"""Camada de acesso ao banco de dados (SQLAlchemy 2.0).

Em produção usa PostgreSQL (via `DESKSIDE_DATABASE_URL`); nos testes usa
SQLite. A criação de tabelas é feita por `init_db()` na inicialização do app —
quando o esquema evoluir, migramos para Alembic.
"""

from collections.abc import Iterator

from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

from app.config import settings

# O SQLite precisa de check_same_thread=False para funcionar com o pool de
# threads do FastAPI/TestClient; o Postgres não usa esse argumento.
_connect_args = (
    {"check_same_thread": False} if settings.database_url.startswith("sqlite") else {}
)

engine = create_engine(settings.database_url, connect_args=_connect_args, future=True)
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False)


class Base(DeclarativeBase):
    pass


def get_db() -> Iterator[Session]:
    """Dependência do FastAPI: fornece uma sessão e a fecha ao final."""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def init_db() -> None:
    """Cria as tabelas ainda inexistentes. Importa os modelos para registrá-los."""
    from app import models  # noqa: F401  (registra as tabelas no metadata)

    Base.metadata.create_all(bind=engine)
    _migrate()


def _migrate() -> None:
    """Migração leve: adiciona colunas novas em bancos já existentes.

    Como ainda não usamos Alembic, garantimos aqui as colunas que `create_all`
    não adiciona a tabelas pré-existentes (funciona em SQLite e Postgres).
    """
    from sqlalchemy import inspect, text

    inspector = inspect(engine)
    por_tabela = {
        "devices": {
            "mac_address": "VARCHAR(32)",
            "last_public_ip": "VARCHAR(64)",
        },
        "users": {
            "totp_secret": "VARCHAR(64)",
            "totp_enabled": "BOOLEAN DEFAULT 0 NOT NULL",
            # Cadastro completo. Todas nulas ou com padrão: `ALTER TABLE ADD
            # COLUMN` com `NOT NULL` e sem padrão é recusado numa tabela que já
            # tem linhas, e o servidor não subiria.
            #
            # `phone` fica sem `UNIQUE` aqui de propósito: o SQLite não aceita
            # adicionar coluna única a uma tabela existente. Em banco novo o
            # `create_all` cria o índice; em banco antigo a unicidade fica por
            # conta da checagem no cadastro. Some quando houver Alembic.
            "phone": "VARCHAR(20)",
            "first_name": "VARCHAR(80) DEFAULT '' NOT NULL",
            "last_name": "VARCHAR(80) DEFAULT '' NOT NULL",
            "birth_date": "DATE",
            # Chave de sessão (ver `User.token_key`). Nasce vazia — `ADD COLUMN`
            # com `NOT NULL` precisa de um padrão fixo, e sortear um por linha
            # aqui é impossível — e `_sortear_chaves_de_sessao()` logo abaixo
            # troca cada vazia por uma chave de verdade. Os tokens que as contas
            # antigas têm em mãos não trazem chave nenhuma e param de valer
            # nesta subida: um login a mais, uma vez só, que é o comportamento
            # correto. Aceitá-los por compatibilidade manteria aberta
            # exatamente a porta que a coluna fecha.
            "token_key": "VARCHAR(32) DEFAULT '' NOT NULL",
        },
    }
    with engine.begin() as conn:
        for tabela, colunas in por_tabela.items():
            existing = {col["name"] for col in inspector.get_columns(tabela)}
            for coluna, tipo in colunas.items():
                if coluna not in existing:
                    conn.execute(text(f"ALTER TABLE {tabela} ADD COLUMN {coluna} {tipo}"))

    _email_deixa_de_ser_obrigatorio()
    _sortear_chaves_de_sessao()


def _sortear_chaves_de_sessao() -> None:
    """Dá uma `token_key` de verdade a quem entrou nesta coluna com ela vazia.

    A vazia é recusada na conferência (`security.chave_confere`), então sem esta
    etapa a conta antiga nunca mais entraria: cada login emitiria um token com
    chave vazia que a requisição seguinte rejeitaria. O `ADD COLUMN` não tem
    como sortear uma por linha — é um valor fixo para a tabela inteira —, e por
    isso o sorteio acontece aqui, um por conta.
    """
    from sqlalchemy import inspect, select, text

    from app.models import User
    from app.security import nova_chave_de_sessao

    inspector = inspect(engine)
    if "users" not in inspector.get_table_names():
        return
    with engine.begin() as conn:
        ids = list(conn.scalars(select(User.id).where(User.token_key == "")))
        for user_id in ids:
            conn.execute(
                text("UPDATE users SET token_key = :chave WHERE id = :id"),
                {"chave": nova_chave_de_sessao(), "id": user_id},
            )
    if ids:
        print(f"migração: {len(ids)} conta(s) ganharam chave de sessão")


def _email_deixa_de_ser_obrigatorio() -> None:
    """Afrouxa `users.email` em bancos criados antes do cadastro por telefone.

    Este é o remendo que faltava, e a falha que ele conserta era invisível até o
    último passo: `ADD COLUMN` resolve coluna que **falta**, e nada resolve
    coluna que existe com a restrição errada. O banco de produção nasceu com
    `email NOT NULL`, o `create_all` não mexe em tabela que já existe, e criar
    conta por telefone morria no `INSERT` — depois de o formulário passar, de o
    SMS sair e de o código certo ser digitado. O pior lugar possível.

    Em Postgres é uma linha. No SQLite não existe "alterar coluna": a tabela
    precisa ser reconstruída, e é isso que acontece aqui.
    """
    from sqlalchemy import inspect, text

    inspector = inspect(engine)
    if "users" not in inspector.get_table_names():
        return
    colunas = {c["name"]: c for c in inspector.get_columns("users")}
    email = colunas.get("email")
    if email is None or email["nullable"]:
        return

    if engine.dialect.name != "sqlite":
        with engine.begin() as conn:
            conn.execute(text("ALTER TABLE users ALTER COLUMN email DROP NOT NULL"))
        return

    from app.models import User

    # Só as colunas que existem dos dois lados: o banco antigo pode não ter as
    # que acabaram de ser adicionadas, e a tabela nova não tem nada que só
    # existisse no antigo.
    comuns = [c.name for c in User.__table__.columns if c.name in colunas]
    lista = ", ".join(f'"{n}"' for n in comuns)
    indices = [i["name"] for i in inspector.get_indexes("users")]

    # `AUTOCOMMIT` porque um `PRAGMA` dentro de transação é ignorado em silêncio,
    # e são os dois PRAGMAs que tornam esta reconstrução segura. A transação
    # volta logo abaixo, escrita à mão: sem ela, uma falha no meio deixaria o
    # banco com a tabela renomeada e nenhuma `users`.
    bruta = engine.connect().execution_options(isolation_level="AUTOCOMMIT")
    with bruta as conn:
        conn.exec_driver_sql("PRAGMA foreign_keys=OFF")
        # O detalhe que decide: desde o SQLite 3.25, um RENAME reescreve as
        # cláusulas `REFERENCES` das **outras** tabelas — `devices` passaria a
        # apontar para `users_antiga`, que some no fim. Ninguém veria nada
        # quebrar (o SQLite não força chaves estrangeiras por padrão), e o banco
        # ficaria com uma referência para o nada.
        conn.exec_driver_sql("PRAGMA legacy_alter_table=ON")
        conn.exec_driver_sql("BEGIN")
        try:
            # Os índices seguem a tabela renomeada com o nome que tinham, e
            # `ix_users_email` colidiria ao ser criado de novo.
            for nome in indices:
                conn.execute(text(f'DROP INDEX IF EXISTS "{nome}"'))
            conn.execute(text("ALTER TABLE users RENAME TO users_antiga"))
            User.__table__.create(bind=conn)
            conn.execute(
                text(f"INSERT INTO users ({lista}) SELECT {lista} FROM users_antiga")
            )
            conn.execute(text("DROP TABLE users_antiga"))
            conn.exec_driver_sql("COMMIT")
        except Exception:
            conn.exec_driver_sql("ROLLBACK")
            raise
        finally:
            conn.exec_driver_sql("PRAGMA legacy_alter_table=OFF")
            conn.exec_driver_sql("PRAGMA foreign_keys=ON")
    print("migração: users.email passou a ser opcional (cadastro por telefone)")
