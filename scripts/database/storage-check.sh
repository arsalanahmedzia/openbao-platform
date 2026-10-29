#!/usr/bin/env bash
# storage-check.sh - checks that the backup storage (SeaweedFS S3) works.
# Run it: bash scripts/database/storage-check.sh (any time; after storage or backup changes)
# Changes the cluster: yes: starts one temporary pod in namespace databases,
#   writes and deletes one test file in the bucket, then deletes the pod.
#
# What it does:
#   1. Shows the SeaweedFS pod, volume and Service, and waits until the
#      Deployment is ready.
#        kubectl -n storage get pods,pvc,svc -o wide
#        kubectl -n storage rollout status deploy/seaweedfs --timeout=60s
#   2. Checks that the job that creates the bucket pg-backups has completed.
#        kubectl -n storage get job create-bucket-pg-backups
#   3. Starts a temporary pod in namespace databases with the PostgreSQL S3
#      keys (Secret s3-credentials) and does a round trip: upload a file,
#      download it, compare both, delete it. Then it counts the backup files
#      of pg-openbao. Same image and keys as the backups use.
#        kubectl -n databases run storage-check-<time> --image=amazon/aws-cli:2.37.13 ...
#        aws s3 cp / aws s3 ls / aws s3 rm   (inside the pod)
#   4. Shows the pod log and deletes the pod (also on failure or Ctrl+C).
#
# What you should see: PASS for the Deployment, the bucket job and
#   "S3 round trip", and an INFO line with the number of base backup and WAL
#   files. RESULT storage check passed.
# If it fails: "round trip failed" means S3 is not reachable from databases or
#   the keys are wrong (see docs/runbooks/postgres-backup-restore.md,
#   Troubleshooting). A pod stuck in Pending: no node has room; the script
#   gives up after 120 s.
# Needs: kubectl with access to the cluster, jq. The S3 keys stay in the
#   Secret; the script never prints them.
set -uo pipefail

IMAGE=amazon/aws-cli:2.37.13
ENDPOINT=http://seaweedfs.storage.svc:8333
POD=storage-check-$(date +%s)
FAILS=0
ts()   { date -u +%T; }
pass() { echo "$(ts) PASS  $*"; }
fail() { echo "$(ts) FAIL  $*"; FAILS=$((FAILS + 1)); }
info() { echo "$(ts) INFO  $*"; }

LOG=$(mktemp)
cleanup() { kubectl -n databases delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1; rm -f "$LOG"; }
trap cleanup EXIT

echo "==> 1. SeaweedFS"
kubectl -n storage get pods,pvc,svc -o wide
kubectl -n storage rollout status deploy/seaweedfs --timeout=60s >/dev/null 2>&1 \
  && pass "Deployment seaweedfs ready" || fail "Deployment seaweedfs not ready"

echo
echo "==> 2. Bucket job"
kubectl -n storage get job create-bucket-pg-backups
[[ "$(kubectl -n storage get job create-bucket-pg-backups -o jsonpath='{.status.succeeded}' 2>/dev/null)" == 1 ]] \
  && pass "job create-bucket-pg-backups completed" || fail "job create-bucket-pg-backups not completed"

echo
echo "==> 3. S3 round trip from namespace databases (temporary pod $POD)"
# Runs inside the pod; only object names, sizes and checksums are printed.
SCRIPT='set -e
E="--endpoint-url '"$ENDPOINT"'"
echo "storage-check $(date -u +%FT%TZ)" > /tmp/in.txt
aws $E s3 cp /tmp/in.txt s3://pg-backups/storage-check/in.txt
aws $E s3 ls s3://pg-backups/storage-check/
aws $E s3 cp s3://pg-backups/storage-check/in.txt /tmp/out.txt
md5sum /tmp/in.txt /tmp/out.txt
[ "$(md5sum < /tmp/in.txt)" = "$(md5sum < /tmp/out.txt)" ] && echo ROUNDTRIP_OK
aws $E s3 rm s3://pg-backups/storage-check/in.txt
echo "base backup files: $(aws $E s3 ls s3://pg-backups/pg-openbao/base/ --recursive | wc -l)"
echo "WAL files: $(aws $E s3 ls s3://pg-backups/pg-openbao/wals/ --recursive | wc -l)"'
OVERRIDES=$(jq -n --arg image "$IMAGE" --arg script "$SCRIPT" '{spec: {containers: [{
  name: "aws", image: $image, command: ["sh", "-c"], args: [$script],
  env: [
    {name: "AWS_DEFAULT_REGION", value: "us-east-1"},
    {name: "AWS_ACCESS_KEY_ID", valueFrom: {secretKeyRef: {name: "s3-credentials", key: "ACCESS_KEY_ID"}}},
    {name: "AWS_SECRET_ACCESS_KEY", valueFrom: {secretKeyRef: {name: "s3-credentials", key: "ACCESS_SECRET_KEY"}}}
  ]}]}}')
kubectl -n databases run "$POD" --restart=Never --image="$IMAGE" --overrides="$OVERRIDES" >/dev/null
for _ in $(seq 1 60); do
  phase=$(kubectl -n databases get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)
  [[ $phase == Succeeded || $phase == Failed ]] && break
  sleep 2
done
info "pod $POD: ${phase:-unknown}"
kubectl -n databases logs "$POD" > "$LOG" 2>&1
sed 's/^/        /' "$LOG"
grep -q ROUNDTRIP_OK "$LOG" && pass "S3 round trip (upload, download, same checksum, delete)" \
  || fail "S3 round trip failed"
grep -E '^(base backup|WAL) files' "$LOG" | while read -r l; do info "$l"; done

echo
(( FAILS == 0 )) && echo "$(ts) RESULT  storage check passed" \
  || { echo "$(ts) RESULT  storage check: $FAILS check(s) failed"; exit 1; }
