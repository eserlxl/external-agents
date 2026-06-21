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
  (`scripts/run-history-maintain.sh`), and only when the index is **strictly above** a maximum
  (`> MAX`, not `>= MAX`):
  - `EXTERNAL_AGENTS_INDEX_MAX_BYTES` (default `10485760` = 10 MiB), or
  - `EXTERNAL_AGENTS_INDEX_MAX_ROWS` (default `50000`).

  At or below both thresholds, rotation is a no-op; an **empty or missing index is never rotated**
  (even with `--force`). **Nothing rotates automatically during a run** — the driver only ever appends.
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

## Backup & restore

The rotation archives under `<EXTERNAL_AGENTS_OUT>/archive/` double as **backups** of the run index;
the per-run records (`<EXTERNAL_AGENTS_OUT>/<project>/`) can be archived the same way. Both use plain
file copies, so a restore reproduces **content-identical** rows.

**Back up** the current index into the archive directory:

```bash
base="${EXTERNAL_AGENTS_OUT:-$HOME/.external-agents/logs}"
mkdir -p "$base/archive"
cp -p "$base/index.jsonl" "$base/archive/index-backup-$(date -u +%Y%m%dT%H%M%SZ).jsonl"
```

**Restore** after a corruption or accidental deletion — recover from one archive (exact copy) or
reconstruct the whole history from every archive (archives sort chronologically by name):

```bash
base="${EXTERNAL_AGENTS_OUT:-$HOME/.external-agents/logs}"
# from a single archive (byte-for-byte):
cp -p "$base/archive/index-<UTC>.jsonl" "$base/index.jsonl"
# OR reconstruct the full history:
cat "$base"/archive/index-*.jsonl > "$base/index.jsonl"
```

`cp` / `cat` preserve each row verbatim, so the restored index is **content-identical** to the
originals — the offline recoverability drill in `tests/run.sh` proves exactly this. All backup and
restore writes stay under `EXTERNAL_AGENTS_OUT`, never inside the repo.

## Lifecycle, end to end

The run history has one cradle-to-grave flow, all under `EXTERNAL_AGENTS_OUT` (never the repo):

1. **Accrue.** Every run appends one control-plane row to `index.jsonl` and writes per-run records —
   no transcript text, prompt, or secret (the content-free guarantee; see
   [docs/run-record-contract.md](docs/run-record-contract.md) and
   [docs/threat-model.md](docs/threat-model.md)).
2. **Retain.** The index grows unbounded; the `EXTERNAL_AGENTS_INDEX_MAX_BYTES` / `_MAX_ROWS`
   thresholds decide when it has grown too large.
3. **Rotate.** `scripts/run-history-maintain.sh` atomically rolls the index to
   `archive/index-<UTC>.jsonl` and starts a fresh one — **no rows lost**. Old archives are pruned only
   on the explicit `EXTERNAL_AGENTS_ARCHIVE_KEEP` opt-in.
4. **Back up.** Archives double as backups; an explicit `cp` snapshots the live index on demand.
5. **Restore.** A `cp` (single archive) or `cat archive/index-*.jsonl` (full history) rebuilds the
   index with **content-identical** rows.

Every artifact in this flow — the index, the per-run records, and the archives — lives under
`EXTERNAL_AGENTS_OUT` (default `$HOME/.external-agents/logs`), **outside the repository**, and carries
**only control-plane facts**, never a transcript, prompt, or secret. The offline suite asserts the
rotation / recoverability invariants and the secret-free guarantee.

## Live-smoke & e2e evidence

The opt-in [live smoke](README.md#live-smoke-opt-in) and [e2e recipes](docs/e2e-recipe.md) write their
evidence **outside the repository**, under `EXTERNAL_AGENTS_OUT` (default `$HOME/.external-agents/logs`)
— never a tracked file:

- **Live smoke:** `<EXTERNAL_AGENTS_OUT>/live-smoke/status.txt` (one `<agent>  <status>` line) plus
  `provenance.txt`. The status vocabulary is `live-verified`, `failed`, `skipped-not-reachable`,
  `skipped-scoped-out`, and `skipped-not-opted-in` (the harness was not armed). Only `live-verified`
  means the agent round-tripped at record time.
- **E2E recipes:** `<EXTERNAL_AGENTS_OUT>/e2e/<recipe>/<agent>/` — per-run `argv`, `pre.sha`,
  `pre.status`, and the redacted response.

Read the live-smoke result with:

```bash
cat "${EXTERNAL_AGENTS_OUT:-$HOME/.external-agents/logs}"/live-smoke/status.txt
```

These records are **best-effort, human-auditable, and never committed to the repo**; the required
offline gate never produces them. See the README [live smoke](README.md#live-smoke-opt-in) section for
the full vocabulary and record-stability contract.

## Phase 8 resilience readiness

What the run-history surface now guarantees, and the honest limits:

**Enforced (offline-verified in `tests/run.sh`):**

- **Outcome classification.** Every run records a closed-set `error_class` (`ok` / `safety-refusal` /
  `timeout` / `transient` / `auth` / `contract` / `unknown`); a `safety-refusal` is never retryable.
- **Bounded retry.** Retries are opt-in, bounded by `EXTERNAL_AGENTS_RETRY_MAX` (default `0`), and
  apply only to retryable classes; `attempts` / `retried` are recorded.
- **Schema contract.** The per-run record and index row conform to `schema/run-record.schema.json`
  (validated under both jq and python3), and a drift guard keeps the emitter and schema in lockstep.
- **Recoverability & retention.** Rotation archives the index atomically without losing rows, and
  backup/restore reproduces content-identical rows — both drilled offline.

**Best-effort (not a guarantee):**

- **Cost/usage signals.** `signals.tokens` / `signals.cost` are CLI self-reports, not billing-grade;
  an `unavailable` value is excluded from aggregates, never zeroed.
- **agy read-only.** `--sandbox` is best-effort and never claimed as enforced — use
  codex/claude/cursor for a hard read-only guarantee.

**Boundaries:**

- The **required CI gate is offline-only** ([.github/workflows/ci.yml](.github/workflows/ci.yml)) — it
  launches no external CLI; live verification is opt-in (`EXTERNAL_AGENTS_LIVE=1`) and never required.
- All run history (the index, per-run records, and archives) lives under `EXTERNAL_AGENTS_OUT`
  (default `$HOME/.external-agents/logs`), **outside the repository**, and is control-plane only.
