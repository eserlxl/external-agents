# Extending external-agents: adding an agent

This is the **adapter touch-point inventory** — every place in the driver (`scripts/run-agent.sh`) an
added agent must be wired **today**. Line references are anchored to the current version; the Phase 9.2
**declarative adapter registry** consolidates these touch-points behind one boundary, after which this
document is updated to describe the registry rather than the scattered call sites.

## Driver touch-points an added agent requires today

| # | Touch-point | Where (`scripts/run-agent.sh`) | What it does |
|---|-------------|--------------------------------|--------------|
| 1 | `build_argv` per-agent case | `build_argv` at `:548` (agy `:556`, codex `:575`, claude `:581`, cursor `:588`) | Builds the agent's read-only / write argv, prompt index, and resolved model |
| 2 | `agent_bin` mapping | `:292` | Maps the agent name to its CLI binary (e.g. `cursor` → `cursor-agent`) |
| 3 | Single-agent allow-list | `:456` | The `--agent <name>` validation (`case "$AGENT" in agy\|codex\|claude\|cursor)`) |
| 4 | `--check` candidate list | `:370` | The agents the presence preflight probes |
| 5 | `--discover` candidate list | `:409` | The agents the machine-readable reachable-set lists |
| 6 | Read-only enforcement argv | within `build_argv` (agy `--sandbox` `:557`, codex `-s read-only` `:575`, claude `--allowedTools` `:581`, cursor `--mode plan` `:591`) | The per-agent read-only mechanism, mirrored in the [threat-model matrix](threat-model.md#per-cli-read-only-enforcement-matrix) |

A seventh hard-coded four-agent literal lives in the signal extractor
(`extract_signal` at `:686`, `case "$agent" in agy|codex|claude|cursor`), which gates cost/latency
parsing per agent.

## Config side

Beyond the driver, an added agent needs its tier → (model, optional native effort, optional agy-only
fallback) entry in [`agents.json`](../agents.json), validated by
[`schema/agents.schema.json`](../schema/agents.schema.json) (which already accepts new agents via
`additionalProperties`).

## Why this is the baseline for Phase 9.2

Adding an agent today means editing **six-plus** scattered driver locations that must stay in sync — a
silent-drift surface where forgetting one (e.g. the `--discover` list) leaves the agent half-wired. The
Phase 9.2 declarative adapter registry consolidates touch-points 1–6 (and the signal-extractor literal)
behind one boundary, so an agent is added **without touching policy code** — the property Phase 9.3's
fixture-agent oracle then proves.
