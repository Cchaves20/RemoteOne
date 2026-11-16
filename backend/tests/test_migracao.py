"""A migração de esquema em banco que já existia.

Existe por causa de um defeito que a suíte inteira não pegava, e não pegava por
um motivo estrutural: **os testes rodam sempre em banco novo**, criado pelo
`create_all` com a definição atual. Produção roda em banco antigo, onde
`create_all` não toca em tabela que já existe.

O defeito: `users.email` nasceu `NOT NULL`, e o cadastro por telefone grava
`email = NULL`. A migração adicionava as colunas que faltavam — `ADD COLUMN`
resolve coluna ausente — e nada resolvia uma coluna presente com a restrição
errada. O formulário passava, o SMS saía, o código certo era digitado, e só
então o `INSERT` morria. O pior lugar possível para uma falha.

Estes testes montam o esquema antigo à mão e conferem o que a migração faz com
ele. É a única forma de exercitar aqui o caminho que só acontece lá.
"""

import sqlite3

import pytest
from sqlalchemy import create_engine, inspect, text

import app.db as db_mod

#: O `users` como ele existia antes do cadastro completo, com o índice único e
#: uma tabela filha apontando para ele.
ESQUEMA_ANTIGO = """
CREATE TABLE users (
    id INTEGER NOT NULL PRIMARY KEY,
    email VARCHAR(320) NOT NULL UNIQUE,
    hashed_password VARCHAR(255) NOT NULL,
    created_at DATETIME NOT NULL
);
CREATE UNIQUE INDEX ix_users_email ON users (email);
CREATE TABLE devices (
    id INTEGER NOT NULL PRIMARY KEY,
    device_id VARCHAR(64) NOT NULL,
    user_id INTEGER NOT NULL REFERENCES users(id),
    name VARCHAR(120) NOT NULL,
    os VARCHAR(32) NOT NULL,
    hostname VARCHAR(255) NOT NULL,
    created_at DATETIME NOT NULL
);
INSERT INTO users VALUES (1, 'antigo@example.com', 'hash-velho', '2026-01-01');
INSERT INTO devices VALUES (1, 'dev-1', 1, 'PC', 'windows', 'pc', '2026-01-01');
"""


@pytest.fixture
def banco_antigo(tmp_path, monkeypatch):
    """Um banco com o esquema de antes, e a migração já aplicada nele.

    Troca o `engine` do módulo em vez de usar o da suíte: o da suíte aponta para
    um banco que o `create_all` acabou de criar com o esquema **novo**, que é
    exatamente o que não reproduz o problema.
    """
    caminho = tmp_path / "antigo.db"
    bruto = sqlite3.connect(caminho)
    bruto.executescript(ESQUEMA_ANTIGO)
    bruto.commit()
    bruto.close()

    engine = create_engine(
        f"sqlite:///{caminho}", connect_args={"check_same_thread": False}
    )
    monkeypatch.setattr(db_mod, "engine", engine)
    db_mod.init_db()
    return engine


def test_email_deixa_de_ser_obrigatorio(banco_antigo):
    """O conserto em si: sem isto, cadastro por telefone morre no `INSERT`."""
    colunas = {c["name"]: c for c in inspect(banco_antigo).get_columns("users")}
    assert colunas["email"]["nullable"] is True
    # E as colunas novas continuam lá depois da reconstrução.
    for nova in ("phone", "first_name", "last_name", "birth_date", "token_key"):
        assert nova in colunas, nova


def test_a_conta_antiga_ganha_uma_chave_de_sessao(banco_antigo):
    """Sem esta etapa, a conta que já existia **nunca mais entraria**.

    O `ADD COLUMN` só sabe pôr um valor fixo, e o valor fixo aqui é a string
    vazia — que a conferência recusa de propósito. O login funcionaria, e a
    requisição seguinte devolveria 401 para sempre. É um erro que não aparece na
    subida do servidor: só na cara de quem tenta usar a conta.
    """
    with banco_antigo.connect() as conn:
        chave = conn.execute(text("SELECT token_key FROM users")).scalar()
    assert chave, "a conta antiga ficou sem chave de sessão"


def test_a_conta_que_ja_existia_sobrevive(banco_antigo):
    """Reconstruir tabela é mexer nos dados de alguém. Eles têm de voltar
    inteiros — inclusive o hash da senha, sem o qual a pessoa perde a conta."""
    with banco_antigo.connect() as conn:
        linha = conn.execute(
            text("SELECT id, email, hashed_password FROM users")
        ).one()
    assert linha == (1, "antigo@example.com", "hash-velho")


def test_o_computador_pareado_continua_apontando_para_a_conta(banco_antigo):
    """O que quase passou batido.

    Desde o SQLite 3.25 um `RENAME` reescreve as cláusulas `REFERENCES` das
    outras tabelas: `devices` passaria a apontar para `users_antiga`, que some no
    fim da migração. Nada quebraria na hora — o SQLite não força chaves
    estrangeiras por padrão — e o banco ficaria com uma referência para o nada,
    esperando o dia em que alguém as ligasse.
    """
    with banco_antigo.connect() as conn:
        sql = conn.execute(
            text("SELECT sql FROM sqlite_master WHERE name = 'devices'")
        ).scalar()
        pareados = conn.execute(text("SELECT device_id, user_id FROM devices")).all()
    assert "users_antiga" not in sql
    assert "REFERENCES users" in sql.replace('"', "")
    assert pareados == [("dev-1", 1)]


def test_nao_sobra_tabela_de_rascunho(banco_antigo):
    tabelas = set(inspect(banco_antigo).get_table_names())
    assert "users_antiga" not in tabelas
    assert {"users", "devices", "pending_signups"} <= tabelas


def test_os_indices_voltam_com_os_nomes_certos(banco_antigo):
    """Os índices seguem a tabela renomeada com o nome que tinham, e
    `ix_users_email` colidiria ao ser criado de novo — a migração inteira
    falharia na subida do servidor."""
    nomes = {i["name"] for i in inspect(banco_antigo).get_indexes("users")}
    assert {"ix_users_email", "ix_users_phone"} <= nomes


def test_rodar_de_novo_nao_faz_nada(banco_antigo):
    """Idempotência não é elegância: `init_db()` roda a **cada** subida do
    servidor, e uma migração que reconstrói a tabela toda vez seria uma chance
    de perder dados por reinício."""
    db_mod.init_db()
    db_mod.init_db()
    with banco_antigo.connect() as conn:
        assert conn.execute(text("SELECT COUNT(*) FROM users")).scalar() == 1
        assert conn.execute(text("SELECT COUNT(*) FROM devices")).scalar() == 1
    assert "users_antiga" not in inspect(banco_antigo).get_table_names()


def test_banco_novo_nao_e_reconstruido(tmp_path, monkeypatch):
    """Em banco novo o `create_all` já cria `email` opcional, e a reconstrução
    não deve nem começar."""
    engine = create_engine(f"sqlite:///{tmp_path / 'novo.db'}")
    monkeypatch.setattr(db_mod, "engine", engine)
    db_mod.init_db()
    colunas = {c["name"]: c for c in inspect(engine).get_columns("users")}
    assert colunas["email"]["nullable"] is True
    assert "users_antiga" not in inspect(engine).get_table_names()
