# Threat Model

> Security-posture reference for external-agents. This document is built up across the Phase 6
> hardening work; see also the README [Safety](../README.md#safety) section for the user-facing
> summary.

## Secret handling and transcript redaction

Agent transcripts can echo secrets that appear in a target tree or in an agent's own output.
Before any transcript is persisted under the logs directory or echoed to stdout, the driver runs
it through a **best-effort, length-bounded** redaction stage (`redact` in `scripts/run-agent.sh`)
that masks secret-shaped tokens — `sk-`/`pk-`, `gh*_`/`github_pat_`, `xox*-`, `AKIA…`, `Bearer`
tokens, `KEY=`/`TOKEN=`/`SECRET=`/`PASSWORD=` assignments, and long high-entropy runs — as
`<REDACTED>`.

**Limits (documented honestly).** Redaction is *not* a guarantee of total secret removal:

- short or unusually-shaped secrets below the length thresholds can pass through;
- long non-secret strings (e.g. base64 blobs, 40-character hashes) can be over-masked;
- only the stdout transcript and the echoed stderr tail are redacted.

So transcripts must still be treated as sensitive. The matching user-facing note is the README
[Safety → Transcript redaction](../README.md#safety) bullet.
