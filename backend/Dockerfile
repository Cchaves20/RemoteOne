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

EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
