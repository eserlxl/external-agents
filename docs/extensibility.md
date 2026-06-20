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
