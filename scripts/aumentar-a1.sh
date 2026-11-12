#!/bin/bash
# Aumenta a máquina A1 que o `pedir-a1.sh` criou, até 4 OCPU / 24 GB.
#
# A A1 é "Flex": o tamanho muda na mesma máquina, sem criar outra. E é assim
# que se deve fazer. Uma segunda máquina somaria o tamanho das duas, passaria
# do limite grátis (4 OCPU / 24 GB no total) e, numa conta Pay As You Go,
# o excesso seria cobrado.
#
# **Cada tentativa que dá certo reinicia a máquina.** Por isso, rode antes de
# migrar o servidor para ela, enquanto ela está vazia (docs/migrar-para-a1.md).
#
# Como o pedido da máquina, a Oracle costuma responder "sem vaga" (o servidor
# físico onde ela está não tem núcleo sobrando) ou "acima do limite" (a conta
# ainda não pode ter 4 OCPU de A1). Os dois mudam com o tempo; o script tenta
# de novo a cada INTERVALO segundos até a máquina estar no tamanho pedido.
#
#   scripts/aumentar-a1.sh --uma        # uma tentativa
#   nohup scripts/aumentar-a1.sh >> ~/aumentar-a1.log 2>&1 &
set -u

OCI=${OCI:-$HOME/oci/bin/oci}
NOME=${NOME:-deskside-a1}
INTERVALO=${INTERVALO:-300}
OCPU=${OCPU:-4}
GB=${GB:-24}
UMA=0; [ "${1:-}" = "--uma" ] && UMA=1

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }
falha() { log "PAROU: $*"; exit 1; }
ocid() { case "$1" in ocid1.*) return 0 ;; *) return 1 ;; esac; }

[ -x "$OCI" ] || falha "não achei a linha de comando da Oracle em $OCI"
T=$(sed -n 's/^tenancy *= *//p' "$HOME/.oci/config" 2>/dev/null | head -1)
ocid "$T" || falha "não achei 'tenancy=' em ~/.oci/config"

ID=$("$OCI" compute instance list -c "$T" --display-name "$NOME" \
  --query "data[?\"lifecycle-state\"!='TERMINATED' && \"lifecycle-state\"!='TERMINATING'] | [0].id" \
  --raw-output 2>/dev/null)
ocid "$ID" || falha "não achei a máquina $NOME"

tamanho_atual() {
  "$OCI" compute instance get --instance-id "$ID" \
    --query 'data."shape-config".ocpus' --raw-output 2>/dev/null | cut -d. -f1
}

log "máquina $NOME encontrada · alvo $OCPU OCPU / $GB GB · a cada ${INTERVALO}s"

tentativa=0
while :; do
  tentativa=$((tentativa + 1))
  atual=$(tamanho_atual)
  if [ "${atual:-0}" -ge "$OCPU" ] 2>/dev/null; then
    log "PRONTO: a máquina já tem $atual OCPU."
    exit 0
  fi

  espera=$INTERVALO
  saida=$("$OCI" compute instance update --instance-id "$ID" --force \
    --shape-config "{\"ocpus\": $OCPU, \"memoryInGBs\": $GB}" \
    --query 'data."shape-config".ocpus' --raw-output 2>&1)
  if [ $? -eq 0 ]; then
    log "PRONTO: pedido aceito; a máquina reinicia com $OCPU OCPU / $GB GB."
    exit 0
  fi
  case "$saida" in
    *[Cc]apacity*)
      log "tentativa $tentativa: sem vaga para $OCPU OCPU / $GB GB nesse servidor" ;;
    *LimitExceeded*)
      log "tentativa $tentativa: $OCPU OCPU / $GB GB passa do limite da conta (Limites, Cotas e Uso)" ;;
    *TooManyRequests*)
      log "tentativa $tentativa: a Oracle pediu calma; a próxima demora o dobro"
      espera=$((INTERVALO * 2)) ;;
    *Conflict*|*IncorrectState*)
      # A máquina está ligando, desligando ou mudando: espera e tenta de novo.
      log "tentativa $tentativa: a máquina está mudando de estado; tento depois" ;;
    *)
      log "tentativa $tentativa: erro inesperado:"
      echo "$saida" | head -15
      [ "$tentativa" -eq 1 ] && falha "corrija o erro acima e rode de novo" ;;
  esac

  [ "$UMA" -eq 1 ] && { log "fim da tentativa única."; exit 0; }
  sleep "$espera"
done
