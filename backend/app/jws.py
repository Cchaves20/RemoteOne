"""Verificação da assinatura criptográfica dos comprovantes da Apple.

Separado de `lojas.py` porque é a única parte que é criptografia pura: entra
texto, sai texto conferido, sem rede, sem banco e sem configuração. Isso a
torna testável de ponta a ponta com uma cadeia de certificados fabricada
aqui — que é como estes testes rodam, já que este ambiente não alcança a Apple.

## O que um JWS é, e onde a integração costuma errar

A Apple entrega cada transação como um JWS: três pedaços separados por ponto,
`cabeçalho.conteúdo.assinatura`, cada um em base64url. O conteúdo é JSON
legível **sem chave nenhuma** — e é exatamente aí que a integração dá errado.
Ler o conteúdo é trivial; um comprovante forjado passa por qualquer código que
se contente com decodificar.

O que prova que a Apple emitiu aquilo é a assinatura, e conferi-la exige:

1. Tirar do cabeçalho a cadeia de certificados (`x5c`);
2. Provar que a cadeia termina **no certificado raiz da Apple** — não num
   certificado que só diz chamar-se Apple;
3. Provar que cada certificado foi assinado pelo seguinte;
4. Só então usar a chave pública da ponta para conferir a assinatura do JWS.

Pular o passo 2 é o erro que mais se vê: qualquer pessoa gera uma cadeia
própria, assina o que quiser com ela, e o código aceita porque "a assinatura
bate com o certificado que veio junto". Bate mesmo — com o certificado do
impostor.
"""

from __future__ import annotations

import base64
import json
from datetime import UTC, datetime
from itertools import pairwise

from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa
from cryptography.hazmat.primitives.asymmetric.utils import encode_dss_signature


class JwsInvalido(Exception):
    """O comprovante não é um JWS válido, ou não foi emitido por quem diz."""


def _sem_padding(pedaco: str) -> bytes:
    """base64url tolerando o preenchimento ausente.

    O JWS omite o `=` do fim; `urlsafe_b64decode` exige. Recolocar é mais
    seguro do que confiar que o outro lado mandou o tamanho múltiplo de quatro.
    """
    faltam = -len(pedaco) % 4
    try:
        return base64.urlsafe_b64decode(pedaco + "=" * faltam)
    except (ValueError, TypeError) as e:
        raise JwsInvalido(f"pedaço não é base64url: {e}") from e


def _conferir_assinatura_entre(filho: x509.Certificate, pai: x509.Certificate) -> None:
    """Prova que `pai` assinou `filho`."""
    chave = pai.public_key()
    try:
        if isinstance(chave, ec.EllipticCurvePublicKey):
            chave.verify(
                filho.signature,
                filho.tbs_certificate_bytes,
                ec.ECDSA(filho.signature_hash_algorithm),
            )
        elif isinstance(chave, rsa.RSAPublicKey):
            chave.verify(
                filho.signature,
                filho.tbs_certificate_bytes,
                padding.PKCS1v15(),
                filho.signature_hash_algorithm,
            )
        else:
            raise JwsInvalido(f"tipo de chave não suportado: {type(chave).__name__}")
    except InvalidSignature as e:
        raise JwsInvalido("a cadeia de certificados está quebrada") from e


def verificar_jws(token: str, raiz: x509.Certificate, agora: datetime | None = None) -> dict:
    """Confere um JWS da Apple e devolve o conteúdo.

    `raiz` é o certificado em que a cadeia precisa terminar. Ele é parâmetro, e
    não constante, por dois motivos: em produção vem de arquivo (ver
    `settings.apple_root_ca`), e nos testes vem de uma raiz fabricada — o que
    permite exercitar **a recusa**, que é a parte que importa.
    """
    agora = agora or datetime.now(UTC)

    partes = token.split(".")
    if len(partes) != 3:
        raise JwsInvalido(f"um JWS tem três partes, veio com {len(partes)}")
    cabecalho_b64, conteudo_b64, assinatura_b64 = partes

    try:
        cabecalho = json.loads(_sem_padding(cabecalho_b64))
    except json.JSONDecodeError as e:
        raise JwsInvalido(f"cabeçalho não é JSON: {e}") from e

    if cabecalho.get("alg") != "ES256":
        # Recusar explicitamente em vez de aceitar o que vier: `alg: none` e a
        # troca de algoritmo são as duas falhas clássicas de quem confia no
        # cabeçalho para decidir como verificar.
        raise JwsInvalido(f"algoritmo inesperado: {cabecalho.get('alg')!r}")

    x5c = cabecalho.get("x5c")
    if not isinstance(x5c, list) or len(x5c) < 2:
        raise JwsInvalido("cabeçalho sem cadeia de certificados (x5c)")

    try:
        cadeia = [x509.load_der_x509_certificate(base64.b64decode(c)) for c in x5c]
    except Exception as e:  # noqa: BLE001 - qualquer defeito aqui é "não é certificado"
        raise JwsInvalido(f"x5c não contém certificados: {e}") from e

    # A ponta da cadeia precisa ser a raiz que confiamos. Comparar os bytes
    # inteiros, e não o nome nem a chave: nome se escolhe, e comparar só a
    # chave pública aceitaria um certificado com a mesma chave e outras datas.
    der = serialization.Encoding.DER
    if cadeia[-1].public_bytes(der) != raiz.public_bytes(der):
        raise JwsInvalido("a cadeia não termina no certificado raiz esperado")

    for cert in cadeia:
        if not (cert.not_valid_before_utc <= agora <= cert.not_valid_after_utc):
            raise JwsInvalido("certificado da cadeia fora da validade")

    # `pairwise`, e não `zip(cadeia, cadeia[1:])` com `strict=True` como o
    # lint sugere: as duas listas têm tamanhos diferentes **de propósito**
    # (cada certificado com o de cima), e `strict=True` faria toda verificação
    # levantar erro.
    for filho, pai in pairwise(cadeia):
        _conferir_assinatura_entre(filho, pai)

    folha = cadeia[0]
    chave = folha.public_key()
    if not isinstance(chave, ec.EllipticCurvePublicKey):
        raise JwsInvalido("a folha da cadeia não tem chave de curva elíptica")

    bruta = _sem_padding(assinatura_b64)
    if len(bruta) != 64:
        raise JwsInvalido(f"assinatura ES256 tem 64 bytes, veio com {len(bruta)}")
    # O JWS traz `r` e `s` concatenados e crus; o `cryptography` espera DER.
    # Esquecer esta conversão dá "assinatura inválida" em comprovante legítimo,
    # que é o defeito mais difícil de diagnosticar desta integração.
    assinatura = encode_dss_signature(
        int.from_bytes(bruta[:32], "big"), int.from_bytes(bruta[32:], "big")
    )

    try:
        chave.verify(
            assinatura,
            f"{cabecalho_b64}.{conteudo_b64}".encode(),
            ec.ECDSA(hashes.SHA256()),
        )
    except InvalidSignature as e:
        raise JwsInvalido("a assinatura não confere com o certificado") from e

    try:
        return json.loads(_sem_padding(conteudo_b64))
    except json.JSONDecodeError as e:
        raise JwsInvalido(f"conteúdo não é JSON: {e}") from e
