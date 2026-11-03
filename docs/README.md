# Docs

The platform overview is in the [main README](../README.md). This folder holds the details.

- [`architecture.md`](architecture.md): in which order Flux builds the platform, where each part is in the repo, how secrets are kept in Git, which certificates exist and who checks them, which network rules apply, and the versions used.
- [`operations.md`](operations.md): which scripts to run day to day and after a Codespace restart, and what to do about common failures.
- [`runbooks/`](runbooks/): step-by-step guides for OpenBao init and unseal, External Secrets, PostgreSQL backup and restore, monitoring, and the failure tests.
- [`adr/`](adr/): why each design decision was made, which options were rejected and what the trade-off is.
- [`risk-assessment.md`](risk-assessment.md): what can go wrong, how likely and how bad each risk is, and what was done about it.
- [`evidence/`](evidence/): the recorded output of every test and check, as proof of the results.
- [`glossary.md`](glossary.md): what each technical word means.
- [`environment.md`](environment.md): where the platform runs, which Codespaces secrets it needs, and the manual GitHub steps.
- [`time-log.md`](time-log.md): how much time each phase took.
