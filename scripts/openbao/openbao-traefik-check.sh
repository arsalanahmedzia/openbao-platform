#!/usr/bin/env bash
# openbao-traefik-check.sh - proves a secret can be read from outside the cluster through Traefik, and only with a valid login.
#
# Traefik is the HTTPS entry point of the cluster: a request to
# https://openbao.demo.local on port 443 reaches Traefik, which passes it on
# to the active OpenBao pod. Earlier tests only asked /v1/sys/health there,
# which is public. This script proves the whole path a person or a tool would
# use: log in from outside, get a token, read a secret with it.
#
# It checks both sides. Without a token OpenBao must refuse the read. With a
# token from a real login it must return the value. The login is the same
# Kubernetes login External Secrets uses (role external-secrets), so no root
# token is needed. The secret read is the demo value secret/demo/hello
# (hello-from-openbao), which protects nothing. At the end the token is
# revoked, and a last read with it must be refused again.
#
# Run it: bash scripts/openbao/openbao-traefik-check.sh (any time OpenBao is unsealed)
# Changes the cluster: yes, briefly: creates one OpenBao token (valid 15 min)
#   and revokes it at the end, also if the script fails. Nothing else changes.
#
# What it does:
#   1. Gets the public demo CA, so curl can check the certificate Traefik shows.
#        kubectl -n openbao get secret openbao-tls -o jsonpath='{.data.ca\.crt}'
#   2. Asks for the health status through Traefik (public, no token).
#        curl --resolve openbao.demo.local:443:127.0.0.1 --cacert <ca> https://openbao.demo.local/v1/sys/health
#   3. Tries to read the secret without a token: must be refused.
#        curl ... https://openbao.demo.local/v1/secret/data/demo/hello
#   4. Gets a 10-minute Kubernetes token for the ESO service account and logs
#      in to OpenBao with it, through Traefik. The JWT goes to curl through
#      stdin; the OpenBao token goes into a file only you can read.
#        kubectl -n external-secrets create token external-secrets --duration=10m
#        curl ... --data @- https://openbao.demo.local/v1/auth/kubernetes/login
#   5. Reads the secret with the token, through Traefik.
#        curl ... -H @<header file> https://openbao.demo.local/v1/secret/data/demo/hello
#   6. Revokes the token, then tries it once more: must be refused.
#        curl ... -X POST https://openbao.demo.local/v1/auth/token/revoke-self
#   7. Cleanup (trap, also on failure or Ctrl+C): revokes the token if it is
#      still valid and deletes the temporary files.
#
# What you should see: PASS for the health status (HTTP 200), the refused read
#   without a token (HTTP 403), the login, the value hello-from-openbao, the
#   revoke (HTTP 204) and the refused read after it (HTTP 403).
#   RESULT Traefik check passed.
# If it fails: HTTP 000 means curl could not connect or the certificate did not
#   match; check that Traefik runs (kubectl -n traefik get pods). HTTP 503 on
#   health means OpenBao is sealed: run scripts/after-restart/openbao-unseal.sh.
#   A failed login prints OpenBao's error message, never a token.
# Needs: kubectl, curl, jq. No token is printed; the token file is deleted.
set -uo pipefail

HOST=openbao.demo.local
URL=https://$HOST
FAILS=0
ts()   { date -u +%T; }
pass() { echo "$(ts) PASS  $*"; }
fail() { echo "$(ts) FAIL  $*"; FAILS=$((FAILS + 1)); }
info() { echo "$(ts) INFO  $*"; }

TMP=$(mktemp -d)
chmod 700 "$TMP"
CA=$TMP/ca.crt
HEADER=$TMP/header   # "X-Vault-Token: <token>", only readable by you
REVOKED=no

# bao <curl args...>: one request through Traefik, certificate checked with the demo CA
bao() { curl -s --resolve "$HOST:443:127.0.0.1" --cacert "$CA" "$@"; }

cleanup() {
  if [[ -s $HEADER && $REVOKED == no ]]; then
    bao -H @"$HEADER" -X POST "$URL/v1/auth/token/revoke-self" -o /dev/null
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "==> 1. Demo CA (public certificate, no secret)"
kubectl -n openbao get secret openbao-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "$CA"
[[ -s $CA ]] && pass "demo CA from Secret openbao/openbao-tls" || { fail "could not read the demo CA"; exit 1; }

echo
echo "==> 2. Health through Traefik (public, no token)"
code=$(bao -o /dev/null -w '%{http_code}' "$URL/v1/sys/health")
[[ $code == 200 ]] && pass "GET $URL/v1/sys/health -> HTTP $code (active and unsealed)" \
  || fail "GET $URL/v1/sys/health -> HTTP $code (expected 200)"

echo
echo "==> 3. Read the secret WITHOUT a token: must be refused"
code=$(bao -o /dev/null -w '%{http_code}' "$URL/v1/secret/data/demo/hello")
[[ $code == 403 ]] && pass "GET .../secret/data/demo/hello without a token -> HTTP $code (refused)" \
  || fail "GET .../secret/data/demo/hello without a token -> HTTP $code (expected 403)"

echo
echo "==> 4. Log in through Traefik as the ESO service account"
JWT=$(kubectl -n external-secrets create token external-secrets --duration=10m)
LOGIN=$(printf '{"role":"external-secrets","jwt":"%s"}' "$JWT" | bao --data @- "$URL/v1/auth/kubernetes/login")
unset JWT
TOKEN=$(jq -r '.auth.client_token // empty' <<<"$LOGIN")
if [[ -n $TOKEN ]]; then
  ( umask 077; printf 'X-Vault-Token: %s\n' "$TOKEN" > "$HEADER" )
  pass "login ok; policies: $(jq -c '.auth.policies' <<<"$LOGIN"), valid $(jq -r '.auth.lease_duration' <<<"$LOGIN") s"
else
  fail "login failed: $(jq -c '.errors // .' <<<"$LOGIN")"
fi
unset TOKEN LOGIN

echo
echo "==> 5. Read the secret WITH the token, through Traefik"
if [[ -s $HEADER ]]; then
  value=$(bao -H @"$HEADER" "$URL/v1/secret/data/demo/hello" | jq -r '.data.data.message // empty')
  [[ $value == hello-from-openbao ]] && pass "secret/demo/hello through Traefik: $value" \
    || fail "secret/demo/hello through Traefik: '${value:-no value}' (expected hello-from-openbao)"
else
  fail "no token, read skipped"
fi

echo
echo "==> 6. Revoke the token, then try it again: must be refused"
if [[ -s $HEADER ]]; then
  code=$(bao -H @"$HEADER" -X POST -o /dev/null -w '%{http_code}' "$URL/v1/auth/token/revoke-self")
  if [[ $code == 204 ]]; then REVOKED=yes; pass "token revoked -> HTTP $code"; else fail "revoke -> HTTP $code (expected 204)"; fi
  code=$(bao -H @"$HEADER" -o /dev/null -w '%{http_code}' "$URL/v1/secret/data/demo/hello")
  [[ $code == 403 ]] && pass "read with the revoked token -> HTTP $code (refused)" \
    || fail "read with the revoked token -> HTTP $code (expected 403)"
else
  info "no token to revoke"
fi

echo
(( FAILS == 0 )) && echo "$(ts) RESULT  Traefik check passed" \
  || { echo "$(ts) RESULT  Traefik check: $FAILS check(s) failed"; exit 1; }
