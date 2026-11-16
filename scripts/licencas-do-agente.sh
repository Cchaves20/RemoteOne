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
# O texto do codec da Cisco vai junto (condição 4 da licença dela; ver
# src/codec_cisco.rs), com o mesmo título que o `deskside-agent licencas` usa.
{
  cat LICENCAS-DE-TERCEIROS.txt
  printf '\n------------------------------------------------------------------------------\n'
  printf 'OpenH264 (binário da Cisco, baixado à parte pelo agente)\n'
  printf -- '------------------------------------------------------------------------------\n\n'
  cat LICENCA-OPENH264-CISCO.txt
} > ../deploy/site/licencas.txt
echo "licenças atualizadas: agent/LICENCAS-DE-TERCEIROS.txt e deploy/site/licencas.txt"
