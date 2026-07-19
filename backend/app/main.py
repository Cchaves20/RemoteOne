from fastapi import FastAPI

from app.config import settings

app = FastAPI(title=settings.app_name, version=settings.version)


@app.get("/health")
def health() -> dict[str, str]:
    """Verificação de disponibilidade usada pela CI e por orquestradores."""
    return {"status": "ok", "version": settings.version}


@app.get("/api/v1")
def api_root() -> dict[str, str]:
    """Raiz da API v1. Autenticação e pareamento entram aqui (Etapas 2 e 5)."""
    return {"name": settings.app_name}
