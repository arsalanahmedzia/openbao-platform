# Runbook: failure tests

Planned failures, run by hand on 2026-10-27, one at a time, with
`bash scripts/checks/test-gate.sh` before the first test and after every test.
Evidence: `docs/evidence/07-f<N>-*.txt`.

| Test | What we broke | Result | Recovery time |
| --- | --- | --- | --- |
| F1 | Worker node with the active OpenBao pod and the PostgreSQL primary | OpenBao answered again through a standby; one pod sealed after the restart | OpenBao 76 s; ESO ~6 min; node rejoin 20 s |
| F2 | PostgreSQL primary pod deleted | Replica promoted; OpenBao writes failed only ~4-6 s; old primary back as replica | Failover 187 s; healthy after 213 s |
| F3 | All 3 OpenBao pods restarted (sealed) while ESO runs | Secret kept its value; ESO errors after ~90 s; recovered by itself after unseal, no ESO restart | ExternalSecret 16 s after unseal |
| F4 | PushSecret deleted (Flux paused) | Value and all versions deleted in OpenBao; Flux recreated the PushSecret, value back | Deleted after 1 s; back 2 s after Flux resumed |
| F5 | ESO controller pod deleted | New pod logged in with new tokens (audit log), synced; Secret untouched | New pod 1 s; synced 6 s |
| F6 | Point-in-time restore into a new cluster | Restored exactly to the target time: row A present, row B absent; cleaned up | Restore cluster healthy after 71 s |

## F1. A worker node dies

What we broke: `docker stop openbao-platform-worker2`. That node ran the
active OpenBao pod, the PostgreSQL primary, the only ESO controller replica
and the Flux source- and helm-controller.

What we expected: OpenBao keeps answering through a standby after about a
minute; ESO and Flux recover after about 5 minutes; the restarted OpenBao pod
comes back sealed.

What really happened:

| Time after stop | Event |
| --- | --- |
| 0 s | worker2 stopped |
| 54 s | Kubernetes marks worker2 `NotReady` |
| 61 s | CloudNativePG promotes `pg-openbao-2` to primary |
| 68 s | OpenBao standby `openbao-2` takes the lock and becomes active |
| 76 s | OpenBao answers `200` through Traefik again |
| ~5 min | Flux source- and helm-controller restarted on other workers |
| ~6 min | ESO controller restarted on worker3; store `Valid`, sync OK |

After `docker start`, worker2 was `Ready` after 20 s, `openbao-0` came back
sealed and `pg-openbao-1` rejoined as a replica.
`scripts/after-restart/openbao-unseal.sh` unsealed it as a standby; the gate passed.
The Kubernetes Secret `hello-from-openbao` kept its value the whole time.

Different from the expectation:
- `docker stop` is a clean shutdown (stop signal, 10 s grace), not a power
  loss: OpenBao sealed itself and removed its "active" label on the way out.
  A hard power loss was not tested.
- 76 s instead of about one minute.
- Flux controllers were replaced about 50 s before ESO; reason not checked.

How to recover by hand: start the node (`docker start <node>`, or
`bash scripts/after-restart/resume.sh`), wait for `Ready`, then `bash scripts/after-restart/openbao-unseal.sh`
and `bash scripts/checks/test-gate.sh`.

What we would change in production:
- Most of the outage is the time Kubernetes needs to declare a node dead
  (about 40-50 s) before PostgreSQL fails over. Faster detection (shorter node
  monitor grace period, or CloudNativePG's own failover settings) shortens it,
  at the cost of false alarms.
- Run the ESO controller and the Flux controllers with 2 replicas, or a
  shorter toleration for unreachable nodes, so a node loss does not stop them
  for 5 minutes.
- Auto-unseal, so the restarted OpenBao pod rejoins without a person (R03).

## F2. The PostgreSQL primary dies

What we broke: `bash scripts/failure-tests/failure-f2-postgres.sh` deleted the primary
pod `pg-openbao-1`. A background probe wrote to OpenBao every 2 s as the ESO
login (`secret/pushed/f2-probe`), because a write must reach PostgreSQL.

What we expected: a replica promoted within seconds to about half a
minute (worst case up to the 180 s smart-shutdown limit); OpenBao writes
failing for a few seconds at most.

What really happened:

| Time after delete | Event |
| --- | --- |
| 0 - 186 s | Smart shutdown: the old primary refuses new connections, OpenBao's open connections keep working (93 writes ok) |
| 187 s | `pg-openbao-2` promoted |
| 187 - 191 s | 2 failed OpenBao writes: the only real outage, about 4-6 s |
| 213 s | Cluster healthy, 3 instances; `pg-openbao-1` back as a replica |

`secret/demo/hello` was readable as the ESO login afterwards; the gate passed.
The active OpenBao pod changed from `openbao-0` to `openbao-1` (probably it
could not renew its lock row during the switch; not verified).

Different from the expectation: the failover took the full 180 s
smart-shutdown time + 7 s, not "seconds to half a minute". CloudNativePG waits
for open connections, and OpenBao keeps a connection pool.

Data loss: replication is asynchronous; a write confirmed by the old
primary in its last moment may not have reached the new primary. Possible in
theory, not measured.

What we would change in production: never delete a primary pod for
maintenance: run `kubectl cnpg promote` (a switchover) first. If faster
failover after a crash-like deletion matters, set a shorter
`.spec.smartShutdownTimeout`, at the cost of cutting open sessions earlier.
Synchronous replication (`minSyncReplicas: 1`) closes the data-loss window at
the cost of write latency.

## F3. OpenBao is sealed while ESO runs

What we broke: `bash scripts/failure-tests/failure-f3-sealed.sh` deleted all three
OpenBao pods. They came back sealed after 20 s; the script unsealed them after
153 s (keys via stdin).

What we expected: the Kubernetes Secret keeps its last value; ESO reports
errors while OpenBao is sealed; after unsealing everything recovers by itself
without restarting ESO, possibly only after minutes (retry pauses).

What really happened:

| Time | Event |
| --- | --- |
| +20 s | All OpenBao pods back, sealed |
| up to +82 s | ExternalSecret `hello` still `SecretSynced` |
| ~+97 s | ExternalSecret `SecretSyncedError`; ESO log: login to OpenBao times out |
| whole outage | Store shows `True Valid`; Secret value unchanged and not rewritten |
| unseal +11 s / +16 s | Store and ExternalSecret Ready again, no ESO restart |

Different from the expectation:
- The store status never showed the outage; only the ExternalSecret did.
- ESO reported the error only after ~90 s (reason not verified).
- Recovery took 16 s, not minutes: after a short outage ESO's retry pauses
  are still short. After a long outage (seen the same morning) they grow to
  ~7 minutes, and recovery waits for the next retry.

What we would change in production: alert on ExternalSecret conditions
(`Ready=False`), not on the store status; auto-unseal (R03) so a restart does
not need a person; apps should read the Kubernetes Secret, which survives an
OpenBao outage.

## F4. The PushSecret is deleted

What we broke: `bash scripts/failure-tests/failure-f4-pushsecret.sh` suspended the Flux
kustomization `apps-external-secrets` (so Flux could not recreate the object
during the test) and deleted the PushSecret `push-demo`.

What we expected: with `deletionPolicy: Delete`, ESO deletes
`secret/pushed/push-demo` in OpenBao; after Flux resumes, the PushSecret comes
back from Git and the value is pushed again.

What really happened: the PushSecret was gone at once (ESO's finalizer
acted in the same second), the value and its metadata (all versions) were gone
from OpenBao 1 s later, and the Kubernetes source Secret stayed. After
`flux resume`, Flux recreated the PushSecret and the value was back in OpenBao
2 s later, as version 1 (created from scratch). Checked as the ESO login. The
gate passed. As expected.

How to recover by hand: `flux resume kustomization apps-external-secrets`
(or `flux reconcile kustomization apps-external-secrets`) recreates the
PushSecret from Git; ESO pushes the value again.

What we would change in production: use `deletionPolicy: Delete` only
where Kubernetes is the source of truth (R21), and review PushSecret deletions
in pull requests: a removed PushSecret deletes the value and its history in
OpenBao for good.

## F5. ESO restarts

What we broke: `bash scripts/failure-tests/failure-f5-eso-restart.sh` deleted the ESO
controller pod; the Deployment started a new one.

What we expected: the Kubernetes Secret is untouched; the new pod logs in
to OpenBao again with a new token; the store is `Valid` again.

What really happened: the new pod was Ready after 1 s and synced
`hello` 6 s after the delete. The Secret was not changed (same
resourceVersion). The OpenBao audit log shows logins by `external-secrets`
from the new pod's IP with new tokens (only hashes in the log). The gate
passed. As expected.

Also seen: ESO logs in on every sync (about two logins per 30 s cycle),
creating a new short-lived token each time, not one token per pod.

What we would change in production: run 2 ESO controller replicas (only
one is active, the other takes over without waiting for a new pod); with many
ExternalSecrets, use a longer refresh interval or ESO's client caching to cut
logins to OpenBao (check the ESO docs for the option before enabling it).

## F6. Restore from backup (point-in-time recovery)

What we did: `bash scripts/failure-tests/failure-f6-restore.sh` wrote row A into the
live cluster (database `postgres`), noted a target time, wrote row B, forced
a WAL switch and waited until it was archived, then created a temporary
cluster `pg-restore-test` from the S3 backup with `recoveryTarget.targetTime`
(same spec as `docs/runbooks/restore-example.yaml`), checked the data and
deleted the restore cluster again.

What we expected: the restored cluster starts and contains the data up to
the target time, nothing after it.

What really happened: healthy after 71 s; row A present, row B absent;
both databases (`postgres`, `openbao`) restored. Nothing named
`pg-restore-test` left afterwards; the gate passed. As expected.

Found on the way:
- The B2 NetworkPolicy only allowed the operator to reach `pg-openbao`'s
  instance manager, so any restore cluster would have hung. Fixed in Git
  before the test: the rule now covers every CloudNativePG instance.
- The daily backup of 2026-10-27 12:00 UTC ran at 14:51 UTC, when the
  Codespace was started again: missed slots run late (R06).
- `kubectl cnpg psql` output ends lines with a carriage return; strip it
  before using values in scripts.

What we would change in production: run a restore test regularly
(e.g. monthly) and alert on its result; keep the backups outside the cluster
(R05); measure restore time against the recovery-time goal as the database
grows.
