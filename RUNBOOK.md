# external-agents operations runbook

Operational guide for the **run history** `scripts/run-agent.sh` accumulates — the per-run records and
the append-only index — which live **outside the repo**, under `EXTERNAL_AGENTS_OUT`
(default `$HOME/.external-agents/logs`). Everything here is **control-plane only**: no transcript text,
prompt, or secret (see [docs/run-record-contract.md](docs/run-record-contract.md)).

## Where the history lives

- `<EXTERNAL_AGENTS_OUT>/index.jsonl` — the append-only run index (one JSON row per agent per run).
- `<EXTERNAL_AGENTS_OUT>/<project>/<agent>.meta.json` and the redacted transcripts — the per-run records.
- Rotation / backup archives live under `<EXTERNAL_AGENTS_OUT>/archive/` — **never inside the repo**.

## Retention & rotation policy

The index grows unbounded with use. Rotation bounds storage **without losing rows**:

- **Thresholds (opt-in, conservative).** Rotation acts only when explicitly invoked
  (`scripts/run-history-maintain.sh`), and only when a threshold is crossed:
  - `EXTERNAL_AGENTS_INDEX_MAX_BYTES` (default `10485760` = 10 MiB), or
  - `EXTERNAL_AGENTS_INDEX_MAX_ROWS` (default `50000`).

  Below both thresholds, rotation is a no-op. **Nothing rotates automatically during a run** — the
  driver only ever appends.
- **Archive, don't prune (default).** On rotation the current `index.jsonl` is **archived** (moved to
  `<EXTERNAL_AGENTS_OUT>/archive/index-<UTC>.jsonl`) and a fresh empty index starts. No row is ever
  deleted by default. **Pruning** old archives (by count) is a separate, explicit opt-in via
  `EXTERNAL_AGENTS_ARCHIVE_KEEP` (default `0` = keep every archive).
- **Append-only-safe.** Rotation is a single **atomic rename** (`mv` within one filesystem) of
  `index.jsonl` to its archive path, so a concurrent appender (per the
  [concurrency note](README.md#run-index)) lands in either the archived file or the fresh one — never a
  half-written row, and no rows are lost.
- **Location.** Every archive lives under `<EXTERNAL_AGENTS_OUT>/archive/`, outside the repo, so
  rotation never touches tracked files.
