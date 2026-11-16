# Certificados de âncora de confiança

Esta pasta entra no contêiner da API como `/certs`, **somente leitura**
(`deploy/docker-compose.lite.yml`). O conteúdo não é versionado — só este
arquivo e o `.gitkeep`.

## `AppleRootCA-G3.cer`

É a raiz que ancora a verificação do comprovante de compra da App Store. O
comprovante vem assinado por um certificado que vem assinado por outro, e a
verificação só vale alguma coisa se a ponta dessa corrente for um certificado
que **nós** já confiávamos antes de a corrente chegar. Sem ele, `lojas.py` cai
no modo `DeMentira` e o `/health` denuncia.

Buscar na fonte, no próprio servidor:

    cd ~/Deskside/deploy
    curl -fsSL -o certs/AppleRootCA-G3.cer \
      https://www.apple.com/certificateauthority/AppleRootCA-G3.cer

E conferir antes de confiar — um certificado raiz copiado errado transforma a
verificação em teatro, e um teatro que não dá erro nenhum:

    openssl x509 -inform DER -in certs/AppleRootCA-G3.cer -noout \
      -subject -issuer -dates -fingerprint -sha256

O `subject` e o `issuer` têm que ser **iguais** (é uma raiz: ela assina a si
mesma) e dizer `Apple Root CA - G3`. A impressão digital SHA-256 é a que a
Apple publica em <https://www.apple.com/certificateauthority/>.

Depois, no `deploy/.env`:

    DESKSIDE_APPLE_ROOT_CA=/certs/AppleRootCA-G3.cer

O caminho é o de **dentro** do contêiner, não o do servidor.
