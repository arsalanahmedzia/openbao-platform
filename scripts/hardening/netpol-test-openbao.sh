#!/usr/bin/env bash
# netpol-test-openbao.sh - applies and proves the NetworkPolicies of namespace openbao (hardening B2c).
#
# Namespace openbao holds OpenBao. Its rules allow port 8200 (the API) only
# from Traefik, the ESO controller and the OpenBao pods themselves, and port
# 8201 (the cluster port, where standbys forward requests to the active pod)
# only between the OpenBao pods. This script applies the rules and proves
# them.
#
# Short-lived test pods show that Traefik and ESO get through and that an
# unlabelled pod and a pod in default are blocked. As real proof it calls
# OpenBao through Traefik over HTTPS, and it logs in as ESO on a standby
# pod: a login creates a token, which only the active pod can do, so it
# works only if the standby can forward it over 8201.
#
# Run it: bash scripts/hardening/netpol-test-openbao.sh (after git push of apps/openbao/networkpolicy.yaml)
# Changes the cluster: yes: starts temporary probe pods (kubectl run --rm) and
#   logs in once as the ESO service account. Tokens stay in variables and go to
#   the pod via stdin; only the demo value is shown.
#
# What it does:
#   1. Applies Git now.
#        flux reconcile kustomization apps-openbao
#   2. Probes with temporary pods, nc -w 3 <host> <port>:
#        open:    Traefik-labelled pod in traefik, ESO-labelled pod in
#                 external-secrets -> openbao-active:8200
#        blocked: unlabelled pod in external-secrets -> 8200, default -> 8200,
#                 default -> a standby pod's 8201
#   3. Real paths: HTTPS through Traefik; an ESO login ON A STANDBY pod (a login
#      writes a token, so the standby must forward it to the active pod over
#      8201; reads could be served by the standby itself); store still Valid.
#        curl --resolve openbao.demo.local:443:127.0.0.1 --cacert <ca> https://openbao.demo.local/v1/sys/health
#        kubectl -n openbao exec -i <standby> -- bao write -field=token auth/kubernetes/login role=external-secrets jwt=-
#
# What you should see: one PASS per probe, "HTTP 200", "login on standby: ok",
#   the demo value, then "RESULT: openbao policies work as intended".
# If it fails: the login on the standby fails: port 8201 between the OpenBao
#   pods is blocked.
# Needs: flux, kubectl, curl, the image busybox:1.37.0.
set -euo pipefail

IMAGE=busybox:1.37.0
NS=openbao
SELECTOR=app.kubernetes.io/name=openbao,component=server

echo "==> Flux: apply apps-openbao"
flux reconcile source git flux-system
flux reconcile kustomization apps-openbao
kubectl -n "$NS" get networkpolicy

# probe <namespace> <labels or -> <host> <port> <expected: open|blocked>
FAILS=0
probe() {
  local ns=$1 labels=$2 host=$3 port=$4 expected=$5 got args=() who=$1
  [[ "$labels" != - ]] && { args=(--labels="$labels"); who="$ns ($labels)"; }
  if kubectl -n "$ns" run "netpol-probe-$RANDOM" --image="$IMAGE" --restart=Never --rm -i --quiet "${args[@]}" \
       --command -- nc -w 3 "$host" "$port" </dev/null >/dev/null 2>&1; then got=open; else got=blocked; fi
  if [[ "$got" == "$expected" ]]; then echo "PASS  $who -> $host:$port expected $expected, got $got"
  else echo "FAIL  $who -> $host:$port expected $expected, got $got"; FAILS=$((FAILS + 1)); fi
}

ACTIVE_SVC=openbao-active.openbao.svc
STANDBY=$(kubectl -n "$NS" get pods -l "$SELECTOR,openbao-active=false" -o jsonpath='{.items[0].metadata.name}')
STANDBY_IP=$(kubectl -n "$NS" get pod "$STANDBY" -o jsonpath='{.status.podIP}')
echo
echo "==> Connectivity (standby $STANDBY = $STANDBY_IP)"
probe traefik app.kubernetes.io/name=traefik "$ACTIVE_SVC" 8200 open
probe external-secrets app.kubernetes.io/name=external-secrets "$ACTIVE_SVC" 8200 open
probe external-secrets - "$ACTIVE_SVC" 8200 blocked
probe default - "$ACTIVE_SVC" 8200 blocked
probe default - "$STANDBY_IP" 8201 blocked

echo
echo "==> Real path: HTTPS through Traefik"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
kubectl -n "$NS" get secret openbao-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "$TMP/ca.crt"
curl -sS --resolve openbao.demo.local:443:127.0.0.1 --cacert "$TMP/ca.crt" \
  -o /dev/null -w 'GET https://openbao.demo.local/v1/sys/health -> HTTP %{http_code}\n' \
  https://openbao.demo.local/v1/sys/health

echo
echo "==> Real path: ESO login on STANDBY $STANDBY (a write: forwarded to the active pod over 8201)"
JWT=$(kubectl -n external-secrets create token external-secrets --duration=10m)
ESO_TOKEN=$(printf '%s' "$JWT" |
  kubectl -n "$NS" exec -i "$STANDBY" -- bao write -field=token auth/kubernetes/login role=external-secrets jwt=-)
unset JWT
[[ -n "$ESO_TOKEN" ]] && echo "login on standby: ok (token created by the active pod)"
printf '%s\n' "$ESO_TOKEN" |
  kubectl -n "$NS" exec -i "$STANDBY" -- sh -c 'read -r BAO_TOKEN; export BAO_TOKEN; echo "secret/demo/hello via standby: $(bao kv get -mount=secret -field=message demo/hello)"; bao token revoke -self >/dev/null'
unset ESO_TOKEN

echo
echo "==> Real path: ESO store"
kubectl get clustersecretstore openbao

echo
(( FAILS == 0 )) && echo "RESULT: openbao policies work as intended" || { echo "RESULT: $FAILS check(s) failed"; exit 1; }
