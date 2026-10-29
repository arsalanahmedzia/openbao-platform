# Task brief: failure-test stage

Read CLAUDE.md, docs/risk-assessment.md and docs/runbooks/ first. All rules in CLAUDE.md still apply.
The platform is built and hardened. This stage breaks things on purpose and shows what happens.
It is a requirement of the task, so do not shorten it.

## Rules (same as the earlier stages)

- **One short script per test**, clear name, comments at the top, so I only run
  `bash scripts/<name>.sh`. Long commands go inside the script, not into my terminal.
  You write and commit the scripts. **I run every command that touches the cluster.** You do not
  run kubectl, flux, bao, docker or bootstrap yourself.
- A script that breaks something **asks before it starts** (y/N) and **puts everything back at
  the end**, also when it fails (use a `trap`). It prints plain `PASS` / `FAIL` / `INFO` lines
  and the times (`date -u`) of each phase, so the output is the evidence.
- Before each test: two plain sentences (what we break, what we expect). After each test: which
  output means it worked. Then wait for me.
- At the top of each script, comments in plain English: what it does, in numbered steps, and the
  real commands it runs (I must be able to explain them).
- Never print a token, key share or secret value. For OpenBao access use the login-as-ESO
  pattern from scripts/eso-pull-check.sh. If a test needs the root token, ask me first.
- For evidence each script writes `docs/evidence/07-f<N>-<name>.txt` with `tee`, and you scan the
  file for tokens and keys before committing.
- **Test gate:** run `bash scripts/test-gate.sh` before the first test, and after every test.
  If it does not say `GATE PASSED` after a test, we fix that first. No second test on a broken platform.
- **Time box:** about 30 minutes per test. If one is stuck, stop, put it back, record it as a
  known gap with the reason in docs/risk-assessment.md, and go on.
- If a result is different from what you expected, say so. Do not change the expectation afterwards.
- If you are unsure about a command, check the docs or `--help` and say that you are unsure.

## Start state (I do this, not you)

`bash scripts/resume.sh`, `bash scripts/openbao-unseal.sh`, `bash scripts/test-gate.sh` must be green.
Every script checks this at the start and stops if it is not true.

## Tests, in this order

**F1. A worker node dies.**
Stop one worker (`docker stop <worker>`, ask me which one; pick one that runs an OpenBao pod
and, if possible, a PostgreSQL pod). Watch: which pods are lost, how long until OpenBao answers
again, whether ESO still syncs, whether Flux stays healthy. Then start the worker again
(`docker start`) and show the pods come back. OpenBao pods that restart come back **sealed**:
the script shows that, then runs `bash scripts/openbao-unseal.sh`.
Expected: OpenBao keeps answering through a standby; one pod is sealed after the restart.

**F2. The PostgreSQL primary dies.**
Delete the primary pod of `pg-openbao`. Show which replica becomes primary, how long it takes,
that OpenBao keeps working (read `secret/demo/hello` as the ESO login), and that
`kubectl cnpg status pg-openbao -n databases` is healthy afterwards with 3 instances.
Expected: automatic failover in seconds to about a minute; async replication means a small
data-loss window is possible in theory. Say that in the evidence.

**F3. OpenBao is sealed while ESO runs.**
Seal the active OpenBao pod, or all three if that is easy. If that needs the root token, say so
and ask me first; a pod restart also seals the pod and needs no token.
Watch: ESO store status, the ExternalSecret `hello`, the existing Kubernetes Secret
`hello-from-openbao` (does it keep its last value?), and the ESO log. Then unseal and show the
store becomes `Valid` again by itself.
Expected: apps keep the last known Secret; ESO reports errors until OpenBao is unsealed; no restart needed.

**F4. The PushSecret is deleted.**
Delete the PushSecret `push-demo` in `eso-demo` (the repo still has it, so Flux will recreate
it: say which of the two things you see first, and make the test deterministic, for example
by suspending the Flux kustomization `apps-external-secrets` for the test and resuming after).
Show that `secret/pushed/push-demo` disappears in OpenBao (`deletionPolicy: Delete`), then that
Flux recreates the PushSecret and the value comes back.
Expected: value removed, then restored after Flux resumes.

**F5. ESO restarts.**
Delete the ESO controller pod. Show that the Secret is untouched, the new pod logs in again with
a new token, and the store is `Valid` again.

**F6. Restore from backup (point-in-time recovery).**
Follow docs/runbooks/postgres-backup-restore.md and docs/runbooks/restore-example.yaml.
Do **not** touch the live cluster `pg-openbao`. Restore into a **new** cluster (for example
`pg-restore-test`) in the `databases` namespace from the S3 backup, to a point in time that
you pick after writing a marker value (create a test row, note the time, create another row,
restore to the time between them). Show the first row exists and the second does not.
Then delete the restore cluster and everything it created.
A restore cluster needs NetworkPolicy access to S3: check the policies in apps/database and
infrastructure/storage and tell me before changing anything.
Expected: restored cluster starts, contains the data up to the chosen time, nothing after it.
Also check the scheduled backup: `kubectl -n databases get backups` should show a run from the
schedule (12:00 UTC). Say if it is missing.

**F7 (optional, only if time is left). Unseal after a full restart.**
Prove that `scripts/openbao-unseal.sh` works with `OPENBAO_UNSEAL_KEYS` from the Codespaces
secret and without `~/openbao-init.json`. Do not delete the init file yourself: tell me when
it is safe and I do it.

## Deliverables

- One script per test: `scripts/failure-f1-worker.sh`, `failure-f2-postgres.sh`,
  `failure-f3-sealed.sh`, `failure-f4-pushsecret.sh`, `failure-f5-eso-restart.sh`,
  `failure-f6-restore.sh` (F7 only if time is left). F1 is already done by hand: write its
  script anyway so it can be repeated, but I do not need to run it again.
- One evidence file per test: `docs/evidence/07-f<N>-<name>.txt`, scanned for tokens and keys
  before commit.
- `docs/runbooks/failure-tests.md`: for each test, what we break, what we expect, what really
  happened, how long recovery took, and what we would change in production.
- `docs/adr/0007-failure-test-results.md` is optional: only if a result changes a decision.
- `docs/risk-assessment.md` updated: which risks are now proven (R-numbers), which gaps are
  confirmed, and any new risk you found.
- `docs/time-log.md`: one entry.
- Small commits, plain messages, one test per commit.

## Final summary (at the end)

Plain English, no analogies:
- a table: test, what we broke, result, recovery time
- five sentences I must be able to explain in the interview, each with its reason
- every place where you were unsure or did not verify something
- every result that was different from the expectation
- what is left for cleanup (root token, GitHub tokens, deploy keys, age key)
