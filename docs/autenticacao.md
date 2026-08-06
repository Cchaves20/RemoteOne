# Autenticação (Etapa 2)

Fundação de autenticação do Deskside: cadastro e login com e-mail e senha,
emitindo tokens JWT. Os métodos externos (Google, Apple, Microsoft) e o 2FA
são construídos por cima desta base.

## Tokens

- **access token** — curta duração (padrão 15 min), enviado no header
  `Authorization: Bearer <token>` a cada requisição protegida.
- **refresh token** — longa duração (padrão 30 dias), trocado por um novo
  access token quando este expira.

O payload traz um campo `type` (`access`/`refresh`); o backend recusa usar um
no lugar do outro. Senhas são guardadas com hash **bcrypt** (nunca em texto).

Configuração por variável de ambiente (ver `app/config.py`):
`DESKSIDE_JWT_SECRET` (obrigatório trocar em produção),
`DESKSIDE_ACCESS_TOKEN_TTL_MINUTES`, `DESKSIDE_REFRESH_TOKEN_TTL_DAYS`.

## Endpoints

| Método | Rota | Corpo | Resposta |
|---|---|---|---|
| POST | `/api/v1/auth/register` | `{email, password}` | 201 + `{access_token, refresh_token}` |
| POST | `/api/v1/auth/login` | `{email, password}` | `{access_token, refresh_token}` |
| POST | `/api/v1/auth/refresh` | `{refresh_token}` | `{access_token}` |
| GET | `/api/v1/auth/me` | — (Bearer) | `{id, email, created_at}` |

Erros: e-mail já cadastrado → 409; credenciais inválidas → 401; e-mail/senha
fora do formato (senha < 8 caracteres, e-mail inválido) → 422.

## Verificação manual

Com o backend rodando (`docker compose up` na pasta `backend/`):

```bash
# cadastro
curl -X POST http://localhost:8000/api/v1/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"caio@example.com","password":"senhaSegura123"}'

# use o access_token retornado:
curl http://localhost:8000/api/v1/auth/me -H "Authorization: Bearer <access_token>"
```

Ou explore de forma interativa em <http://localhost:8000/docs>.

## Próximos passos desta etapa

1. **Login social** (Google/Apple/Microsoft): cada provedor valida a
   identidade e reaproveita a mesma emissão de tokens desta base. Exige
   registrar o app em cada provedor (client id/secret, URLs de redirecionamento).
2. **2FA**: segundo fator (TOTP) após a validação de senha.
3. **Controle de dispositivos autorizados**: vincular refresh tokens a
   dispositivos e permitir revogação — conecta com o pareamento (Etapa 5).
