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

## Packaging contract (install-critical manifest fields)

`.claude-plugin/plugin.json` must carry the metadata a host needs to **load** the plugin. These
**install-critical** fields are a contract: the packaging oracle in `tests/run.sh`
(`MANIFEST_REQUIRED_FIELDS`) asserts each is present and non-empty, and a negative-path test proves
that removing one fails the offline suite. The set is:

<!-- install-critical-manifest-fields = name,version,description,homepage,repository,license -->
`name`, `version`, `description`, `homepage`, `repository`, `license`.

Keep this list and `MANIFEST_REQUIRED_FIELDS` in sync — a set-parity check in `tests/run.sh` fails if
they drift apart.

## Secret & safety discipline (must always hold)

These are standing policies a contribution must uphold; each is enforced at a specific gate in
`scripts/run-agent.sh`. Don't weaken a gate — if you change one, keep its offline test passing.

- **No secrets in any committed file or transcript.** The driver masks secret-shaped tokens via the
  `redact()` function before a transcript is persisted or echoed, and the per-run metadata record and
  run index carry **control-plane facts only** — never transcript text or the prompt. Redaction is
  **best-effort** (length-bounded), so raw transcripts still land *outside* the repo and are never
  committed. Never add a path that writes raw agent output, the prompt, or a credential to a tracked
  file.
- **Prompt passing is injection-safe.** The prompt is always passed as a **single argv element** (or
  via stdin), never `eval`'d or word-split, regardless of content — see `build_argv` and the
  `format_masked_argv` record, which masks the prompt to `<PROMPT>`. Never interpolate the prompt into
  a shell string.
- **Keep the per-CLI enforcement matrix honest.** `codex` / `claude` / `cursor` read-only is
  **enforced**; `agy` read-only is **best-effort** (`--sandbox` is not a hard write barrier). Never
  document, assert, or test agy read-only as enforced — the offline suite checks the driver's argv
  against the matrix in [docs/threat-model.md](docs/threat-model.md), which must stay in sync.

The full trust-boundary analysis is in [docs/threat-model.md](docs/threat-model.md); the README
[Safety](README.md#safety) section is the user-facing summary of these same gates.

## Tests

- **Extend the offline suite** (`tests/run.sh`) for any behaviour change, and keep it CLI-free (use
  `--dry-run` / `--list` / `--check` / stub agents — never a real CLI).
- **Keep jq/python3 parity.** Every `cfg` config op must produce byte-identical output under both
  backends; when you add or change a config query type, update **both** backends in `run-agent.sh`
  and the parity block in `tests/run.sh` together.
- The live/E2E harnesses (`tests/live-smoke.sh`, `tests/e2e/`) are **opt-in**
  (`EXTERNAL_AGENTS_LIVE=1`) and **never** part of the required offline gate — so a green required
  (offline) CI run does **not** imply a green *live* run; live readiness is proven only by an armed run
  (see the README [Live smoke](README.md#live-smoke-opt-in) section).

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
