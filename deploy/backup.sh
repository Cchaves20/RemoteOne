#!/bin/sh
# Cópia de segurança do banco do Deskside, na própria VM.
#
# É o que o cron chama uma vez por dia. A lógica de verdade está em
# `backend/app/backup.py`, testada; aqui só há o que o cron precisa: entrar na
# pasta certa e chamar o contêiner.
#
# Instalar (uma vez, na VM):
#
#   cd ~/Deskside 2>/dev/null || cd ~/RemoteOne
#   chmod +x deploy/backup.sh
#   ( crontab -l 2>/dev/null | grep -v 'deploy/backup.sh'; \
#     echo "17 3 * * * sh -c 'cd ~/Deskside 2>/dev/null || cd ~/RemoteOne; ./deploy/backup.sh' >> ~/backup.log 2>&1" ) | crontab -
#
# O caminho na linha do cron aceita os **dois** nomes de pasta pelo mesmo motivo
# que o `cd` aqui embaixo: o clone pode se chamar RemoteOne ou Deskside. Uma
# linha de cron com o caminho errado falha todos os dias em silêncio, num log
# que ninguém lê até precisar restaurar. Já aconteceu aqui.
#
# 3h17 e não 3h00: a madrugada em ponto é quando todo mundo agenda tarefa, e
# numa VM de 1 GB duas coisas pesadas ao mesmo tempo é o suficiente para
# derrubar o servidor.
set -e

# O caminho do clone, que **não** é a marca - é só onde o repositório foi
# baixado. Aceitar os dois nomes deixa a pasta ser renomeada sem quebrar isto.
cd ~/Deskside/deploy 2>/dev/null || cd ~/RemoteOne/deploy

# `exec -T` porque o cron não tem terminal. Sem o `-T`, o docker recusa com
# "the input device is not a TTY" - e o backup falharia todo dia, em silêncio,
# num log que ninguém lê até precisar restaurar.
sudo docker compose -f docker-compose.lite.yml exec -T api python -m app.backup /backups

# Uma linha por execução, com a data: é o que permite olhar o log e ver que a
# tarefa **rodou**, e não só que não deu erro.
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) backup concluído"
