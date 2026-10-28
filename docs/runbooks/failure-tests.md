# Runbook: failure tests

Planned failures, run by hand on 2026-10-27, one at a time, with
`bash scripts/test-gate.sh` before the first test and after every test.
Evidence: `docs/evidence/07-f<N>-*.txt`.

| Test | What we broke | Result | Recovery time |
| --- | --- | --- | --- |
| F1 | Worker node with the active OpenBao pod and the PostgreSQL primary | OpenBao answered again through a standby; one pod sealed after the restart | OpenBao 76 s; ESO ~6 min; node rejoin 20 s |
| F2 | PostgreSQL primary pod deleted | Replica promoted; OpenBao writes failed only ~4-6 s; old primary back as replica | Failover 187 s; healthy after 213 s |

## F1. A worker node dies

**What we broke:** `docker stop openbao-platform-worker2`. That node ran the
active OpenBao pod, the PostgreSQL primary, the only ESO controller replica
and the Flux source- and helm-controller.

**What we expected:** OpenBao keeps answering through a standby after about a
minute; ESO and Flux recover after about 5 minutes; the restarted OpenBao pod
comes back sealed.

**What really happened:**

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
**sealed** and `pg-openbao-1` rejoined as a **replica**.
`scripts/openbao-unseal.sh` unsealed it as a standby; the gate passed.
The Kubernetes Secret `hello-from-openbao` kept its value the whole time.

**Different from the expectation:**
- `docker stop` is a clean shutdown (stop signal, 10 s grace), not a power
  loss: OpenBao sealed itself and removed its "active" label on the way out.
  A hard power loss was not tested.
- 76 s instead of about one minute.
- Flux controllers were replaced about 50 s before ESO; reason not checked.

**How to recover by hand:** start the node (`docker start <node>`, or
`bash scripts/resume.sh`), wait for `Ready`, then `bash scripts/openbao-unseal.sh`
and `bash scripts/test-gate.sh`.

**What we would change in production:**
- Most of the outage is the time Kubernetes needs to declare a node dead
  (about 40-50 s) before PostgreSQL fails over. Faster detection (shorter node
  monitor grace period, or CloudNativePG's own failover settings) shortens it,
  at the cost of false alarms.
- Run the ESO controller and the Flux controllers with 2 replicas, or a
  shorter toleration for unreachable nodes, so a node loss does not stop them
  for 5 minutes.
- Auto-unseal, so the restarted OpenBao pod rejoins without a person (R03).

## F2. The PostgreSQL primary dies

**What we broke:** `bash scripts/failure-f2-postgres.sh` deleted the primary
pod `pg-openbao-1`. A background probe wrote to OpenBao every 2 s as the ESO
login (`secret/pushed/f2-probe`), because a write must reach PostgreSQL.

**What we expected:** a replica promoted within seconds to about half a
minute (worst case up to the 180 s smart-shutdown limit); OpenBao writes
failing for a few seconds at most.

**What really happened:**

| Time after delete | Event |
| --- | --- |
| 0 - 186 s | Smart shutdown: the old primary refuses new connections, OpenBao's open connections keep working (93 writes ok) |
| 187 s | `pg-openbao-2` promoted |
| 187 - 191 s | 2 failed OpenBao writes: the only real outage, about 4-6 s |
| 213 s | Cluster healthy, 3 instances; `pg-openbao-1` back as a replica |

`secret/demo/hello` was readable as the ESO login afterwards; the gate passed.
The active OpenBao pod changed from `openbao-0` to `openbao-1` (probably it
could not renew its lock row during the switch; not verified).

**Different from the expectation:** the failover took the full 180 s
smart-shutdown time + 7 s, not "seconds to half a minute". CloudNativePG waits
for open connections, and OpenBao keeps a connection pool.

**Data loss:** replication is asynchronous; a write confirmed by the old
primary in its last moment may not have reached the new primary. Possible in
theory, not measured.

**What we would change in production:** never delete a primary pod for
maintenance: run `kubectl cnpg promote` (a switchover) first. If faster
failover after a crash-like deletion matters, set a shorter
`.spec.smartShutdownTimeout`, at the cost of cutting open sessions earlier.
Synchronous replication (`minSyncReplicas: 1`) closes the data-loss window at
the cost of write latency.
