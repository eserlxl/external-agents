# Contributing to external-agents

Thanks for contributing! This guide takes you from a clean checkout to a validated, submittable
change. external-agents is a small, dependency-light Bash + Python plugin; the bar is **the offline
gate stays green and the safety invariants hold**.

## Local setup

You need `bash`, `git`, and `jq` **or** `python3` (the driver reads `agents.json` with either).
`shellcheck` is required to reproduce the lint gate, and `python3` with `jsonschema` to reproduce the
schema check. There is no build step — the driver (`scripts/run-agent.sh`) runs in place. The external
agent CLIs (`agy` / `codex` / `claude` / `cursor-agent`) are **not** needed for development: the
offline tests never launch them.

## The validation loop

Run the same checks CI runs (`.github/workflows/ci.yml`), in this order, until all are green:

```bash
# 1. lint the driver scripts
shellcheck scripts/run-agent.sh scripts/bump-version.sh
# 2. validate agents.json against its schema
python3 -c "import json, jsonschema; jsonschema.validate(json.load(open('agents.json')), json.load(open('schema/agents.schema.json')))"
# 3. run the offline test suite
bash tests/run.sh
```

The offline suite is **CLI-free** — it exercises `run-agent.sh` only through `--dry-run`, `--list`,
`--check`, and stubbed runs, so no external agent CLI is launched. Keep it that way (see [Tests](#tests)).

## Architecture (where a change belongs)

Three layers, one rule:

- **Interface** — `skills/external-agents/SKILL.md` (the natural-language brain) and
  `commands/external-agents.md` (the `/external-agents` slash command). These are **thin**: they
  resolve arguments and hand off, and contain **no driving logic**.
- **Driver** — `scripts/run-agent.sh`: all the logic — argument parsing, per-agent argv construction,
  the safety gates, running each agent, redaction, and collection/observability.
- **Adapter (config)** — `agents.json` (+ `schema/agents.schema.json`): the per-agent
  tier → (model, effort, fallback) map the driver reads through its `cfg` backend.

**The rule: safety gates live in the driver, never the interface.** Containment checks, the non-cwd
`--yes` confirmation, `--read-only`/`--write` mutual exclusion, transcript redaction, and single-argv
prompt construction are all enforced in `run-agent.sh`, so they hold no matter how the script is
invoked — never relocate a gate up into the skill or command.

## Safety invariants (must always hold)

- **No secrets in any committed file or transcript.** Transcripts are redacted (best-effort) and land
  outside the repo; never commit one.
- **Prompt passing is injection-safe.** The prompt is always a single argv element (or stdin), never
  `eval`'d or word-split.
- **Per-CLI enforcement stays honest.** `codex` / `claude` / `cursor` read-only is enforced; `agy`
  read-only is best-effort — never document or assert agy as enforced.

The full trust-boundary analysis is in [docs/threat-model.md](docs/threat-model.md); the README
[Safety](README.md#safety) section is the user-facing summary.

## Tests

- **Extend the offline suite** (`tests/run.sh`) for any behaviour change, and keep it CLI-free (use
  `--dry-run` / `--list` / `--check` / stub agents — never a real CLI).
- **Keep jq/python3 parity.** Every `cfg` config op must produce byte-identical output under both
  backends; when you add or change a config query type, update **both** backends in `run-agent.sh`
  and the parity block in `tests/run.sh` together.
- The live/E2E harnesses (`tests/live-smoke.sh`, `tests/e2e/`) are **opt-in**
  (`EXTERNAL_AGENTS_LIVE=1`) and **never** part of the required offline gate.

## Versioning, changelog, and SPDX

- **Never hand-edit version strings.** Use `scripts/bump-version.sh`, which bumps the version in
  lockstep across the plugin manifest, the skill frontmatter, the README badge, and `CHANGELOG.md`
  (add a changelog note with `-m`). The full release flow is in [RELEASING.md](RELEASING.md).
- **Every shell script carries an SPDX header** — the two lines at the top of any `*.sh`:

  ```bash
  # SPDX-FileCopyrightText: 2026 Eser KUBALI
  # SPDX-License-Identifier: GPL-3.0-or-later
  ```

## Submitting

1. Branch from `main`.
2. Make the change; run the [validation loop](#the-validation-loop) above until it is green.
3. Sanity-check your environment with `bash scripts/run-agent.sh --check`
   (see [install verification](README.md#install)).
4. Open a PR; CI runs the same offline gate on push/PR.
