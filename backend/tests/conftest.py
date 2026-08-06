"""Configuração de testes.

Define o banco como SQLite (num arquivo temporário) e um segredo JWT fixo
ANTES de importar o app, de modo que toda a suíte rode sem PostgreSQL. A
fixture autouse recria as tabelas a cada teste, garantindo isolamento.
"""

import os

os.environ.setdefault("DESKSIDE_DATABASE_URL", "sqlite:///./test_deskside.db")
os.environ.setdefault("DESKSIDE_JWT_SECRET", "test-secret")

import pytest  # noqa: E402

from app.db import Base, engine  # noqa: E402


@pytest.fixture(autouse=True)
def fresh_db():
    Base.metadata.drop_all(bind=engine)
    Base.metadata.create_all(bind=engine)
    yield
    Base.metadata.drop_all(bind=engine)
