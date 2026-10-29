#!/usr/bin/env bash
# Hardening B1: are NetworkPolicies enforced in this cluster? (kind >= v0.24.0
# ships kube-network-policies with kindnet; this test proves it.)
# MANUAL TEMPORARY TEST, not from Git: creates namespace netpol-test with a
# server and a client pod (on different nodes), then
#   1. no policy               -> connection must work
#   2. deny-all ingress        -> connection must time out
#   3. deny-all + allow client -> connection must work again
# and deletes the namespace at the end, also if the script fails.
#   bash scripts/hardening/netpol-enforcement-test.sh
set -euo pipefail

NS=netpol-test
IMAGE=busybox:1.37.0
trap 'echo; echo "==> Cleanup: deleting namespace $NS"; kubectl delete namespace "$NS" --wait=false >/dev/null 2>&1 || true' EXIT

echo "==> Setup (temporary namespace $NS)"
kubectl create namespace "$NS"
kubectl apply -n "$NS" -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: server
  labels: {app: server}
spec:
  containers:
    - name: httpd
      image: $IMAGE
      command: ["sh", "-c", "echo ok > /tmp/index.html && exec httpd -f -p 8080 -h /tmp"]
---
apiVersion: v1
kind: Pod
metadata:
  name: client
  labels: {app: client}
spec:
  # different node than the server, so traffic crosses the node network
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector: {matchLabels: {app: server}}
          topologyKey: kubernetes.io/hostname
  containers:
    - name: client
      image: $IMAGE
      command: ["sleep", "3600"]
EOF
kubectl -n "$NS" wait pod --all --for=condition=Ready --timeout=120s
kubectl -n "$NS" get pods -o wide
SERVER_IP=$(kubectl -n "$NS" get pod server -o jsonpath='{.status.podIP}')

# probe <expected: ok|blocked>: client -> server:8080, 3 s timeout
RESULTS=()
probe() {
  local expected=$1 got
  if got=$(kubectl -n "$NS" exec client -- wget -q -T 3 -O - "http://$SERVER_IP:8080/" 2>/dev/null) && [[ "$got" == ok ]]; then
    got=ok
  else
    got=blocked
  fi
  if [[ "$got" == "$expected" ]]; then echo "PASS  expected $expected, got $got"; RESULTS+=(pass)
  else echo "FAIL  expected $expected, got $got"; RESULTS+=(fail); fi
}

echo
echo "==> 1. No NetworkPolicy: client -> server must work"
probe ok

echo
echo "==> 2. deny-all ingress policy: client -> server must be blocked"
kubectl apply -n "$NS" -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-ingress
spec:
  podSelector: {}
  policyTypes: [Ingress]
EOF
sleep 5
probe blocked

echo
echo "==> 3. plus allow app=client -> app=server TCP 8080: must work again"
kubectl apply -n "$NS" -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-client-to-server
spec:
  podSelector: {matchLabels: {app: server}}
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector: {matchLabels: {app: client}}
      ports:
        - {protocol: TCP, port: 8080}
EOF
sleep 5
probe ok

echo
if [[ " ${RESULTS[*]} " == *" fail "* ]]; then
  echo "RESULT: NetworkPolicies are NOT enforced as expected"; exit 1
fi
echo "RESULT: NetworkPolicies are enforced (deny and allow both work)"
