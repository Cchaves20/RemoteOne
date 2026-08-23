"""Cópia de segurança do banco.

O que se protege aqui é a única coisa do projeto que não dá para refazer: as
contas e os pareamentos. Um backup que falha em silêncio é pior que nenhum,
porque a descoberta acontece no pior dia possível.
"""

import sqlite3
from datetime import UTC, datetime
from pathlib import Path

import pytest

from app.backup import (
    PREFIXO,
    fazer_backup,
    limpar_antigos,
    nome_do_arquivo,
    rodar,
)


def _banco(caminho: Path, linhas: int = 3) -> Path:
    """Um banco pequeno com conteúdo conhecido."""
    con = sqlite3.connect(caminho)
    con.execute("CREATE TABLE contas (id INTEGER PRIMARY KEY, email TEXT)")
    con.executemany(
        "INSERT INTO contas (email) VALUES (?)",
        [(f"pessoa{i}@example.com",) for i in range(linhas)],
    )
    con.commit()
    con.close()
    return caminho


def _emails(caminho: Path) -> list[str]:
    con = sqlite3.connect(caminho)
    try:
        return [r[0] for r in con.execute("SELECT email FROM contas ORDER BY id")]
    finally:
        con.close()


def test_a_copia_tem_os_mesmos_dados(tmp_path):
    """O básico, e o que ninguém confere até precisar."""
    origem = _banco(tmp_path / "deskside.db")
    destino = fazer_backup(origem, tmp_path / "backups" / "copia.db")

    assert destino.is_file()
    assert _emails(destino) == _emails(origem)


def test_a_copia_e_um_banco_de_verdade(tmp_path):
    """Não basta ter os bytes: o arquivo tem que abrir como banco.

    Uma cópia feita com `cp` no meio de uma transação produz um arquivo que
    parece bom e não abre. É exatamente esse defeito que a API de backup do
    SQLite existe para evitar - e é isto que este teste verifica.
    """
    origem = _banco(tmp_path / "deskside.db")
    destino = fazer_backup(origem, tmp_path / "copia.db")

    con = sqlite3.connect(destino)
    try:
        assert con.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
    finally:
        con.close()


def test_copia_com_escrita_acontecendo(tmp_path):
    """Com uma transação aberta noutra conexão, a cópia continua íntegra.

    É o caso de produção: o servidor está no ar, e o backup roda por cima. Uma
    cópia de arquivo aqui pegaria metade do antes e metade do depois.
    """
    origem = _banco(tmp_path / "deskside.db")
    escritor = sqlite3.connect(origem)
    try:
        escritor.execute("BEGIN")
        escritor.execute("INSERT INTO contas (email) VALUES ('no-meio@example.com')")
        # Sem commit: a linha existe só dentro da transação aberta.
        destino = fazer_backup(origem, tmp_path / "copia.db")
        con = sqlite3.connect(destino)
        try:
            assert con.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
            # A cópia é de um estado **consistente**: a transação não confirmada
            # não pode aparecer pela metade.
            emails = [r[0] for r in con.execute("SELECT email FROM contas")]
            assert "no-meio@example.com" not in emails
        finally:
            con.close()
    finally:
        escritor.rollback()
        escritor.close()


def test_banco_que_nao_existe_e_erro_e_nao_silencio(tmp_path):
    """Um backup "bem-sucedido" sem arquivo nenhum só se descobre na hora de
    restaurar - e aí é tarde."""
    with pytest.raises(FileNotFoundError):
        fazer_backup(tmp_path / "nao-existe.db", tmp_path / "copia.db")


def test_a_pasta_de_destino_e_criada(tmp_path):
    """Primeira execução numa VM nova: a pasta ainda não existe."""
    origem = _banco(tmp_path / "deskside.db")
    destino = fazer_backup(origem, tmp_path / "a" / "b" / "copia.db")
    assert destino.is_file()


def test_a_origem_e_aberta_so_para_leitura(tmp_path):
    """O processo de backup não tem por que poder escrever no banco de
    produção. Um erro de digitação aqui não pode virar dano."""
    origem = _banco(tmp_path / "deskside.db")
    antes = _emails(origem)
    fazer_backup(origem, tmp_path / "copia.db")
    assert _emails(origem) == antes


class TestNome:
    def test_leva_a_hora_e_nao_so_o_dia(self):
        """Um backup manual antes de mexer no servidor não pode sobrescrever o
        automático do mesmo dia - que é justamente o que se quer preservar."""
        um = nome_do_arquivo(datetime(2026, 8, 9, 3, 0, 0, tzinfo=UTC))
        dois = nome_do_arquivo(datetime(2026, 8, 9, 14, 30, 0, tzinfo=UTC))
        assert um != dois
        assert um.startswith(PREFIXO)
        assert um.endswith(".db")

    def test_a_ordem_alfabetica_e_a_ordem_do_tempo(self):
        """A limpeza ordena por nome. Se o nome não crescer com o tempo, ela
        apagaria a cópia errada."""
        nomes = [
            nome_do_arquivo(datetime(2026, 1, 2, 3, 4, 5, tzinfo=UTC)),
            nome_do_arquivo(datetime(2026, 1, 2, 3, 4, 6, tzinfo=UTC)),
            nome_do_arquivo(datetime(2026, 1, 10, 0, 0, 0, tzinfo=UTC)),
            nome_do_arquivo(datetime(2026, 2, 1, 0, 0, 0, tzinfo=UTC)),
        ]
        assert nomes == sorted(nomes)


class TestLimpeza:
    def _copias(self, pasta: Path, quantas: int) -> list[Path]:
        pasta.mkdir(parents=True, exist_ok=True)
        feitas = []
        for i in range(quantas):
            p = pasta / f"{PREFIXO}2026010{i}-000000.db"
            p.write_bytes(b"x")
            feitas.append(p)
        return feitas

    def test_guarda_as_mais_novas(self, tmp_path):
        copias = self._copias(tmp_path, 5)
        apagadas = limpar_antigos(tmp_path, manter=2)
        assert apagadas == copias[:3]
        restantes = sorted(p.name for p in tmp_path.iterdir())
        assert restantes == [copias[3].name, copias[4].name]

    def test_nao_apaga_nada_abaixo_do_limite(self, tmp_path):
        self._copias(tmp_path, 3)
        assert limpar_antigos(tmp_path, manter=14) == []
        assert len(list(tmp_path.iterdir())) == 3

    def test_nao_toca_no_que_nao_e_backup(self, tmp_path):
        """Uma pasta de backups ganha um README ou uma cópia manual com outro
        nome. Apagar isso seria uma surpresa desagradável."""
        self._copias(tmp_path, 3)
        (tmp_path / "LEIA-ME.txt").write_text("como restaurar")
        (tmp_path / "antes-da-migracao.db").write_bytes(b"x")
        limpar_antigos(tmp_path, manter=1)
        nomes = {p.name for p in tmp_path.iterdir()}
        assert "LEIA-ME.txt" in nomes
        assert "antes-da-migracao.db" in nomes

    def test_manter_zero_e_recusado(self, tmp_path):
        """Apagar tudo não é limpeza, é o contrário de um backup."""
        with pytest.raises(ValueError):
            limpar_antigos(tmp_path, manter=0)

    def test_pasta_inexistente_nao_quebra(self, tmp_path):
        assert limpar_antigos(tmp_path / "nunca-existiu") == []


def test_rodar_faz_a_copia_e_limpa(tmp_path):
    """O que a tarefa agendada chama, ponta a ponta."""
    origem = _banco(tmp_path / "deskside.db")
    pasta = tmp_path / "backups"
    # Duas cópias velhas que devem sair quando o limite é 1.
    pasta.mkdir()
    for i in range(2):
        (pasta / f"{PREFIXO}2020010{i}-000000.db").write_bytes(b"x")

    destino = rodar(origem, pasta, manter=1)

    assert destino.is_file()
    assert _emails(destino) == _emails(origem)
    # Sobrou só a nova: as duas de 2020 vêm antes na ordem do nome.
    assert [p.name for p in pasta.iterdir()] == [destino.name]


# --- Cifra em repouso (S6, segunda metade) -----------------------------------


def test_a_copia_cifrada_nao_deixa_o_original_para_tras(tmp_path):
    """Cifrar sem apagar o original não protege nada.

    É o erro que se comete acrescentando a cifra sem pensar no que fica para
    trás: a pasta passa a ter as duas versões, e quem copia a pasta leva a
    legível junto.
    """
    from app import backup

    banco = tmp_path / "origem.db"
    _banco(banco)
    copia = backup.fazer_backup(banco, tmp_path / "copias" / "deskside-1.db")

    cifrada = backup.cifrar(copia, "uma-chave-guardada-em-outro-lugar")

    assert cifrada.exists()
    assert not copia.exists(), "o banco em claro ficou ao lado do cifrado"
    assert not cifrada.read_bytes().startswith(b"SQLite format 3")


def test_a_copia_cifrada_volta_a_ser_um_banco(tmp_path):
    """Um backup que não abre está destruído, então isto é o teste que importa."""
    from app import backup

    banco = tmp_path / "origem.db"
    _banco(banco)
    copia = backup.fazer_backup(banco, tmp_path / "deskside-2.db")
    cifrada = backup.cifrar(copia, "chave-boa")

    aberta = backup.decifrar(cifrada, "chave-boa")
    assert aberta.read_bytes().startswith(b"SQLite format 3")
    assert _emails(aberta) == _emails(banco)


def test_chave_errada_nao_produz_arquivo_pela_metade(tmp_path):
    """Falhar alto, e sem deixar lixo com cara de banco.

    Gravar o que quer que seja com o nome `.db` seria pior que o erro: no dia
    da restauração, alguém acharia um arquivo e o usaria.
    """
    import pytest

    from app import backup

    banco = tmp_path / "origem.db"
    _banco(banco)
    cifrada = backup.cifrar(backup.fazer_backup(banco, tmp_path / "deskside-3.db"), "certa")

    with pytest.raises(SystemExit):
        backup.decifrar(cifrada, "errada")
    assert not (tmp_path / "deskside-3.db").exists()


def test_a_limpeza_enxerga_as_copias_cifradas(tmp_path):
    """Senão elas ficam para sempre e enchem o disco.

    O filtro antigo olhava `p.suffix == ".db"`; o sufixo de uma cópia cifrada é
    `.enc`. Nenhuma seria apagada — e um backup que enche o disco derruba o
    servidor que ele existe para proteger.
    """
    from app import backup

    for i in range(20):
        (tmp_path / f"deskside-2026010{i:02d}-000000.db.enc").write_bytes(b"x")

    apagados = backup.limpar_antigos(tmp_path, manter=14)

    assert len(apagados) == 6, f"apagou {len(apagados)}"
    assert len(list(tmp_path.iterdir())) == 14
