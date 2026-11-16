#!/bin/sh
# Regera agent/LICENCAS-DE-TERCEIROS.txt, que vai dentro do executável do
# agente (`deskside-agent licencas`) e no site (deskside.com.br/licencas).
#
# Rodar depois de mudar dependências do agente (o Dependabot abre esses PRs), e
# fazer o commit dos dois arquivos junto.
#
#   cargo install cargo-about --locked --features cli   (uma vez)
#   sh scripts/licencas-do-agente.sh
set -e
cd "$(dirname "$0")/../agent"
cargo about generate about.hbs -o LICENCAS-DE-TERCEIROS.txt
cp LICENCAS-DE-TERCEIROS.txt ../deploy/site/licencas.txt
echo "licenças atualizadas: agent/LICENCAS-DE-TERCEIROS.txt e deploy/site/licencas.txt"
