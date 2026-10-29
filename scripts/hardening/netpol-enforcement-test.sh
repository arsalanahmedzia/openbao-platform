#!/usr/bin/env bash
# netpol-enforcement-test.sh - proves that this cluster enforces NetworkPolicies at all (hardening B1).
#
# In plain words:
#   A NetworkPolicy (a Kubernetes rule for which pods may connect to which)
#   only works if the cluster's network enforces it; otherwise Kubernetes
#   accepts the rule and silently ignores it. This script proves that this
#   cluster enforces them, before any other rule is trusted.
#
#   It works in its own temporary namespace, so nothing else is touched: one
#   web server pod and one client pod on another node. With no rule the client
#   must reach the server; with a deny-all rule it must be blocked; with an
#   extra allow rule for the client it must get through again. The namespace
#   is deleted at the end, also if the script fails.
#
# Run it: bash scripts/hardening/netpol-enforcement-test.sh (once per new cluster, before trusting any policy)
# Changes the cluster: yes: MANUAL TEMPORARY TEST, not from Git. Creates
#   namespace netpol-test with a server and a client pod (on different nodes)
#   and deletes the namespace at the end, also if the script fails. kind >=
#   v0.24.0 ships kube-network-policies with kindnet; this test proves it.
#
# What it does:
#   1. Creates the namespace, a busybox web server on port 8080 and a client on
#      another node.
#        kubectl create namespace netpol-test ; kubectl apply -n netpol-test -f -
#   2. No policy: client -> server must work.
#   3. Adds a deny-all ingress policy: the connection must time out.
#   4. Adds an allow rule app=client -> app=server TCP 8080: it must work again.
#   5. Cleanup (trap): deletes the namespace.
#        kubectl delete namespace netpol-test
#
# What you should see: three PASS lines (ok, blocked, ok) and
#   "RESULT: NetworkPolicies are enforced (deny and allow both work)".
# If it fails: "blocked" still working means the cluster ignores
#   NetworkPolicies; no other policy in this repo would then have any effect.
# Needs: kubectl, the image busybox:1.37.0.
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
