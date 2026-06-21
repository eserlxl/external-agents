# Changelog

All notable changes to external-agents are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.10.1] - 2026-06-21

### Changed
- Validate required flag arguments across scripts (a flag missing its value exits 2 instead of hanging or swallowing the next token); add offline api-client.py test coverage (exit codes, HTTP-status mapping, response parsing, key resolution); ignore Python bytecode cache

## [0.10.0] - 2026-06-21

A feature release adding **read-only cloud API advisors** — additive and
backward-compatible (every 0.9.0 flag, default, `agents.json` key, and run-record
field is preserved).

### Added
- **Cloud API advisors (read-only).** `claude-api`, `openai`, `gemini`, and `openrouter` — direct
  provider completion endpoints driven by a new stdlib-only `scripts/api-client.py`, for repository
  analysis (e.g. council/conclave panels). A new `api` agent kind (shared `argv_api` builder plus
  `ADAPTER_KIND`/`ADAPTER_PROVIDER`/`ADAPTER_KEY_ENV` registry maps) is **always read-only and
  enforced** (no filesystem access) and ships **disabled by default**; an API-only run auto-selects
  `--read-only`, and api agents are omitted from `--discover` (not tree-runnable). Tier models mirror
  the CLI agents.
- **API key resolution via Unix `pass`.** Each provider's env var (`ANTHROPIC_API_KEY` /
  `OPENAI_API_KEY` / `GEMINI_API_KEY`→`GOOGLE_API_KEY` / `OPENROUTER_API_KEY`) names a `pass` entry; the
  key is read via `pass show` at run time and never appears in argv, transcripts, or committed config.
  `--check` reports the key *source* only and never decrypts. Falls back to a literal key when `pass`
  is absent or `EXTERNAL_AGENTS_NO_PASS=1`.

## [0.9.0] - 2026-06-21

A feature release focused on **multi-agent orchestration and registry-driven
extensibility** — all additive and backward-compatible (every 0.8.0 flag, default,
`agents.json` key, and run-record field is preserved).

### Added
- **Pipeline orchestration (Phase 9.4).** `scripts/run-pipeline.sh` runs agents in an
  ordered, multi-stage sequence with artifact seeding between stages and per-stage
  failure handling, pinned by an offline outcome-summary oracle that asserts only
  control-plane facts (never transcript content).
- **Outcome-consensus verdict (Phase 9.5).** `--json` output now carries a deterministic
  consensus verdict derived from per-agent outcomes, proven by a stub-driven consensus
  oracle.
- **Adapter-registry agent extensibility (Phase 9.2).** Adding an agent is now a
  registry-only change: per-agent argv builders are extracted and agent validation is
  unified through the `ADAPTER_BIN` registry, decoupling policy from the dispatcher.
  New extensibility guide plus registry-argv parity and policy-decoupling guards.

### Changed
- Agent validation and launch-argv construction are driven by the `ADAPTER_BIN`
  registry across all backends, replacing per-agent special-casing.

### Fixed
- Malformed rows in the run-history index are handled with line-by-line `fromjson?`
  parsing, restoring jq/python3 parity instead of aborting.
- Guard an empty `AGENT` before `ADAPTER_BIN` array indexing, fixing a "bad array
  subscript" error on `--check` / `--discover`.
- `run-history` archive prune now sorts by mtime, avoiding same-second collisions.
- `bump-version.sh` tracks and reports failed restores in its transactional rollback.
- `verify_install` captures output before `grep` so `pipefail` no longer masks headers.

### Docs
- Orchestration patterns (pipeline + consensus), the Phase 9.2 extensibility guide, the
  `run-pipeline.sh` invocation/flag reference, and threat-model semantic anchors
  (replacing fragile line-number citations).

## [0.8.0] - 2026-06-20

### Changed
- Phase 8 resilience: published run-record JSON Schema, error-class taxonomy + driver classifier, bounded opt-in retry/backoff, read-only run-history analytics, and index rotation + backup/restore (all additive, backward-compatible)

## [0.7.0] - 2026-06-20

A feature release focused on **machine-readable run output, durable run history, and safety** —
all additive and backward-compatible (every 0.6.0 flag, default, and `agents.json` key is preserved).

### Added
- **`--json` flag.** Emits a machine-readable JSON run summary to stdout *in addition to* the
  (unchanged) human output — run-level fields plus one control-plane object per agent and the
  agreement signal, with no transcript content.
- **Per-run metadata record.** Every run writes one structured `<agent>.meta.json` next to the
  transcript, capturing resolved control-plane facts (agent, model, tier, effort, mode, target,
  rc, sec, bytes, fallback flag, launch timestamp) — never transcript text.
- **Run index.** An append-only JSON Lines history at `<base>/index.jsonl` accruing one row per
  agent per run (grouped by a run id), built only from control-plane facts and readable with any
  JSON tool.
- **Cross-agent fan-out summary.** `--agent all` prints a compact per-agent digest table (agent,
  rc, model, tier, sec, bytes, fallback) after the verbatim transcripts, closed by a deterministic
  `all-ok` / `mixed` / `all-fail` agreement line (plus write-fan-out and read-only no-mutation notes).
- **Best-effort cost/latency signals.** When an agent CLI prints a recognizable token count or
  dollar cost, the driver lifts it into an optional `signals` object on the per-run record and index
  row; an absent signal is the explicit `"unavailable"` marker, never a fabricated number.
- **`--discover` flag.** Prints one machine-readable line per known agent
  (`<agent> <present|missing> <bin>`) so a harness can scope itself to the installed set;
  config-independent like `--check`.
- **`--version` / `-V` flag.** Prints the plugin version and exits (no `agents.json` required).
- **`agents.json` JSON Schema** (`schema/agents.schema.json`, draft-07) — a published config
  contract, validated in CI.
- **Masked launch-argv record** (`<agent>.argv`), byte-identical to `--dry-run` and never
  containing the prompt text.

### Changed
- **Best-effort transcript secret-redaction.** Agent stdout/stderr is run through a length-bounded
  redaction stage that masks token-shaped strings (`sk-`/`pk-`, `gh*_`/`github_pat_`, `xox*-`,
  `AKIA`, `Bearer` tokens, `KEY=`/`TOKEN=`/`SECRET=`/`PASSWORD=` assignments, and long high-entropy
  runs) as `<REDACTED>` before any transcript is persisted or echoed. Best-effort, not a guarantee;
  the structural output contract (`=====` headers, the ok/failed tally) is preserved.
- Plugin manifest now declares accurate `repository` and `homepage` fields.

### Fixed
- `--timeout` is validated as a positive integer of seconds up front, with a clear error message,
  instead of deferring to an opaque per-agent timeout failure at launch.

### Removed
- Dead `.codex-plugin/plugin.json` reference in `scripts/bump-version.sh`. The repository ships only
  `.claude-plugin/plugin.json`, so the release tooling now describes exactly the manifests this repo
  ships — lockstep across `.claude-plugin/plugin.json`, `skills/*/SKILL.md`, the README version
  badge, and `CHANGELOG.md`. A regression guard in `tests/run.sh` keeps the dead reference from
  returning.

### Security
- Added a **threat model** (`docs/threat-model.md`) enumerating trust boundaries, protected assets,
  and mitigating controls, including a published **per-CLI read-only enforcement matrix** (agy
  best-effort vs codex/claude/cursor enforced).
- Added a **security policy** (`SECURITY.md`) with private vulnerability reporting and supported-version scope.
- Documented and bounded transcript-redaction limits, and reaffirmed the read-only enforcement guarantees.

### Documentation
- Authored a **release runbook** (`RELEASING.md`) — clean-tree → dry-run → bump → tag → push, with
  a tag-equals-version verification gate and the release cadence heuristic.
- Authored a **contributor guide** (`CONTRIBUTING.md`) cross-linked with the README, CI, and runbook.
- Documented the new run surfaces in the README (`--json`, per-run metadata, run index, cost/latency
  signals, cross-agent summary, `EXTERNAL_AGENTS_OUT`, and the schema/config contract), clarified the
  presence-vs-live boundary of `--check`, and published a consolidated E2E recipe (`docs/e2e-recipe.md`).

### Tests / CI
- Added a **GitHub Actions CI** workflow, offline by design: shellcheck of the driver scripts,
  `agents.json` schema validation, and the CLI-free offline suite (never invokes live/e2e harnesses).
- Added an **extensive offline suite** (`tests/run.sh`) covering config resolution, malformed-config
  resilience, the safety gates, redaction (positive/negative/false-positive), the enforcement-matrix
  accuracy, jq/python3 backend parity (config reads *and* JSON emitters), and `bump-version.sh`.
- Added an **opt-in live-smoke harness** (`tests/live-smoke.sh`, gated by `EXTERNAL_AGENTS_LIVE`) and
  **stub-driven offline e2e recipes** (`tests/e2e/`).

## [0.6.0] - 2026-06-19

### Added
- **`cursor` agent.** A fourth external agent driving Cursor's headless CLI (`cursor-agent`)
  to run Cursor's own models, defaulting to Composer 2.5. Read-write uses `-p --force --trust`
  (auto-approve edits + shell); read-only uses `-p --mode plan --trust` — Cursor's *enforced*
  no-edit planning mode, a hard read-only guarantee like codex/claude. The prompt is passed as
  the trailing positional after `--`, so a prompt starting with `-` can't be read as a flag.
  Ships **enabled** in `agents.json` (so `--agent all` includes it) with a per-tier **non-fast**,
  ZDR-respecting cheap→premium ladder — `gpt-5-mini` (low), `composer-2.5` (medium),
  `gpt-5.5-high` (high), `claude-opus-4-8-thinking-high` (xhigh) — all plain (non-`-fast`) ids
  so runs don't spend Cursor's fast/priority quota. Its CLI binary is `cursor-agent`, not
  `cursor` (the IDE); `--check` resolves and reports the correct binary. Requires
  `cursor-agent login` (or `CURSOR_API_KEY`).

- **agy quota-aware fallback.** An `agy` tier may declare a `fallback` model. Before launching
  such a tier, `run-agent.sh` consults the free `antigravity-usage --json` CLI for the primary
  model's remaining Antigravity quota and uses the primary **only when it is confirmed
  available**; if it is exhausted **or unconfirmable** (Antigravity IDE closed / not logged in /
  CLI absent), the larger-limit Gemini `fallback` runs instead — so scarce 3rd-party / Opus
  quota is never spent without a positive check. agy-only; a `--model` override skips it. The
  default agy ladder now uses `Claude Sonnet 4.6 (Thinking)` (high) and `Claude Opus 4.6
  (Thinking)` (xhigh), falling back to `Gemini 3.5 Flash (High)` and `Gemini 3.1 Pro (High)`
  respectively. Tunable via `EXTERNAL_AGENTS_AGY_MIN_REMAINING` /
  `EXTERNAL_AGENTS_AGY_QUOTA_TIMEOUT` / `EXTERNAL_AGENTS_AGY_QUOTA_CMD`. `--list` shows the
  fallback; `--check` reports whether `antigravity-usage` is on `PATH`.

### Changed
- `default_tier` is now `medium` (was `xhigh`), so a run with no `--effort` resolves to each
  agent's mid tier — cheaper by default. Pass `--effort xhigh` (or set `default_tier` back) for
  the previous top-tier default.

## [0.4.0] - 2026-06-19

### Added
- **Effort tiers.** `--effort low|medium|high|xhigh` is now a single semantic level that
  maps, per agent, to the right model + native effort: agy bakes the tier into the model
  (e.g. `Gemini 3.5 Flash (High)`), codex/claude take model + effort separately. With no
  `--effort`, the config's `default_tier` (ships `xhigh`, reproducing the previous defaults)
  is used; `--model M` still overrides only the resolved model.
- `agents.json` config — `enabled` agents plus a per-tier `{model, effort}` map and
  `default_tier`. Read via `jq` (preferred) or `python3`. `--list` now prints the resolved
  tier table and enabled status.

### Changed
- `run-agent.sh` reads its config from JSON; `--conf` now defaults to `agents.json`.
- `--check` also reports the JSON reader (jq/python3) alongside the agent CLIs.

### Removed
- `agents.conf` (the pipe-delimited per-agent defaults), replaced by `agents.json`.

## [0.3.0] - 2026-06-16

### Changed
- scripts/bump-version.sh now also syncs the README shields.io version badge, so the README always advertises the current version.

## [0.2.0] - 2026-06-16

### Added
- `scripts/bump-version.sh` — lockstep version bumper across the plugin manifest, skill frontmatter, and CHANGELOG.md (Keep a Changelog).

## [0.1.0] - 2026-06-16

### Added
- Initial release. The **`external-agents`** skill and **`/external-agents`** slash
  command dispatch a prompt to external coding-agent CLIs (`agy`, `codex`, optionally
  `claude`) as autonomous sub-agents in the working tree.
- `scripts/run-agent.sh` driver — owns every flag, sandbox mode, parallel fan-out,
  timeout, and per-agent default. Supports a single target or `--agent all` parallel
  fan-out, read-write by default with `--read-only`, plus `--model`, `--effort`,
  `--claude-perm`, `--yes`, `--timeout`, `--out`, `--check`, `--list`, `--dry-run`.
