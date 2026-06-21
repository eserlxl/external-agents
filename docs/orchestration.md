# Orchestration patterns

The driver runs agents in **parallel** today (fan-out: `--agent all`). This document specifies the
ordered **pipeline** pattern (Phase 9.4) — a composable sequence where each stage's output seeds the
next — and the **consensus** verdict over a fan-out (Phase 9.5, added below).

## Sequential pipeline

A pipeline runs an **ordered list of agents** in sequence; stage N+1's prompt is seeded from stage N's
output, turning the fleet into a composable chain (e.g. one agent drafts, the next reviews).

### Input

An ordered agent list, e.g. `--pipeline agy,codex,claude` — the list order is the run order. Each stage
is a single agent from the registry; the same agent may appear more than once.

### Invocation

Run the pipeline with `scripts/run-pipeline.sh`, which wraps the driver once per stage:

```
scripts/run-pipeline.sh --pipeline agy,codex,claude --prompt P [--target DIR] [--read-only|--write] [--continue]
```

Everything except `--pipeline`/`--prompt`/`--continue` is passed straight through to `scripts/run-agent.sh`
for each stage, so every per-stage safety gate and record described below applies unchanged.

### Per-stage prompt seeding

Stage 1 receives the user's prompt. Stage N+1 (N ≥ 1) receives the **base prompt plus stage N's
REDACTED artifact** — the transcript after `redact()` has masked secret-shaped tokens — **never the
raw output**. Seeding from the redacted artifact keeps the secret-redaction guarantee intact across the
trust boundary at every stage: a secret an upstream agent surfaces is masked before it reaches the next
agent's prompt. The seeded prompt is still passed as a **single argv element** (or via stdin),
injection-safe, exactly like a single run.

### Stage-failure policy

- **stop (default; omit `--continue`).** If a stage fails (non-`ok` `error_class`), the pipeline stops;
  later stages do not run. The deterministic outcome records how far it got (completed-through-stage-K).
- **continue (opt-in, `--continue`).** Every stage runs regardless; a failed stage's (redacted) artifact
  still seeds the next. Use when later stages should see earlier failures.

### Per-stage artifact contract

Every stage produces the **same per-run records as a single run** — `<agent>.meta.json`, an
`index.jsonl` row, and a masked `<agent>.argv` — and all stages of one pipeline **share a single
pipeline `run_id`** (so the index groups the chain, exactly as a fan-out shares a run_id). Records stay
**control-plane only**.

### Safety invariants (every stage)

A pipeline crosses the data-egress trust boundary at **every** stage, so each stage independently
applies: the containment gate, the non-cwd-write `--yes` gate, transcript redaction (before persist /
echo / seeding the next stage), and the single-argv injection-safe prompt. The pipeline is never a back
door around the single-run safety model — Phase 9.4's per-stage enforcement and stub-driven oracle
prove this offline.

## Consensus

A `--agent all` fan-out already returns N transcripts plus a deterministic **agreement** signal
(`all-ok` / `mixed` / `all-fail`) derived from the per-agent exit-code tally. Consensus extends that
into a **quorum verdict** a caller can act on — still **outcome-based and deterministic**, never an
interpretation of free text.

### Deterministic outcome-consensus verdict

Over the parallel fan-out's per-agent **success tally** (an agent succeeded iff its run was `ok`), the
consensus verdict is a **majority/quorum** over the panel:

- `consensus`  — a strict majority of the panel succeeded (`ok` count > half the panel);
- `no-quorum`  — no majority succeeded: a tie **or** a minority (`ok` count ≤ half the panel but > 0);
- `none`       — no agent succeeded.

It is computed from the per-agent success count / records, **never** from transcript text, so it is
deterministic and content-free (like the agreement signal). It is **additive**: plain fan-out and
single-agent output are unchanged when consensus is not surfaced.

### Honest limit: semantic consensus is gated

This is an **outcome** verdict (did the panel *succeed*), **not** a **semantic** one (do the agents
agree on *what they said*). Content-level semantic consensus would require parsing each agent's
free-text answer into a comparable structured form — which needs a **human-confirmed structured-output
schema** and live-run evidence — so it is **deliberately deferred**, mirroring the driver's existing
agreement-signal honesty note. To compare the agents' actual content, read the verbatim transcripts.
