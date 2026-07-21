"""Camada de acesso ao banco de dados (SQLAlchemy 2.0).

Em produção usa PostgreSQL (via `REMOTEONE_DATABASE_URL`); nos testes usa
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
