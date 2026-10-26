#!/usr/bin/env bash
# Step 4 of the OpenBao stage, and after every pod or Codespace restart:
# unseals every sealed OpenBao pod with 3 of the 5 key shares.
# Keys come from the Codespaces secret OPENBAO_UNSEAL_KEYS (JSON list) or, if
# that is not set yet, from ~/openbao-init.json. They are passed to the pod
# through stdin (`bao write sys/unseal key=-`), never printed and never on a
# command line.
#   bash scripts/openbao-unseal.sh
set -euo pipefail

NS=openbao
SELECTOR=app.kubernetes.io/name=openbao,component=server
INIT_FILE="$HOME/openbao-init.json"

for tool in kubectl jq; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool"; exit 1; }
done

if [[ -n "${OPENBAO_UNSEAL_KEYS:-}" ]]; then
  mapfile -t KEYS < <(jq -r '.[]' <<<"$OPENBAO_UNSEAL_KEYS")
  echo "keys from: Codespaces secret OPENBAO_UNSEAL_KEYS"
elif [[ -r "$INIT_FILE" ]]; then
  mapfile -t KEYS < <(jq -r '.unseal_keys_b64[]' "$INIT_FILE")
  echo "keys from: $INIT_FILE"
else
  echo "no keys: set OPENBAO_UNSEAL_KEYS or provide $INIT_FILE"; exit 1
fi
(( ${#KEYS[@]} >= 3 )) || { echo "need at least 3 key shares, found ${#KEYS[@]}"; exit 1; }

# bao status exits with 2 while sealed, so read the JSON and ignore the code.
status_field() { kubectl -n "$NS" exec "$1" -- bao status -format=json 2>/dev/null | jq -r ".$2" || true; }

for pod in $(kubectl -n "$NS" get pods -l "$SELECTOR" -o jsonpath='{.items[*].metadata.name}'); do
  if [[ "$(status_field "$pod" initialized)" != "true" ]]; then
    echo "$pod: not initialised (run scripts/openbao-init.sh first)"; exit 1
  fi
  if [[ "$(status_field "$pod" sealed)" == "false" ]]; then
    echo "$pod: already unsealed"; continue
  fi
  for key in "${KEYS[@]:0:3}"; do
    printf '%s' "$key" | kubectl -n "$NS" exec -i "$pod" -- bao write sys/unseal key=- >/dev/null
    [[ "$(status_field "$pod" sealed)" == "false" ]] && break
  done
  [[ "$(status_field "$pod" sealed)" == "false" ]] && echo "$pod: unsealed" || { echo "$pod: STILL SEALED"; exit 1; }
done

echo
echo "==> Waiting for all pods to be Ready (readiness = unsealed)"
kubectl -n "$NS" wait pod -l "$SELECTOR" --for=condition=Ready --timeout=120s

echo
for pod in $(kubectl -n "$NS" get pods -l "$SELECTOR" -o jsonpath='{.items[*].metadata.name}'); do
  echo "--- $pod"
  kubectl -n "$NS" exec "$pod" -- bao status | grep -E '^(Initialized|Sealed|HA Enabled|HA Mode)'
done
