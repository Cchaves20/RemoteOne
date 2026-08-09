"""Cópia de segurança do banco.

O Deskside guarda no banco a única coisa que **não** dá para refazer: as contas
e os pareamentos. O código está no Git, a configuração está no `.env`, os
computadores reinstalam o agente em dois minutos — mas se o banco sumir, cada
usuário perde a conta e cada computador precisa ser pareado de novo, um a um.

Até aqui não havia backup nenhum. A VM da Oracle é gratuita, tem 1 GB de RAM e
nenhuma garantia; um disco que morre leva tudo junto.

## Por que não é `cp`

Copiar o arquivo com o servidor rodando pode produzir um arquivo **corrompido**:
o SQLite escreve em páginas, e uma cópia feita no meio de uma transação pega
metade do antes e metade do depois. O pior é que a cópia parece boa — o defeito
só aparece no dia em que alguém tenta restaurar.

O caminho certo é a API de backup do próprio SQLite (`Connection.backup`), que
existe exatamente para isto: ela copia página a página, percebe quando uma
página muda no meio do caminho e recomeça essa parte. O resultado é um banco
consistente **sem parar o servidor**.

## O que este módulo não faz

Não manda a cópia para lugar nenhum. Ele grava numa pasta da própria VM, e isso
sozinho **não protege contra a VM morrer** — protege contra o que é mais comum:
uma migração de esquema que dá errado, um `DELETE` sem `WHERE`, um contêiner
recriado com o volume errado.

Levar a cópia para fora é a outra metade, e ela é feita de onde já existe uma
chave SSH: `scripts/atualizar.cmd -Backup` baixa a mais recente para o
computador de casa. Ver `docs/deploy-vps-oracle.md`.
"""

from __future__ import annotations

import sqlite3
from datetime import datetime, timezone
from pathlib import Path

#: Quantas cópias diárias ficam na VM.
#:
#: Catorze porque o erro que este backup mais protege — um esquema quebrado, um
#: apagamento acidental — costuma ser notado em dias, não em horas. Guardar só
#: a de ontem deixaria de fora o caso de alguém perceber na segunda-feira algo
#: que aconteceu na sexta. E o banco tem kilobytes: catorze cópias não pesam.
MANTER_POR_PADRAO = 14

#: Prefixo do nome, para a limpeza saber o que é dela e não apagar outra coisa
#: que esteja na mesma pasta.
PREFIXO = "deskside-"
SUFIXO = ".db"


def nome_do_arquivo(quando: datetime | None = None) -> str:
    """O nome da cópia de um instante.

    Em UTC e com hora, não só a data: um backup manual feito antes de mexer no
    servidor não pode sobrescrever o automático do mesmo dia — que é justamente
    o que se quer preservar quando algo dá errado logo depois.
    """
    agora = quando or datetime.now(timezone.utc)
    return f"{PREFIXO}{agora.strftime('%Y%m%d-%H%M%S')}{SUFIXO}"


def fazer_backup(origem: Path, destino: Path) -> Path:
    """Copia o banco de forma consistente, com o servidor no ar.

    Devolve o caminho gravado. Lança se a origem não existe — um backup que
    "deu certo" sem arquivo nenhum seria pior que um erro, porque só se
    descobriria no dia da restauração.
    """
    if not origem.is_file():
        raise FileNotFoundError(f"banco não encontrado: {origem}")
    destino.parent.mkdir(parents=True, exist_ok=True)

    # `mode=ro` na origem: este processo não tem por que poder escrever no banco
    # de produção, e um erro de digitação aqui não pode virar dano.
    fonte = sqlite3.connect(f"file:{origem}?mode=ro", uri=True)
    try:
        copia = sqlite3.connect(destino)
        try:
            fonte.backup(copia)
        finally:
            copia.close()
    finally:
        fonte.close()
    return destino


def limpar_antigos(pasta: Path, manter: int = MANTER_POR_PADRAO) -> list[Path]:
    """Apaga as cópias mais velhas, guardando as `manter` mais novas.

    Devolve o que foi apagado. Ordena pelo **nome**, e não pela data do arquivo:
    o nome carrega o instante em que a cópia foi feita, enquanto a data do
    arquivo muda se alguém mover a pasta ou restaurar um backup de outra
    máquina.

    Só mexe no que tem o prefixo. Uma pasta de backups costuma ganhar um
    `README` ou uma cópia manual com outro nome, e apagar isso seria uma
    surpresa desagradável.
    """
    if manter < 1:
        raise ValueError("manter pelo menos uma cópia")
    if not pasta.is_dir():
        return []
    copias = sorted(
        (p for p in pasta.iterdir() if p.name.startswith(PREFIXO) and p.suffix == SUFIXO),
        key=lambda p: p.name,
    )
    apagar = copias[:-manter] if len(copias) > manter else []
    for p in apagar:
        p.unlink()
    return apagar


def rodar(origem: Path, pasta: Path, manter: int = MANTER_POR_PADRAO) -> Path:
    """Faz a cópia e limpa as antigas. É o que a tarefa agendada chama."""
    destino = fazer_backup(origem, pasta / nome_do_arquivo())
    limpar_antigos(pasta, manter)
    return destino


def _caminho_do_banco() -> Path:
    """O arquivo do banco, deduzido da configuração.

    Existe para a tarefa agendada não precisar repetir o caminho: ele já está
    no `DESKSIDE_DATABASE_URL`, e duas verdades sobre onde o banco fica é o
    tipo de coisa que só se descobre errada no dia da restauração.
    """
    from app.config import settings

    url = settings.database_url
    if not url.startswith("sqlite"):
        raise SystemExit(
            "este backup é do SQLite; para Postgres, use pg_dump "
            f"(DESKSIDE_DATABASE_URL={url})"
        )
    # sqlite:////data/x.db -> /data/x.db ; sqlite:///./x.db -> ./x.db
    caminho = url.split("///", 1)[-1]
    return Path(caminho)


def main() -> None:
    """`python -m app.backup [pasta]` — o que o cron da VM roda."""
    import sys

    pasta = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/backups")
    destino = rodar(_caminho_do_banco(), pasta)
    # Uma linha por execução, com o tamanho: é o que permite ver no log que a
    # cópia não está vindo vazia.
    print(f"backup: {destino} ({destino.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
