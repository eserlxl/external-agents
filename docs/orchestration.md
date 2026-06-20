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

### Per-stage prompt seeding

Stage 1 receives the user's prompt. Stage N+1 (N ≥ 1) receives the **base prompt plus stage N's
REDACTED artifact** — the transcript after `redact()` has masked secret-shaped tokens — **never the
raw output**. Seeding from the redacted artifact keeps the secret-redaction guarantee intact across the
trust boundary at every stage: a secret an upstream agent surfaces is masked before it reaches the next
agent's prompt. The seeded prompt is still passed as a **single argv element** (or via stdin),
injection-safe, exactly like a single run.

### Stage-failure policy

- **stop (default).** If a stage fails (non-`ok` `error_class`), the pipeline stops; later stages do
  not run. The deterministic outcome records how far it got (completed-through-stage-K).
- **continue (opt-in).** Every stage runs regardless; a failed stage's (redacted) artifact still seeds
  the next. Use when later stages should see earlier failures.

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
