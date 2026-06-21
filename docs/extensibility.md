# Extending external-agents: adding an agent

Since Phase 9.2 the driver (`scripts/run-agent.sh`) routes every per-agent decision through a single
**declarative adapter registry**, so adding an agent is a small, localized change rather than edits
scattered across the driver. This document describes that boundary; the exact step-by-step is in the
add-an-agent walkthrough (below, added in Phase 9.3).

## The adapter registry boundary

Per-agent facts live in ONE place near the top of the driver:

| Registry member | Kind | What it holds |
|------------------|------|---------------|
| `ADAPTER_AGENTS` | ordered list | the known agent set, in canonical order — drives the allow-list and the `--check` / `--discover` candidate sets |
| `ADAPTER_BIN` | name → binary | the CLI binary each agent maps to (e.g. `cursor` → `cursor-agent`); `agent_bin` derives from it |
| `ADAPTER_ENFORCEMENT` | name → class | the read-only enforcement class (`enforced` / `best-effort`), tied to the [threat-model matrix](threat-model.md#per-cli-read-only-enforcement-matrix) by the enforcement-class doc-drift guard |
| `argv_<agent>` | function | the thin per-CLI argv builder — the read-only/write argv shape and the prompt index |

Everything else is **derived** from the registry, no longer hand-maintained at scattered call sites:

- `agent_bin` ← `ADAPTER_BIN`;
- the single-agent allow-list, the `--check` candidate set, and the `--discover` candidate set ← `ADAPTER_AGENTS`;
- the best-effort read-only NOTE ← `ADAPTER_ENFORCEMENT`;
- `build_argv` validates membership against `ADAPTER_BIN` and dispatches to `argv_<agent>`.

`agy`'s quota-aware fallback stays a **control-plane policy** in `build_argv` (consulted once before the
dispatch), never duplicated per adapter.

The documented read-only / write argv shapes in the `scripts/run-agent.sh` header comment correspond
exactly to what the `argv_<agent>` builders emit; the offline registry-argv parity oracle asserts they
stay byte-identical across the jq and python3 config backends.

## What adding an agent touches

Two edits, no policy code:

1. **A registry entry** in `scripts/run-agent.sh`: add the name to `ADAPTER_AGENTS`, its binary to
   `ADAPTER_BIN`, its read-only enforcement class to `ADAPTER_ENFORCEMENT`, and a thin `argv_<agent>`
   builder for its argv shape.
2. **An `agents.json` block**: the agent's tier → (model, optional native effort, optional agy-only
   fallback) map, which `schema/agents.schema.json` already accepts via `additionalProperties`.

No edit to `agent_bin`, the allow-list, the `--check`/`--discover` candidate lists, or the safety
gates — they all derive from the registry. The threat-model matrix row (and its enforcement class)
should be added too, so the enforcement-class doc-drift guard stays green.

## Add-an-agent walkthrough

Adding an agent is exactly **two edits** — a registry entry and an `agents.json` block — plus the
standard validation loop. **No policy code is touched**; the fixture-agent oracle and the
policy-decoupling guard in `tests/run.sh` prove a registry-only agent resolves its tier, builds correct
argv, is discovered, and emits the standard records.

**Edit 1 — the registry entry** (`scripts/run-agent.sh`, the adapter-registry block):

1. Add the name to `ADAPTER_AGENTS` (the ordered agent set).
2. Add its CLI binary to `ADAPTER_BIN` (`[name]="binary"`).
3. Add its read-only enforcement class to `ADAPTER_ENFORCEMENT` (`enforced` or `best-effort`).
4. Add a thin `argv_<name>()` builder that sets `ARGV[]` and `PROMPT_IDX` for the read-only and write
   argv shapes (mirror an existing builder, e.g. `argv_cursor`).
5. Add the agent's row to the [threat-model read-only matrix](threat-model.md#per-cli-read-only-enforcement-matrix)
   so the enforcement-class doc-drift guard stays green.

**Edit 2 — the `agents.json` block**: add the agent's `tiers` map (model, optional native effort,
optional agy-only fallback) under `agents`, with `"enabled": true`. `schema/agents.schema.json` already
accepts new agents via `additionalProperties`.

**Then run the validation loop** (the same one CI runs — see
[CONTRIBUTING.md](../CONTRIBUTING.md#the-validation-loop)):

```bash
shellcheck scripts/run-agent.sh scripts/bump-version.sh
python3 -c "import json, jsonschema; jsonschema.validate(json.load(open('agents.json')), json.load(open('schema/agents.schema.json')))"
bash tests/run.sh
```

That's it — no policy edit. `--dry-run --agent <name>` now prints the agent's argv, and
`--check` / `--discover` report it present once its binary is on `PATH`.

## Two agent kinds: `cli` vs `api`

The registry carries a `ADAPTER_KIND` map alongside the policy data:

| Kind | What it is | Read-only | Driven by |
|------|------------|-----------|-----------|
| `cli` | an external agentic CLI (agy/codex/claude/cursor) that may edit the target tree | best-effort (agy) / enforced (others) | the per-CLI `argv_<agent>` builder |
| `api` | a cloud completion endpoint (claude-api/openai/gemini/openrouter) with no filesystem access | **enforced** (intrinsic — a stateless call can't touch the tree) | the shared `argv_api` builder via `scripts/api-client.py` |

An `api` agent is **always read-only** (its `argv_api` builder ignores `MODE`; an API-only run
auto-selects `--read-only`), so its `ADAPTER_ENFORCEMENT` class is `enforced` and its threat-model row
documents "no filesystem access". Two extra registry maps carry the api-only facts: `ADAPTER_PROVIDER`
(the `--provider` passed to the client) and `ADAPTER_KEY_ENV` (the env var(s) that name its `pass`
entry). `ADAPTER_BIN` for an api agent is the client runtime (`python3`), so `--check` reports it present when
the runtime **and** `scripts/api-client.py` exist (plus an info line on the key source); the API key is a
*readiness* concern resolved at run time (never decrypted by `--check`). `--discover` deliberately
**omits** api agents — that surface scopes the live-smoke / e2e harnesses, which run an agent against a
sandbox tree, and an api advisor is neither tree-runnable nor free to live-verify.

**Adding a new api provider** is the same registry-only shape, plus a client case:

1. Registry: add the name to `ADAPTER_AGENTS`, `[name]="python3"` to `ADAPTER_BIN`, `[name]="enforced"`
   to `ADAPTER_ENFORCEMENT`, `[name]="api"` to `ADAPTER_KIND`, `[name]="<provider>"` to
   `ADAPTER_PROVIDER`, and `[name]="<KEY_ENV>"` to `ADAPTER_KEY_ENV`. No new `argv_<name>` builder — the
   shared `argv_api` already dispatches on `ADAPTER_PROVIDER`.
2. Client: add a `run_<provider>()` to `scripts/api-client.py` (request shape + response parsing) and
   register it in its `PROVIDERS` map.
3. `agents.json`: the tier → model block, `"enabled": false`, like any other agent.
4. Threat-model matrix: an `enforced` row (so the enforcement-class and bidirectional doc-drift guards
   stay green), then run the offline validation loop above.

For an OpenAI-compatible gateway, prefer reusing the `openrouter` agent (its tier models are
`vendor/model` slugs) rather than adding a provider — no code change needed.
