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
        },
    }
    with engine.begin() as conn:
        for tabela, colunas in por_tabela.items():
            existing = {col["name"] for col in inspector.get_columns(tabela)}
            for coluna, tipo in colunas.items():
                if coluna not in existing:
                    conn.execute(text(f"ALTER TABLE {tabela} ADD COLUMN {coluna} {tipo}"))
