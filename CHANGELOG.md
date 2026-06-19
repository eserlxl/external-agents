# Changelog

All notable changes to external-agents are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [0.5.0] - 2026-06-19

### Added
- **`cursor` agent.** A fourth external agent driving Cursor's headless CLI (`cursor-agent`)
  to run Cursor's own models, defaulting to Composer 2.5. Read-write uses `-p --force --trust`
  (auto-approve edits + shell); read-only uses `-p --mode plan --trust` — Cursor's *enforced*
  no-edit planning mode, a hard read-only guarantee like codex/claude. The prompt is passed as
  the trailing positional after `--`, so a prompt starting with `-` can't be read as a flag.
  Ships **enabled** in `agents.json` (so `--agent all` includes it) with per-tier **non-fast**
  models — `gpt-5-mini` (low), `auto` (medium), `kimi-k2.5` (high), `composer-2.5` (xhigh) —
  chosen as plain (non-`-fast`) ids so runs don't spend Cursor's fast/priority quota. Its CLI
  binary is `cursor-agent`, not `cursor` (the IDE); `--check` resolves and reports the correct
  binary. Requires `cursor-agent login` (or `CURSOR_API_KEY`).

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
