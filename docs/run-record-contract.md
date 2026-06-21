# Run-record contract & stability

`scripts/run-agent.sh` writes two record shapes, both **control-plane facts only** — never transcript
text, never the prompt, never a secret (the content-free guarantee is part of the
[threat model](threat-model.md)):

- a **per-run `meta.json`** record (one per agent per run), written by `write_meta_json`, and
- a **run-index `index.jsonl` row** — the same record augmented with `run_id` and `project`, appended
  by `append_index_row`.

Both shapes are published as a draft-07 schema in
[`../schema/run-record.schema.json`](../schema/run-record.schema.json); this document is the
field-by-field reference and the **stability policy**.

## Fields

Every value is the **post-fallback resolved truth** (what was actually used, not what was requested),
built only from values resolved at launch/collect — never parsed from the transcript.

| field | JSON type | semantic (post-fallback resolved) |
|-------|-----------|-----------------------------------|
| `agent` | string | the agent name |
| `model` | string | the resolved model actually used (post-fallback for agy) |
| `tier` | string | the effort tier (`low`/`medium`/`high`/`xhigh`) |
| `effort` | string | the tier's native effort, or `(none)` |
| `mode` | string | `readonly` or `write` |
| `target` | string | the resolved directory the agent worked in |
| `rc` | number \| string | agent process exit code (raw string only if non-numeric) |
| `sec` | number \| string | wall-clock seconds |
| `bytes` | number \| string | redacted transcript size in bytes |
| `fallback` | boolean | `true` iff the agy quota fallback swapped the primary model |
| `timestamp` | string | run launch time, UTC ISO-8601 (e.g. `2026-06-20T12:00:00Z`) |
| `error_class` | string (enum) | the closed-set outcome class — one of `ok`, `safety-refusal`, `timeout`, `transient`, `auth`, `contract`, `unknown` (see README → [Error classification](../README.md#error-classification)). Added additively in Phase 8.2 |
| `attempts` | number \| string | total launch attempts (`1` + retries). Added additively in Phase 8.2 |
| `retried` | boolean | `true` iff the run was retried (`attempts` > 1). Added additively in Phase 8.2 |
| `signals.tokens` | number \| string | a numeric token count, or the literal `unavailable` |
| `signals.cost` | string | the cost string verbatim (e.g. `$0.12`), or the literal `unavailable` |

Index-row-only fields (present in `index.jsonl`, not in `meta.json`):

| field | JSON type | semantic |
|-------|-----------|----------|
| `run_id` | string | groups every agent of one fan-out under a single id |
| `project` | string | the project namespace the run was recorded under |

`signals.*` are **best-effort, CLI-self-reported** — not billing-grade. The literal `unavailable`
means no signal was recognized and is **never** a fabricated number (see the README
[signals](../README.md#cost-latency-and-quality-signals) caveat). For latency/size prefer the
driver-measured `sec`/`bytes` over the agent-reported signals.

## Example records

A `meta.json` record (one per agent per run — the `meta.json record` schema branch, with **no**
`run_id` / `project`):

```json
{
  "agent": "codex",
  "model": "gpt-5.5",
  "tier": "high",
  "effort": "high",
  "mode": "readonly",
  "target": "/home/me/project",
  "rc": 0,
  "sec": 12,
  "bytes": 2048,
  "fallback": false,
  "timestamp": "2026-06-20T12:00:00Z",
  "error_class": "ok",
  "attempts": 1,
  "retried": false,
  "signals": { "tokens": 1530, "cost": "$0.04" }
}
```

The matching `index.jsonl` row is the **same** record augmented with the fan-out `run_id` and the
`project` namespace (the `index.jsonl row` schema branch). One such line is appended per agent per run:

```json
{"agent":"codex","model":"gpt-5.5","tier":"high","effort":"high","mode":"readonly","target":"/home/me/project","rc":0,"sec":12,"bytes":2048,"fallback":false,"timestamp":"2026-06-20T12:00:00Z","error_class":"ok","attempts":1,"retried":false,"signals":{"tokens":1530,"cost":"$0.04"},"run_id":"run-2026-06-20T120000Z-a1b2","project":"external-agents"}
```

Both examples validate against [`../schema/run-record.schema.json`](../schema/run-record.schema.json):
the resolved `signals` object is always present (here with live numbers; an unrecognized signal is the
literal `unavailable`, never a fabricated `0`), and `error_class`/`attempts`/`retried` are the
additive Phase 8.2 fields.

## Stability policy (additive-only)

The record is a versioned contract evolved **in lockstep** with the plugin version
([`../scripts/bump-version.sh`](../scripts/bump-version.sh)):

- **Additive (minor/patch bump).** Adding a **new** field. Consumers MUST ignore unknown fields; the
  schema permits additional properties for exactly this reason, so an older consumer keeps working.
- **Breaking (MAJOR bump required).** Any of:
  - **rename** a field,
  - **retype** a field (change its JSON type),
  - **remove** a field, or
  - **change a field's semantic** (what the value means, e.g. pre- vs post-fallback `model`).

A breaking change must bump the **major** version and update both
[`../schema/run-record.schema.json`](../schema/run-record.schema.json) and this document together. The
offline suite's schema-conformance oracle and the schema↔driver drift guard fail if the emitter and the
published schema diverge, so the contract cannot silently rot.

## Content-free guarantee

Both records carry **only** the control-plane facts above — never the prompt, never agent free-text,
never a secret. This is enforced in the driver (records are built from values resolved at
launch/collect, never parsed from the transcript) and asserted by the offline suite. The full
trust-boundary analysis is in [threat-model.md](threat-model.md).

## Aggregate analytics

The append-only [run index](../README.md#run-index) is aggregated read-only by
`scripts/run-history-report.sh` into cross-run trends — run/success counts, the `error_class`
distribution, the agy fallback rate, `sec`/`bytes` summaries, and `tokens`/`cost` aggregates. The
**`unavailable` exclusion rule** applies to every cost/usage aggregate: an `unavailable` value is
**excluded** from the aggregate (and reported as an `unavailable` count), never counted as `0`. The
full metric set and JSON output shape are documented in the README
[Run-history analytics](../README.md#run-history-analytics) section.
