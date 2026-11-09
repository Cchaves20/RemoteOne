"""Qual versão dos termos de uso e da política de privacidade está em vigor.

O aceite é a prova do contrato: quem aceitou, quando e **qual texto**. Sem a
versão, um "aceitou os termos" de 2026 seria lido como aceite dos termos de
qualquer ano.

Mudou o texto de `deploy/site/termos.html` ou `privacidade.html` de um jeito
que importa? Troque `VERSAO` aqui e a data no topo das duas páginas. O app pede
o aceite de novo a quem aceitou a versão anterior (ver `UserOut.termos_versao`
e `POST /auth/me/terms`).
"""

#: Ano e mês da publicação. Texto curto e ordenável, que o app mostra como está.
VERSAO = "2026-11.2"
