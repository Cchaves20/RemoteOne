"""Cria contas e computadores pareados num backend **local**, para o teste de carga.

Escreve direto no banco, pelo próprio código do backend: o cadastro de verdade
exige um código por e-mail ou SMS, e o pareamento, um computador mostrando o
código. Nada disso é o que se quer medir.

Roda de dentro de `backend/`, com o mesmo banco do servidor que vai ser testado:

    DESKSIDE_DATABASE_URL=sqlite:////caminho/carga.db \\
        python ../scripts/carga/preparar_local.py 400 contas.json

**Nunca contra o banco de produção**: as contas de teste não têm dono.
"""

from __future__ import annotations

import json
import secrets
import sys

from app.auth import _entrar
from app.db import SessionLocal, init_db
from app.models import Device, User
from app.pairing import resumo_de_segredo
from app.security import hash_password

SENHA = "Carga-de-teste-1"


def main() -> None:
    quantos, saida = int(sys.argv[1]), sys.argv[2]
    init_db()
    hash_unico = hash_password(SENHA)  # um bcrypt para todos: criar é o que não se mede
    contas = []
    with SessionLocal() as db:
        for i in range(quantos):
            email = f"carga-{i:05d}@carga.example.com"
            user = User(email=email, hashed_password=hash_unico, first_name="Carga")
            db.add(user)
            db.flush()
            segredo = secrets.token_urlsafe(32)
            device_id = f"carga-pc-{i:05d}"
            db.add(Device(
                device_id=device_id,
                user_id=user.id,
                name=f"carga-{i:05d}",
                os="Linux",
                hostname=f"carga-{i:05d}",
                agent_secret=resumo_de_segredo(segredo),
            ))
            contas.append({"email": email, "senha": SENHA,
                           "device_id": device_id, "segredo": segredo, "user": user})
        db.commit()
        # Um acesso já aberto por conta, como o app que guardou o login: abrir
        # o app não confere a senha de novo. O login com senha é medido à
        # parte (`carga.py --entrar`). O acesso vale 15 minutos.
        for c in contas:
            c["token"] = _entrar(db, c.pop("user"), None).access_token
    with open(saida, "w") as f:
        json.dump(contas, f)
    print(f"{quantos} contas pareadas em {saida}")


if __name__ == "__main__":
    main()
