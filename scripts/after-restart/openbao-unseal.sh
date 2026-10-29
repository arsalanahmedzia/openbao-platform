#!/usr/bin/env bash
# openbao-unseal.sh - unseals every sealed OpenBao pod with 3 of the 5 key shares.
#
# OpenBao keeps its data encrypted. Every OpenBao pod starts sealed: it runs
# but cannot read its own data, and it answers no secret requests until it
# is unsealed. Unsealing needs 3 of the 5 key shares (pieces of the key)
# created when OpenBao was first set up.
#
# This script takes the shares from the Codespaces secret
# OPENBAO_UNSEAL_KEYS (or from ~/openbao-init.json), finds every sealed pod
# and hands it shares one at a time until it is unsealed. The shares go into
# the pod through stdin, so they never appear on the screen, in the shell
# history or in the process list. Pods that are already unsealed are
# skipped, so it is safe to run as often as you like. At the end one pod is
# active and two are standby.
#
# Run it: bash scripts/after-restart/openbao-unseal.sh (after every OpenBao pod or Codespace restart; safe to repeat)
# Changes the cluster: yes: unseals sealed pods. Unsealed pods are skipped.
#
# What it does:
#   1. Reads the key shares from the Codespaces secret OPENBAO_UNSEAL_KEYS (JSON
#      list) or, if that is not set, from ~/openbao-init.json.
#   2. For each pod, waits up to 3 minutes for an answer from bao status (right
#      after a restart the pod or PostgreSQL may still be starting).
#        kubectl -n openbao exec <pod> -- bao status -format=json
#   3. Gives each sealed pod one share at a time through stdin, never on the
#      command line or the screen, until it is unsealed.
#        printf '%s' <share> | kubectl -n openbao exec -i <pod> -- bao write sys/unseal key=-
#   4. Waits until all pods are Ready (readiness = unsealed) and shows their status.
#        kubectl -n openbao wait pod -l app.kubernetes.io/name=openbao,component=server --for=condition=Ready --timeout=120s
#
# What you should see: "keys from: ...", then "<pod>: unsealed" or "already
#   unsealed" per pod, and per pod "Sealed false" with "HA Mode active" for one
#   pod and "standby" for the others.
# If it fails: "not initialised" means run scripts/openbao/openbao-init.sh
#   first; "no answer from bao status after 3 minutes" shows the last error
#   (pod starting, or PostgreSQL not ready).
# Needs: kubectl, jq, OPENBAO_UNSEAL_KEYS or ~/openbao-init.json.
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
  # No answer is not the same as "not initialised": right after a restart the
  # pod may still be starting, or PostgreSQL (which holds the init state) may
  # not be ready yet. Wait up to 3 minutes for a real answer.
  init=""
  for _ in $(seq 36); do
    init=$(status_field "$pod" initialized)
    [[ "$init" == true || "$init" == false ]] && break
    sleep 5
  done
  if [[ "$init" == false ]]; then
    echo "$pod: not initialised (run scripts/openbao/openbao-init.sh first)"; exit 1
  elif [[ "$init" != true ]]; then
    echo "$pod: no answer from bao status after 3 minutes (pod starting, or PostgreSQL not ready). Last error:"
    kubectl -n "$NS" exec "$pod" -- bao status 2>&1 | tail -3 || true
    exit 1
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
