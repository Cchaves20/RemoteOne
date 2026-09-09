FROM python:3.12-slim

WORKDIR /app

# As dependências vêm do arquivo travado, e não do `pyproject.toml`.
#
# O `pyproject.toml` diz `fastapi>=0.115`, o que significa "o que estiver
# publicado no dia do build". Duas consequências: dois builds do mesmo commit
# podiam gerar imagens diferentes — e "funciona aqui e não lá" viraria caça a um
# fantasma —, e uma versão comprometida de qualquer dependência, ou de qualquer
# dependência das dependências, entrava sozinha no deploy seguinte.
#
# O `--require-hashes` (implícito, porque o arquivo tem hashes) é a metade que
# importa: versão fixa diz **qual** pacote, hash diz que é **aquele** pacote.
# Sem o hash, um pacote republicado com o mesmo número passaria.
#
# Regerar quando for atualizar algo:
#   pip install pip-tools
#   pip-compile --strip-extras --generate-hashes -o requirements.txt pyproject.toml
# com Python 3.12, a mesma versão desta imagem — um lock de outra versão pode
# resolver marcadores de forma diferente.
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Não há `pip install .` aqui, e não havia antes tampouco — só parecia haver.
# Ele rodava com a pasta `app` ainda não copiada, e sem `[build-system]` nem
# configuração de pacotes o setuptools não achava nada para empacotar: o passo
# instalava uma distribuição vazia e servia unicamente para puxar as
# dependências. Quem importa `app.main` é o uvicorn, a partir do WORKDIR.

COPY app ./app

# Usuário sem privilégio, e a razão é o tamanho do estrago, não a elegância.
#
# Rodando como root, uma execução de código na API — uma falha numa
# dependência, um caminho de arquivo mal tratado — entrega root **dentro do
# contêiner**, com o volume do banco montado e escrevível. Como usuário comum,
# a mesma falha rende bem menos: sem instalar pacote, sem escrever fora do que
# lhe pertence, sem tocar em `/app`.
#
# `/app` fica de **root**, e de propósito: o código não precisa se alterar, e
# um processo que não pode reescrever o próprio programa é um processo que não
# consegue se tornar persistente ali.
#
# UID fixo e alto (10001) porque ele precisa casar com o dono do volume do
# banco no host — ver o comentário em `deploy/docker-compose.lite.yml`. Um UID
# sorteado pelo `useradd` mudaria de imagem para imagem e quebraria a cada
# reconstrução.
# Grupo criado explicitamente: sem `--gid`, o `useradd` escolhe o número do
# grupo por conta própria, e ele pode **não** ser 10001. O `USER 10001:10001`
# abaixo apontaria para um grupo que não existe, e o `chown` do serviço
# `init-permissoes` no compose escreveria um dono que não bate com quem roda.
RUN groupadd --system --gid 10001 deskside \
 && useradd --system --uid 10001 --gid 10001 --no-create-home deskside \
 && mkdir -p /data /backups \
 && chown 10001:10001 /data /backups
USER 10001:10001

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
