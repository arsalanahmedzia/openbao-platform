#!/usr/bin/env bash
# Step 6a of the OpenBao stage: collects test evidence into docs/evidence/:
#   04-pods.txt      pods, nodes, active/sealed labels
#   04-status.txt    bao status of every pod
#   04-https.txt     /v1/sys/health through Traefik over HTTPS, checked with the demo CA
#   04-postgres.txt  OpenBao tables in database openbao, and a fresh base backup
# Prints no keys or tokens (none are used).
#   bash scripts/openbao-evidence.sh
set -euo pipefail
cd "$(dirname "$0")/.."

NS=openbao
SELECTOR=app.kubernetes.io/name=openbao,component=server
EV=docs/evidence
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# run <cmd...>: print the command and its output (for the evidence files)
run() { echo "\$ $*"; "$@"; echo; }

echo "==> $EV/04-pods.txt"
{
  echo "# OpenBao pods, captured $NOW"
  echo
  run kubectl -n "$NS" get pods -o wide
  run kubectl -n "$NS" get pods -L openbao-active,openbao-sealed
} > "$EV/04-pods.txt"

echo "==> $EV/04-status.txt"
{
  echo "# bao status per pod, captured $NOW"
  echo
  for pod in $(kubectl -n "$NS" get pods -l "$SELECTOR" -o jsonpath='{.items[*].metadata.name}'); do
    run kubectl -n "$NS" exec "$pod" -- bao status
  done
} > "$EV/04-status.txt"

echo "==> $EV/04-https.txt"
# Only the public CA certificate (ca.crt) is read from the Secret, not tls.key.
kubectl -n "$NS" get secret openbao-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "$TMP/ca.crt"
{
  echo "# HTTPS through Traefik (host port 443), certificate checked against demo-root-ca, captured $NOW"
  echo
  echo "\$ curl --resolve openbao.demo.local:443:127.0.0.1 --cacert ca.crt https://openbao.demo.local/v1/sys/health"
  curl -sS --resolve openbao.demo.local:443:127.0.0.1 --cacert "$TMP/ca.crt" \
    -w '\nHTTP %{http_code}\n' https://openbao.demo.local/v1/sys/health
  echo
  echo "# TLS details (curl -v, filtered)"
  curl -sv --resolve openbao.demo.local:443:127.0.0.1 --cacert "$TMP/ca.crt" \
    -o /dev/null https://openbao.demo.local/v1/sys/health 2>&1 |
    grep -E 'subject:|issuer:|expire date:|SSL certificate verify|SSL connection using' || true
} > "$EV/04-https.txt"

echo "==> $EV/04-postgres.txt (takes up to a few minutes: base backup)"
{
  echo "# PostgreSQL side of OpenBao, captured $NOW"
  echo
  echo "\$ kubectl cnpg psql pg-openbao -n databases -- -d openbao -c '\\dt'"
  kubectl cnpg psql pg-openbao -n databases -- -d openbao -c '\dt'
  echo
  echo "# Row counts only (no data): OpenBao writes encrypted entries"
  kubectl cnpg psql pg-openbao -n databases -- -d openbao -tA \
    -c 'select count(*) as kv_rows from openbao_kv_store' \
    -c 'select count(*) as ha_lock_rows from openbao_ha_locks'
  echo
  run kubectl cnpg backup pg-openbao -n databases \
    --method=plugin --plugin-name=barman-cloud.cloudnative-pg.io
  sleep 2
  BACKUP=$(kubectl -n databases get backup --sort-by=.metadata.creationTimestamp -o name | tail -1)
  for _ in $(seq 60); do
    phase=$(kubectl -n databases get "$BACKUP" -o jsonpath='{.status.phase}')
    [[ "$phase" == completed || "$phase" == failed ]] && break
    sleep 5
  done
  run kubectl -n databases get "$BACKUP" \
    -o jsonpath='{.metadata.name} phase={.status.phase} started={.status.startedAt} stopped={.status.stoppedAt}{"\n"}'
} > "$EV/04-postgres.txt"

echo
echo "Done. Review with: cat $EV/04-pods.txt $EV/04-status.txt $EV/04-https.txt $EV/04-postgres.txt"
