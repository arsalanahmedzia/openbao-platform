# Runbook: OpenBao init, unseal and recovery

OpenBao runs as StatefulSet `openbao/openbao` (3 pods, one active, two
standby) with all data in PostgreSQL `databases/pg-openbao`. Design:
[ADR 0004](../adr/0004-openbao-ha-postgresql.md). Tested on 2026-10-26,
evidence in `docs/evidence/04-*.txt`.

Terms:
- **Sealed**: the pod is running but cannot decrypt anything; it answers only
  status and unseal requests. Every pod starts sealed.
- **Key shares**: the key that unlocks OpenBao's encryption key is split into
  5 shares; any 3 unseal a pod (`Total Shares 5`, `Threshold 3`).
- **Active / standby**: the pod holding the lock row in `openbao_ha_locks` is
  active and serves requests; standbys wait to take over.

Where the secrets are (never in Git, never printed):
- `~/openbao-init.json` in the Codespace (`chmod 600`), plus your own copy
  outside the Codespace.
- Codespaces secrets `OPENBAO_UNSEAL_KEYS` (JSON list of the 5 shares) and
  `OPENBAO_ROOT_TOKEN`; they appear as environment variables in a new or
  restarted Codespace.

## 1. First start (once per new OpenBao, i.e. empty database)

```bash
bash scripts/openbao-deploy-check.sh   # 3 pods Running 0/1, Initialized false
bash scripts/openbao-init.sh           # "initialised, keys saved to ..."
bash scripts/openbao-unseal.sh         # all pods unsealed, 1 active, 2 standby
bash scripts/openbao-configure.sh      # KV v2, Kubernetes auth, policies, role
```

`openbao-init.sh` refuses to run if `~/openbao-init.json` exists or the pod
reports `initialized=true`. Download `~/openbao-init.json` (Explorer, right
click, Download) and keep it somewhere safe outside the Codespace.

## 2. After a restart (Codespace, node or all pods)

```bash
bash scripts/resume.sh                 # Codespace only: nodes back
kubectl -n openbao get pods            # wait for 3 x Running (0/1 = sealed)
bash scripts/openbao-unseal.sh
```

Expected: `openbao-N: unsealed` for each sealed pod, then all `1/1` and one
`HA Mode active`. The script is safe to repeat; unsealed pods are skipped.

## 3. One pod fails or is deleted

Nothing to do for the service: if it was the active pod, a standby takes the
lock within seconds (measured: about 7 s). The StatefulSet recreates the pod;
it comes back **sealed** (`0/1`, label `openbao-sealed=true`). Unseal it:

```bash
kubectl -n openbao get pods -L openbao-active,openbao-sealed
bash scripts/openbao-unseal.sh
```

Test again any time with `bash scripts/openbao-failover-test.sh` (deletes the
active pod, asks first).

If a pod stays `Pending` after a node failure: required anti-affinity allows
one pod per worker, so it waits until the worker is back. OpenBao keeps
running with the other pods.

## 4. Config change from Git

The chart uses `updateStrategy: OnDelete`: Flux updates the StatefulSet, but
running pods keep the old config until deleted. Roll it by hand, standbys
first, one at a time:

```bash
kubectl -n openbao get pods -L openbao-active
kubectl -n openbao delete pod <standby>   # wait until Running
bash scripts/openbao-unseal.sh            # repeat for the other standby
kubectl -n openbao delete pod <active>    # a standby takes over
bash scripts/openbao-unseal.sh
```

The same applies after rotating the database password
(`bash scripts/openbao-db-secret.sh --force`, commit, push): the pods only read
`BAO_PG_CONNECTION_URL` at start. CloudNativePG changes the role's password
right away, so restart all OpenBao pods promptly after Flux applied it.

## 5. Lost keys: what can and cannot be recovered

- **Fewer than 3 shares left** (file, copy and Codespaces secrets lost): the
  data in PostgreSQL **cannot be decrypted by anyone**. Backups of
  `pg-openbao` do not help: they contain the same encrypted data. The only way
  forward is a new, empty OpenBao: drop and recreate the tables (or a new
  database), run section 1, and recreate every secret from its source.
- **3 or more shares left**: everything works. Make new shares at once with
  `bao operator rekey` (needs 3 current shares) and store them again.
- **Root token lost**: not a problem; create a new one with a quorum of shares
  (section 6).
- **Key shares leaked**: rekey (`bao operator rekey`) so the old shares become
  useless; the encryption key itself can be rotated with `bao operator rotate`.

## 6. Root token: revoke and generate when needed

After `openbao-configure.sh` the root token should not be used. To revoke it
(token through stdin, as in the scripts; pod = the active one):

```bash
POD=$(kubectl -n openbao get pods -l openbao-active=true -o jsonpath='{.items[0].metadata.name}')
jq -r .root_token ~/openbao-init.json |
  kubectl -n openbao exec -i "$POD" -- sh -c 'read -r BAO_TOKEN; export BAO_TOKEN; bao token revoke -self'
```

Expected: `Success! Revoked token (if it existed)`. The value in
`~/openbao-init.json` and in `OPENBAO_ROOT_TOKEN` is then useless.

To get a new root token later, `bao operator generate-root` combines a
one-time password with 3 key shares (`-init`, then 3 times with a share, then
`-decode`). It is an interactive procedure: run it in a terminal session
inside the active pod (`kubectl -n openbao exec -it <pod> -- sh`) and revoke
the new token again when done.

## 7. Reach the UI

HTTPS through Traefik from inside the Codespace:

```bash
kubectl -n openbao get secret openbao-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/openbao-ca.crt
curl --resolve openbao.demo.local:443:127.0.0.1 --cacert /tmp/openbao-ca.crt \
  https://openbao.demo.local/v1/sys/health
```

From your browser (fallback, plain HTTP through a tunnel):

```bash
kubectl -n openbao port-forward svc/openbao-active 8200:8200
```

Codespaces offers to open forwarded port 8200; add `/ui` to the URL. Logging
in needs a token; for the demo, log in only to show the UI and do not keep a
root token around for it.

## 8. Restore of PostgreSQL and OpenBao

A point-in-time restore of `pg-openbao` (see
[postgres-backup-restore.md](postgres-backup-restore.md)) brings back
OpenBao's encrypted data as of that time; the same unseal keys still work
(they belong to the data). If OpenBao should use a restored cluster, set
`bootstrap.recovery.secret.name: pg-openbao-openbao` in the restore manifest so
the role `openbao` gets the password OpenBao knows, point the connection URL at
the new cluster's `-rw` Service, restart the OpenBao pods and unseal them.
