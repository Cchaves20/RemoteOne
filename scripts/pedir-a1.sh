#!/bin/bash
# Pede a máquina ARM grátis (VM.Standard.A1.Flex) à Oracle até conseguir.
#
# Em São Paulo a capacidade ARM vive esgotada: o console responde "Out of
# capacity" e só resta tentar de novo. Este script tenta sozinho a cada
# INTERVALO segundos, primeiro com 2 OCPU / 12 GB e, sem vaga, com 1 / 6.
# Ver docs/migrar-para-a1.md.
#
# Roda no VPS de hoje, com a linha de comando da Oracle num venv em ~/oci e a
# chave de API em ~/.oci (o guia mostra como). Uso:
#
#   scripts/pedir-a1.sh --uma        # uma rodada, para conferir a configuração
#   nohup scripts/pedir-a1.sh > ~/pedir-a1.log 2>&1 &    # até conseguir
#
# A chave SSH da máquina nova é a mesma deste VPS (~/.ssh/authorized_keys):
# o mesmo comando de SSH entra nas duas.
set -u

OCI=${OCI:-$HOME/oci/bin/oci}
NOME=${NOME:-deskside-a1}
SUBNET_NOME=${SUBNET_NOME:-subnet-20260723-0000}
INTERVALO=${INTERVALO:-180}
# "OCPU:GB", do preferido ao último recurso.
TAMANHOS=${TAMANHOS:-"2:12 1:6"}
UMA=0; [ "${1:-}" = "--uma" ] && UMA=1

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }
falha() { log "PAROU: $*"; exit 1; }
ocid() { case "$1" in ocid1.*) return 0 ;; *) return 1 ;; esac; }

[ -x "$OCI" ] || falha "não achei a linha de comando da Oracle em $OCI"
[ -s "$HOME/.ssh/authorized_keys" ] || falha "não achei ~/.ssh/authorized_keys"

# A conta (tenancy) é também o compartimento raiz, onde a VM de hoje está.
T=$(sed -n 's/^tenancy *= *//p' "$HOME/.oci/config" 2>/dev/null | head -1)
ocid "$T" || falha "não achei 'tenancy=' em ~/.oci/config"

# O que não muda entre as tentativas é descoberto uma vez só. Cada chamada da
# linha de comando custa segundos de processador nesta VM.
AD=$("$OCI" iam availability-domain list -c "$T" --query 'data[0].name' --raw-output) \
  || falha "a Oracle recusou a chave de API (veja a mensagem acima)"
[ -n "$AD" ] || falha "nenhum availability domain encontrado"

SUBNET=$("$OCI" network subnet list -c "$T" --display-name "$SUBNET_NOME" \
  --query 'data[0].id' --raw-output)
ocid "$SUBNET" || falha "não achei a subnet $SUBNET_NOME"

# A Ubuntu 24.04 mais nova que serve no A1 (logo, a aarch64), sem a Minimal.
IMAGEM=$("$OCI" compute image list -c "$T" --operating-system "Canonical Ubuntu" \
  --operating-system-version "24.04" --shape VM.Standard.A1.Flex \
  --sort-by TIMECREATED --sort-order DESC --all \
  --query "data[?!contains(\"display-name\", 'Minimal')] | [0].id" --raw-output)
ocid "$IMAGEM" || falha "não achei a imagem Ubuntu 24.04 para A1"

log "conta ok · $AD · subnet $SUBNET_NOME · imagem encontrada · a cada ${INTERVALO}s"

# Uma resposta que se perde no caminho (tempo esgotado) pode ter criado a
# máquina mesmo assim. Antes de cada rodada, confere: duas não cabem no grátis.
ja_existe() {
  local id
  id=$("$OCI" compute instance list -c "$T" --display-name "$NOME" \
    --query "data[?\"lifecycle-state\"!='TERMINATED' && \"lifecycle-state\"!='TERMINATING'] | [0].id" \
    --raw-output 2>/dev/null)
  ocid "$id" && echo "$id"
}

rodada=0
while :; do
  rodada=$((rodada + 1))
  if id=$(ja_existe); then
    log "PRONTO: a máquina $NOME já existe ($id). Siga o guia: IP reservado."
    exit 0
  fi

  espera=$INTERVALO
  for t in $TAMANHOS; do
    ocpu=${t%%:*}; gb=${t##*:}
    saida=$("$OCI" compute instance launch -c "$T" --availability-domain "$AD" \
      --display-name "$NOME" --shape VM.Standard.A1.Flex \
      --shape-config "{\"ocpus\": $ocpu, \"memoryInGBs\": $gb}" \
      --image-id "$IMAGEM" --subnet-id "$SUBNET" --assign-public-ip true \
      --ssh-authorized-keys-file "$HOME/.ssh/authorized_keys" \
      --query 'data.id' --raw-output 2>&1)
    if [ $? -eq 0 ]; then
      log "PRONTO: criada com $ocpu OCPU / $gb GB ($saida). Siga o guia: IP reservado."
      exit 0
    fi
    case "$saida" in
      *[Cc]apacity*)
        log "rodada $rodada: sem vaga para $ocpu OCPU / $gb GB" ;;
      *TooManyRequests*)
        log "rodada $rodada: a Oracle pediu calma; a próxima demora o dobro"
        espera=$((INTERVALO * 2)); break ;;
      *)
        log "rodada $rodada: erro inesperado:"
        echo "$saida" | head -15
        # Na primeira rodada, erro diferente de "sem vaga" é configuração
        # errada, e repetir não conserta. Depois, pode ser um tropeço da rede.
        [ "$rodada" -eq 1 ] && falha "corrija o erro acima e rode de novo"
        break ;;
    esac
  done

  [ "$UMA" -eq 1 ] && { log "fim da rodada única: a configuração está certa."; exit 0; }
  sleep "$espera"
done
