# external-agents

<div align="center">

[![CI](https://github.com/eserlxl/external-agents/actions/workflows/ci.yml/badge.svg)](https://github.com/eserlxl/external-agents/actions/workflows/ci.yml)
[![Claude Code plugin](https://img.shields.io/badge/Claude%20Code-plugin-8A2BE2.svg)](https://docs.claude.com/en/docs/claude-code/overview)
[![Run external CLIs as sub-agents](https://img.shields.io/badge/dispatch-agy%20%C2%B7%20codex%20%C2%B7%20claude%20%C2%B7%20cursor-0A7BBB.svg)](#what-it-drives)
[![version](https://img.shields.io/badge/version-0.7.0-informational.svg)](.claude-plugin/plugin.json)
[![License: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue.svg)](LICENSE)

</div>

A Claude Code plugin that runs **external coding-agent CLIs** — `agy`, `codex`, and
`cursor` (and optionally `claude`) — as autonomous sub-agents from inside a Claude Code
session. Hand a task to one external agent or fan one prompt out to all of them in parallel,
then collect every response inline. The `cursor` agent runs Cursor's own models (Composer 2.5).

It is a *delegation* tool: an arbitrary task, your choice of agent, and **read-write by
default** so the agents can actually do work (use `--read-only` for analysis-only runs).

## What it drives

| agent  | cli           | read-write (default)                                            | read-only (`--read-only`)                       |
|--------|---------------|-----------------------------------------------------------------|-------------------------------------------------|
| agy    | `agy`         | `-p P --add-dir DIR --dangerously-skip-permissions [--model M]` | `-p P --sandbox --add-dir DIR [--model M]`      |
| codex  | `codex exec`  | `-s workspace-write -C DIR --skip-git-repo-check [-m M] [-c model_reasoning_effort="E"] P` | `-s read-only -C DIR --skip-git-repo-check ... P` |
| claude | `claude`      | `-p P --permission-mode acceptEdits [--model M] [--effort E]`   | `-p P --allowedTools Read Grep Glob [--model M] [--effort E]` |
| cursor | `cursor-agent`| `-p --force --trust --workspace DIR [--model M] -- P`           | `-p --mode plan --trust --workspace DIR [--model M] -- P` |

The prompt is always passed as a single argv element (or via stdin), never `eval`'d or
word-split, so it is injection-safe regardless of content.

A few CLI caveats worth knowing:

- **agy read-only is best-effort.** `agy --sandbox` restricts the terminal but does **not**
  hard-block agy's file-edit tools, so an agy read-only run *can* still mutate the tree.
  For an enforced read-only guarantee use `codex`/`claude`/`cursor` (their read-only modes are
  hard), or point `--target` at a throwaway copy. The script warns whenever agy runs read-only.
- **claude write + shell.** `--permission-mode acceptEdits` (the default) auto-accepts file
  edits but **denies** other Bash non-interactively — a "do X and run the tests" task will
  edit and then silently skip the tests at rc=0. For tasks that must build/test/run commands,
  pass `--claude-perm bypassPermissions`.
- **cursor needs auth, and its binary is `cursor-agent`.** The `cursor` agent calls
  `cursor-agent` (the headless Cursor CLI), **not** `cursor` (the IDE). It must be signed in
  first — `cursor-agent login` (or set `CURSOR_API_KEY`) — and shares auth/config with the
  desktop app. Its read-only mode (`--mode plan`) is **enforced** (analyze/plan, no edits),
  so it is a hard guarantee like codex/claude; write mode uses `--force` to auto-approve
  edits and shell.

## Install

Load this directory into Claude Code as a local plugin (e.g. `/plugin` → add a local
directory pointing here), or symlink it into your plugins directory. Once loaded you get:

- the **`external-agents`** skill — triggers on natural language ("ask codex to …",
  "have the external agents review …", "delegate this to agy");
- the **`/external-agents`** slash command — explicit dispatch.

Requires `agy`, `codex`, the `cursor-agent` CLI (for the `cursor` agent; run
`cursor-agent login` once), and — for the `claude` agent — `claude` on `PATH`, plus `jq`
**or** `python3` to read `agents.json`. Optionally `antigravity-usage`
(`npm i -g antigravity-usage`) enables agy's [quota-aware fallback](#agy-quota-aware-fallback-antigravity).
Verify the install with the **`--check` preflight** — it reports the JSON reader (`jq`/`python3`) and
whether each agent CLI is on `PATH`:

```bash
bash scripts/run-agent.sh --check
```

`--check` prints one line per check and a final tally:

- `ok   <name> <path>` — the JSON reader (`jq`/`python3`) or an agent CLI is present on `PATH`.
- `MISS <name> …` — a required piece is missing (an agent CLI not installed, or the `cursor-agent`
  binary the `cursor` agent needs).
- `info agy-qta …` — optional only: whether `antigravity-usage` (agy's quota-fallback helper) is on
  `PATH`; this is never counted as missing.

It ends with `external-agents: <N> missing` and **exits non-zero when `N > 0`**. A clean install of the
agents you intend to use therefore reports **`0 missing` and exits `0`** — that is the pass criterion.
Scope the check to a single agent with `--agent <name>` if you don't use all four:

```bash
bash scripts/run-agent.sh --agent codex --check && echo "codex ready"
```

**What `--check` does and does not prove.** `--check` is a **presence** preflight: it confirms the
config reader (`jq`/`python3`) is available, `agents.json` is readable, and each agent CLI is on
`PATH`. It does **not** invoke any CLI, verify authentication, or exercise read-only enforcement — a
CLI can be present yet unauthenticated or misconfigured, so a passing `--check` is necessary but not
sufficient for a working run. Proving an agent actually round-trips (and that the enforced read-only
guarantee holds) is the job of the opt-in [live smoke harness](#live-smoke-opt-in), never `--check`.

There is intentionally **no built-in auth/health probe** on `--check`: a meaningful check (is this
CLI signed in and able to respond?) needs an authenticated, networked call that is neither free nor
side-effect-free, and wiring it into `--check` would couple the offline gate to live CLIs — so it is
deliberately deferred. **Authentication is your responsibility:** sign each agent in once (e.g.
`cursor-agent login`, plus the sign-in `codex` / `agy` / `claude` each need), then confirm a real
round-trip with the opt-in [live smoke harness](#live-smoke-opt-in). The exact per-agent sign-in step
and what "ready" means for each agent are consolidated in the
[per-agent auth prerequisites](#per-agent-auth-prerequisites-readiness) reference below.

**Presence vs. readiness, end to end.** Three checks, three guarantees, in order of strength: the
[release tag-gate](RELEASING.md) check confirms a published tag equals the lockstep version;
`--check` (offline, exits non-zero on a missing CLI) proves **presence**; and the opt-in live smoke
plus the [per-agent auth prerequisites](#per-agent-auth-prerequisites-readiness) prove **readiness**
(an authenticated agent that actually round-trips). The offline gate performs the presence check and
the tag check, but **never** the auth step — readiness is always an explicit, opt-in act.

**Verifying a packaged release.** Beyond `--check`, an opt-in install/upgrade smoke
([`tests/install-smoke.sh`](tests/install-smoke.sh)) proves the package installs and upgrades **from a
published tag** (not a branch): armed with `EXTERNAL_AGENTS_LIVE=1` it clones the repo at a tag into a
throwaway tree and confirms the loaded driver answers `--check` (presence) and `--version` (the
lockstep version), with the upgrade variant asserting `--version` advances across tags. Without the
arming switch it is a clean no-op, exactly like the live smoke harness — the procedure is in
[RELEASING.md](RELEASING.md).

### Per-agent auth prerequisites (readiness)

`--check` proves an agent's CLI is **present**; this reference is the **readiness** contract — the
exact one-time auth step each agent needs and what "ready" means. It is keyed to the driver's agent
names and the binaries `agent_bin` resolves in `scripts/run-agent.sh`. Do the auth step once, then
confirm a real round-trip with the opt-in [live smoke](#live-smoke-opt-in). These are **auth steps
only** — no key or token value belongs in any committed file.

| Agent | Binary on `PATH` | One-time auth step | "Ready" means |
|-------|------------------|--------------------|---------------|
| `codex` | `codex` | Sign in to the `codex` CLI (its own login). | `codex` present **and** an armed live smoke round-trips. |
| `agy` | `agy` | Sign in to Antigravity / `agy` (its own login). | `agy` present **and** armed live smoke round-trips; for quota-aware fallback also install `antigravity-usage` (below). |
| `cursor` | `cursor-agent` | Run `cursor-agent login`, **or** set the `CURSOR_API_KEY` environment variable. | `cursor-agent` present **and** armed live smoke round-trips. |
| `claude` | `claude` | Authenticate the `claude` CLI (Claude Code sign-in / API key in your environment). | `claude` present **and** armed live smoke round-trips. |
| `antigravity-usage` *(optional)* | `antigravity-usage` | `npm i -g antigravity-usage`, then `antigravity-usage login` (or keep the Antigravity IDE open). | Present on `PATH` so agy's [quota-aware fallback](#agy-quota-aware-fallback-antigravity) is active. **Never required** — its absence just means high/xhigh always use the Gemini fallback. |

Readiness is always an explicit, opt-in act: the offline gate verifies **presence** only (via
`--check`) and never performs any of the auth steps above.

### Confirm an agent is usable: presence → ready

Two tiers, run in order, to know an agent will actually work:

1. **Presence (offline).** `bash scripts/run-agent.sh --agent <name> --check` — exits **non-zero** if
   the CLI (or the `cursor-agent` binary the `cursor` agent needs) is missing, `0` when present. This
   never authenticates or makes a network call.
2. **Readiness (opt-in).** After the one-time auth step above, arm the live smoke and read the
   per-agent verdict:

   ```bash
   EXTERNAL_AGENTS_LIVE=1 bash tests/live-smoke.sh --agent <name>
   cat "${EXTERNAL_AGENTS_OUT:-$HOME/.external-agents/logs}"/live-smoke/status.txt
   ```

   A `<name>  live-verified` line means the agent round-tripped (ready); `failed` or
   `skipped-not-reachable` mean it is not. The [Live smoke](#live-smoke-opt-in) section defines the
   full status vocabulary.

The required offline gate runs **only** step 1's presence check and **never** performs step 2's auth
step — readiness is always an explicit, opt-in act.

## Usage

Natural language (skill):

> ask codex to add input validation to the login handler
> have the external agents review the changes on this branch — read only
> delegate the failing test fix to agy

Slash command:

```
/external-agents codex implement the retry logic in src/client.py
/external-agents all read-only audit this repo for security issues
/external-agents fix the flaky test in tests/test_cache.py
```

Direct script (what the skill/command call under the hood):

```bash
# single agent, read-write (default)
bash scripts/run-agent.sh --agent codex --target "$PWD" --prompt-file - <<'PROMPT'
Implement X. Run the tests when done.
PROMPT

# fan out to every enabled agent, read-only
bash scripts/run-agent.sh --agent all --read-only --prompt "Review this branch; cite file:line."

# pick an effort tier — each agent maps it to its own model + native effort
bash scripts/run-agent.sh --agent all --effort high --prompt "Refactor the parser."

# preview the exact command without running it
bash scripts/run-agent.sh --agent agy --dry-run --prompt "..."
```

### Options

| flag | meaning |
|------|---------|
| `--agent A` | `agy` \| `codex` \| `claude` \| `cursor` \| `all` (all enabled in `agents.json`) |
| `--prompt P` / `--prompt-file F` / `--prompt-file -` | the task (literal, file, or stdin) |
| `--target DIR` | where the agents work (default: cwd) |
| `--write` / `--read-only` | read-write (default) vs analysis-only (mutually exclusive) |
| `--yes` / `-y` | confirm a write run whose `--target` is not the current directory |
| `--effort TIER` | effort level / model tier: `low` \| `medium` \| `high` \| `xhigh`. Maps, per agent, to the model + native effort in `agents.json` (optional; blank = config `default_tier`) |
| `--model M` | model override — wins over the tier's model; native effort still comes from the tier |
| `--claude-perm MODE` | claude write-mode permission mode (default `acceptEdits`; use `bypassPermissions` for shell) |
| `--timeout S` | per-agent timeout, seconds (default 1800) |
| `--out DIR` | transcript dir (default `~/.external-agents/logs/<project>`; the base dir is overridable with the `EXTERNAL_AGENTS_OUT` env var) |
| `--conf FILE` | agent config JSON (default `agents.json`) |
| `--list` / `--check` / `--discover` / `--dry-run` / `--version` | inspect config / preflight reader + CLIs / machine-readable agent reachability / preview argv / print the plugin version |
| `--json` | also emit a machine-readable JSON run summary (opt-in; default output unchanged) |

## Configuration — `agents.json`

The caller picks **one effort level** — `low`, `medium`, `high`, or `xhigh` — and
`agents.json` maps that tier to the right **model + native effort for each agent**. So a
single `--effort high` resolves, per agent, to:

| `--effort` | agy (tier baked into model) | codex | claude | cursor (tier baked into model) |
|------------|-----------------------------|-------|--------|--------------------------------|
| `low`      | `Gemini 3.5 Flash (Low)`        | `gpt-5.5` effort `low`    | `claude-haiku-4-5`  | `gpt-5-mini` |
| `medium`   | `Gemini 3.5 Flash (Medium)`     | `gpt-5.5` effort `medium` | `claude-sonnet-4-6` | `composer-2.5` |
| `high`     | `Claude Sonnet 4.6 (Thinking)`† | `gpt-5.5` effort `high`   | `claude-opus-4-8` effort `high`  | `gpt-5.5-high` |
| `xhigh`    | `Claude Opus 4.6 (Thinking)`†   | `gpt-5.5` effort `xhigh`  | `claude-opus-4-8` effort `xhigh` | `claude-opus-4-8-thinking-high` |

† agy `high`/`xhigh` are **quota-aware**: the limited 3rd-party primary runs only when `antigravity-usage`
confirms remaining quota; otherwise they fall back to a larger-limit Gemini — `Gemini 3.5 Flash (High)`
for `high`, `Gemini 3.1 Pro (High)` for `xhigh` (see below).

`agy` and `cursor` bake the tier into the model name and ignore a separate effort;
`codex`/`claude` take model and effort separately. The cursor tiers form a cheap→premium
ladder — `gpt-5-mini` (low), `composer-2.5` (medium, Cursor's agentic workhorse),
`gpt-5.5-high` (high), `claude-opus-4-8-thinking-high` (xhigh). All are **non-fast**,
ZDR-respecting ids on purpose: Cursor's CLI default is a `-fast` variant (e.g.
`composer-2.5-fast`), which spends fast/priority requests — keep the plain ids, or switch a
tier to a `-fast` model if you do want priority routing. (Avoid the `claude-fable-5-*` ids:
they are marked **NO ZDR**.) Run `cursor-agent models` (once signed in) to see every id your
account exposes. With no `--effort`, the config's `default_tier` is used (ships as `medium`).
A per-run `--model M` overrides only the resolved model — the native effort still comes from the tier.

`enabled: true` agents run under `--agent all`; a named `--agent agy|codex|claude|cursor` runs
even if disabled. Ships with `agy` + `codex` + `cursor` enabled and `claude` disabled:

```json
{
  "default_tier": "medium",
  "agents": {
    "agy": {
      "enabled": true,
      "tiers": {
        "low":   { "model": "Gemini 3.5 Flash (Low)" },
        "xhigh": { "model": "Claude Opus 4.6 (Thinking)", "fallback": "Gemini 3.1 Pro (High)" }
      }
    },
    "codex":  { "enabled": true,  "tiers": { "high":   { "model": "gpt-5.5", "effort": "high" } } },
    "claude": { "enabled": false, "tiers": { "low":    { "model": "claude-haiku-4-5" } } },
    "cursor": { "enabled": true,  "tiers": { "medium": { "model": "composer-2.5" } } }
  }
}
```

Run `bash scripts/run-agent.sh --list` to print the full resolved table, enabled status,
and `default_tier`. Reading the JSON needs `jq` (preferred) or `python3` on `PATH`.

### Config schema and validation

`schema/agents.schema.json` is a JSON Schema (draft-07) for `agents.json`. Each schema key maps to
the `cfg` query op the driver reads it with — the same op surface in both the `jq` and `python3`
backends — so the schema, the config, and both readers stay aligned:

| schema key | `cfg` op | meaning |
|------------|----------|---------|
| `default_tier` | `default_tier` | tier used when `--effort` is omitted |
| `agents` | `agents` | the set of configured agents |
| `agents.<a>.enabled` | `enabled` | whether `<a>` runs under `--agent all` |
| `agents.<a>.tiers` | `tiers` | the tier map for `<a>` |
| `…tiers.<t>.model` | `model` | model id for tier `<t>` |
| `…tiers.<t>.effort` | `effort` | native effort (codex/claude) |
| `…tiers.<t>.fallback` | `fallback` | agy-only quota-fallback model |

Only the `agy` agent's tiers may carry `fallback` (the schema enforces this). Validate the shipped
config against the schema with `jq` + `python3`:

```bash
python3 -c "import json,jsonschema; jsonschema.validate(json.load(open('agents.json')), json.load(open('schema/agents.schema.json')))"
```

The contract: `default_tier` and `agents` are required; each agent requires `enabled` and `tiers`;
each tier requires `model`, with `effort` and `fallback` optional (and `fallback` accepted **only**
on `agy`). `tests/run.sh` validates the shipped config against the schema and asserts that bad
fixtures (missing `model`, wrong-typed `default_tier`, non-object `tiers`, non-agy `fallback`) are
rejected; CI runs the same validation on every push/PR, so a contract violation fails the build.

### agy quota-aware fallback (Antigravity)

`agy` is Google's Antigravity, which gives **large Gemini limits** but **small, precious
3rd-party limits** (Claude Opus/Sonnet, GPT-OSS). To spend the scarce ones deliberately, an
`agy` tier may carry a `fallback`:

```json
"high":  { "model": "Claude Sonnet 4.6 (Thinking)", "fallback": "Gemini 3.5 Flash (High)" },
"xhigh": { "model": "Claude Opus 4.6 (Thinking)",   "fallback": "Gemini 3.1 Pro (High)" }
```

Before launching such a tier, `run-agent.sh` consults the free **`antigravity-usage --json`**
CLI (`npm i -g antigravity-usage`) for the primary model's remaining quota and uses the
primary **only when quota is positively confirmed available**. If the primary is exhausted
**or the quota is unconfirmable**, it uses the Gemini `fallback` instead — so scarce 3rd-party
/ Opus quota is **never spent without a check**. This applies to **agy only**; a per-run
`--model M` is explicit intent and skips the check.

> **You must open the Antigravity IDE** (or run `antigravity-usage login`) for the quota
> check to see data. While it can't (IDE closed / `antigravity-usage` not installed), `agy`'s
> 3rd-party tiers transparently fall back to Gemini. Tune with
> `EXTERNAL_AGENTS_AGY_MIN_REMAINING` (% remaining below which to fall back; default `5`),
> `EXTERNAL_AGENTS_AGY_QUOTA_TIMEOUT` (seconds to wait for `antigravity-usage`; default `20`),
> or `EXTERNAL_AGENTS_AGY_QUOTA_CMD` (override the quota command).

This quota-fallback is **verified against the real CLI** by the opt-in
[live harness](#live-smoke-opt-in): it feeds the real `antigravity-usage` output through the
driver's resolver and asserts the decision matches the quota state (primary **iff** available, else
the Gemini fallback). The probe is **read-only** — it never calls the quota-spending `wakeup` — and
when the quota is unconfirmable (IDE closed / not logged in) it degrades to the fallback, **never**
spending the unconfirmed primary. It also records the real output's keys/types (no values) as a
schema-drift detector.

**Decision contract.** The quota check is a strict, read-only protocol:

1. **Read-only.** The driver runs only `antigravity-usage --json` (read-only); it **never** calls the
   quota-spending `wakeup`.
2. **Primary iff confirmed-available.** The limited 3rd-party primary runs **only** when the quota CLI
   positively reports it available.
3. **Fallback otherwise.** On `exhausted`, or an `unknown`/unconfirmable result (IDE closed, CLI
   absent, timeout, or unparseable output), the larger-limit Gemini `fallback` runs instead — the
   unconfirmed primary is **never** spent.
4. **Keys read.** The decision reads only these `antigravity-usage --json` fields: the top-level
   `models` array, and each model's `label`, `remainingPercentage`, and `isExhausted`. No other field,
   value, or account identifier is read into the run or written to any recorded evidence.

This contract is pinned offline (`tests/run.sh`: the fallback model-pick, graceful-degradation,
never-spend-`wakeup`, and sanitised quota-schema oracles) and verified against the real CLI by the
live harness above.

## Fan-out observability

A `--agent all` fan-out records, per agent, a **result record** built entirely from **control-plane
facts** — values the driver already resolved at launch/collect time, **never parsed from the
transcript**:

| field | source |
|-------|--------|
| `agent` | the agent name |
| `model` | the **resolved** model (post-fallback for agy) |
| `tier` | the effort tier (`--effort`, else `default_tier`) |
| `effort` | the tier's native effort (codex/claude) |
| `mode` | `read-only` / `write` |
| `rc` | the agent process exit code |
| `sec` | wall-clock seconds |
| `bytes` | redacted transcript size |
| `fallback` | `1` iff the agy quota fallback swapped the primary model |

**Contract.** Every field is a **resolved fact**, never inferred from the transcript text: `model` and
`fallback` come from what the driver actually resolved at launch (`run_one`'s `.model`/`.fallback`
sidecars), `tier`/`effort`/`mode` from the config and run mode, and `rc`/`sec`/`bytes` from the run
files. So `fallback=1` means the agy quota fallback *actually swapped* the primary (not merely that
quota was checked), and the record never depends on parsing an agent's free-text output. The record
is the single source the cross-agent summary and the opt-in JSON output (below) both render from.

### Cross-agent summary

A `--agent all` fan-out prints a compact **summary block** after the transcripts — one row per agent
from the records above:

```
===== fan-out summary =====
  agent   rc  model                      tier      sec    bytes fallback
  agy     0   Gemini 3.5 Flash (High)    high        0        5 1
  codex   0   gpt-5.5                    high        1        5 0
  cursor  0   gpt-5.5-high               high        0        5 0
```

How to read it: the summary is a **digest, not a replacement** — the full, verbatim (redacted)
transcripts are still printed above it, and the `ok/failed` tally still goes to stderr. Use the
summary to compare agents at a glance — who succeeded (`rc=0`), which model each resolved to (note
agy's `fallback`), and how they differ in time (`sec`) and output size (`bytes`) — then scroll up to
the matching `===== <agent> … =====` transcript for the actual content. On a **write** fan-out the
summary adds a note that the post-write `git changes after write` block is **target-wide** (all
agents share one tree), so a change can't be attributed to a single agent. Single-agent runs print no
summary.

The summary closes with a deterministic **agreement** line derived from the success tally —
`all-ok`, `mixed`, or `all-fail` — so a caller gets an at-a-glance outcome signal for the fan-out.
For a **read-only** fan-out on a git target it also adds a **no-mutation** line stating whether all
agents left the shared tree unchanged (every read-only mode should — agy is best-effort).

These agreement signals are **deterministic and outcome-based** — they come from the per-agent
exit-code tally and the target tree's git state, never from interpreting the agents' answers.
**Semantic content agreement** (do the agents actually agree on *what they said*?) is **not provided**:
that needs a human-confirmed cross-agent summary schema and live-run evidence, so it is deliberately
deferred. Read the verbatim transcripts to compare the agents' actual content.

### JSON run summary (`--json`)

`--json` additionally emits one machine-readable JSON document (in addition to the human output,
which is unchanged) with this shape — run-level fields plus one object per agent and the agreement
signal, all control-plane facts (no transcript content):

```json
{
  "mode": "readonly", "tier": "high", "ok": 3, "fail": 0, "count": 3, "agreement": "all-ok",
  "agents": [
    { "agent": "agy", "model": "Gemini 3.5 Flash (High)", "tier": "high", "effort": "(none)",
      "mode": "readonly", "rc": 0, "sec": 0, "bytes": 23, "fallback": true }
  ]
}
```

The offline suite validates that the emitted document is well-formed and carries these required keys.

The document is written to **stdout** alongside the human output — `--json` itself is a streaming
summary you can pipe (`… --json | jq …`), not a stored artifact. For **durable, stable on-disk
persistence**, every run also writes a [per-run metadata record](#per-run-metadata-record) per agent
(below); a cross-run index over those records is added in [Run index](#run-index).

## Run metadata and history

### Per-run metadata record

Beyond the in-memory [fan-out record](#fan-out-observability), **every run — single agent *or*
`--agent all` fan-out — writes one structured JSON metadata record per agent** next to that agent's
transcript, capturing the run's **control-plane truth** so you never have to re-parse a transcript to
know how a run resolved. Each field is a **post-fallback resolved** value (what was *actually* used,
not what was requested):

| field | meaning (post-fallback resolved truth) | source |
|-------|----------------------------------------|--------|
| `agent` | the agent name | the run request |
| `model` | the **resolved** model actually used (post-fallback for agy) | `run_one`'s `.model` sidecar |
| `tier` | the effort tier (`--effort`, else `default_tier`) | the run request / config |
| `effort` | the tier's native effort (codex/claude; `(none)` if unset) | `agents.json` |
| `mode` | `readonly` / `write` | the run mode |
| `target` | the resolved directory the agent worked in | resolved `--target` |
| `rc` | the agent process exit code | the run |
| `sec` | wall-clock seconds | the run |
| `bytes` | redacted transcript size | the run |
| `fallback` | `true` iff the agy quota fallback swapped the primary model | `run_one`'s `.fallback` sidecar |
| `timestamp` | run launch time, UTC ISO-8601 (e.g. `2026-06-20T12:00:00Z`) | the run |

`model`, `fallback`, `tier`, `effort`, and `mode` are exactly the resolved facts the fan-out record
carries; the per-run record additionally pins the **`target`** the agent worked in and the
**`timestamp`** it launched, and — unlike the fan-out summary, which is fan-out only — is written
durably to disk for *every* run. The post-fallback rule is decisive: for an agy quota fallback,
`model` is the **Gemini fallback actually used** and `fallback` is `true` (never the unconfirmed
primary). Like the fan-out record, it is built **only** from values resolved at launch/collect time —
**never parsed from the transcript** — so it carries no agent free-text and no prompt.

The record's field set and JSON types are published as a draft-07 contract in
[`schema/run-record.schema.json`](schema/run-record.schema.json), which validates both this
`meta.json` record and the [run index](#run-index) row. The field-by-field reference and the
**additive-only stability policy** (which changes require a major version bump) are in
[`docs/run-record-contract.md`](docs/run-record-contract.md).

### Error classification

Every run is classified into **one** of a closed set of error classes, so a caller can tell a
recoverable failure from a permanent one (recorded as the per-run record's `error_class` field):

| class | meaning | retryable? |
|-------|---------|------------|
| `ok` | the run succeeded (`rc` 0) | n/a (success) |
| `safety-refusal` | a driver pre-launch gate refused — containment, the non-cwd `--yes` confirmation, `--read-only`/`--write` exclusion, or an invalid `--timeout` | **never** (a deliberate guard, not a transient state) |
| `timeout` | the run exceeded `--timeout` | retryable (opt-in) |
| `transient` | a recoverable external failure (network blip, provider 5xx / rate-limit shaped) | retryable |
| `auth` | the agent is unauthenticated or its credentials were rejected | no (re-authenticate first) |
| `contract` | the agent broke the expected contract (malformed/empty output) | no |
| `unknown` | an unclassified non-zero exit | no (conservative default) |

The **retryable subset** is `transient` (always) and `timeout` (opt-in). A `safety-refusal` is
**never** retried — retrying would only repeat the same deliberate refusal. This taxonomy is the
canonical contract; the driver comment in `scripts/run-agent.sh` (above `run_one`) and the
[threat model](docs/threat-model.md#error-classification-and-retry-safety) restate the same closed set.

### Bounded retry

Retryable failures can be re-attempted within **explicit bounds**, so a delegation never silently
amplifies cost or data egress through uncontrolled re-runs. Retry is **opt-in and off by default**:

| env var | default | effect |
|---------|---------|--------|
| `EXTERNAL_AGENTS_RETRY_MAX` | `0` | maximum retries of a **retryable** outcome (`transient`; `timeout` only if enabled below). `0` = never retry. |
| `EXTERNAL_AGENTS_RETRY_BACKOFF` | `1` | seconds to wait before each retry. |
| `EXTERNAL_AGENTS_RETRY_ON_TIMEOUT` | `0` | set to `1` to also retry a `timeout` outcome. |

Only `transient` (and, when enabled, `timeout`) outcomes are retried — a `safety-refusal`, `auth`, or
`contract` failure is **never** retried. Each run records two additive fields: `attempts` (total
launch attempts = `1` + retries) and `retried` (`true` iff `attempts` > 1). With retry disabled
(the default) every run records `attempts: 1`, `retried: false`.

**Where it lives.** The record is written to `<transcript-dir>/<agent>.meta.json` — the *same*
per-project directory as that agent's transcript (default `~/.external-agents/logs/<project>`,
overridable via [`--out`](#options) or the `EXTERNAL_AGENTS_OUT` base). One file per agent per run,
overwritten on the next run that targets the same directory. Inspect or aggregate it with any JSON
tool, e.g.:

```bash
jq . "${EXTERNAL_AGENTS_OUT:-$HOME/.external-agents/logs}"/<project>/codex.meta.json
```

**Secret-free by construction.** Because the record holds only the control-plane facts the driver
resolved — never the transcript, never the prompt — no agent free-text, prompt text, or
secret-shaped token can reach it (the transcript itself is separately [redacted](#safety)). So
`*.meta.json` is safe to collect, ship, or index for run history.

### Run index

Alongside the per-run records, the driver maintains a single durable **run index** — an append-only
[JSON Lines](https://jsonlines.org/) file that accrues **one row per agent per run** across *all*
projects, so you get a chronological run history without walking the per-project transcript tree.

**Where it lives.** `<base>/index.jsonl`, where `<base>` is the transcript root
(`EXTERNAL_AGENTS_OUT`, default `~/.external-agents/logs`); with an explicit `--out DIR` the index is
written inside that directory. It is **append-only** — never rewritten — so each row is a permanent
record of one agent run and concurrent runs simply append.

**Row fields.** Each line is one JSON object: a run id and timestamp that group a fan-out, the
project namespace, and the same post-fallback resolved fields the
[per-run record](#per-run-metadata-record) carries:

| field | meaning |
|-------|---------|
| `run_id` | groups the agents of one invocation (a `--agent all` fan-out shares one `run_id`) |
| `timestamp` | run launch time, UTC ISO-8601 |
| `project` | the `<project>` transcript namespace (repo / repo/subdir / leaf) |
| `agent`, `model`, `tier`, `effort`, `mode`, `target`, `rc`, `sec`, `bytes`, `fallback` | the per-run [resolved fields](#per-run-metadata-record) (post-fallback, control-plane only) |

Like the per-run record, every row is **control-plane only** — built from values resolved at
launch/collect, never the transcript — so the index never accrues agent free-text, prompt text, or
secrets.

**Inspecting it.** The index is plain JSON Lines — **no special subcommand** — so you read it with
standard tools (`tail`, `jq`, `grep`, `python3`). The base resolves to
`${EXTERNAL_AGENTS_OUT:-$HOME/.external-agents/logs}/index.jsonl`:

```bash
IDX="${EXTERNAL_AGENTS_OUT:-$HOME/.external-agents/logs}/index.jsonl"

# the 10 most recent agent runs, as a table
tail -n 10 "$IDX" | jq -r '[.timestamp, .project, .agent, .rc, .model, "\(.sec)s"] | @tsv'

# only the runs that failed (rc != 0)
jq -c 'select(.rc != 0)' "$IDX"

# every run where the agy quota fallback fired
jq -c 'select(.fallback)' "$IDX"
```

Without `jq`, the same rows read fine in `python3` (`for l in open(IDX): json.loads(l)`) or as raw
lines with `tail`/`grep`.

### Cost, latency, and quality signals

Some agent CLIs print machine-readable **cost / token signals** in their output (e.g. a token count
or a dollar cost). When present, the driver lifts them — **best-effort** — into an optional `signals`
object on the [per-run record](#per-run-metadata-record) and [index row](#run-index); when a signal
is **absent or unrecognized**, that field is the explicit string `"unavailable"` — **never** a
guessed or fabricated number, and never a silent gap.

**What is recognized.** Extraction is **capability-aware per agent** and deliberately
**conservative** — it matches only tightly-anchored shapes, so ordinary transcript prose is never
mistaken for a metric:

| signal | recognized shape (case-insensitive, anchored) |
|--------|-----------------------------------------------|
| `tokens` | a `tokens used: N` / `total tokens: N` / `N tokens` line |
| `cost` | a `cost: $X` / `total cost: $X` line |

**Status — best-effort, not yet live-confirmed.** These recognizers are derived from the CLIs'
*expected* output shapes; **no signal has been confirmed against a live run in this repo's offline
work** (the offline CI never launches a real CLI — see [Testing](#testing)). So in practice a field
reads `"unavailable"` unless a CLI's real output happens to match a recognized shape. Confirming
*which* agents actually emit *which* signals — and their exact live shapes — is left to the opt-in
[live/E2E harness](#live-smoke-opt-in); the offline suite proves only that a recognized shape **is**
extracted and an absent one yields `"unavailable"` (via committed fixtures).

**Reading the signals (consumer caveat).** Treat `"unavailable"` as *no data* — filter it out before
aggregating (e.g. `jq 'select(.signals.tokens != "unavailable")'`), never as a zero. A present value
is the **CLI's own self-report**, lifted verbatim and best-effort — not independently measured — so
use it for rough comparison, not billing. For latency and output size, prefer the
**driver-measured** [`sec` and `bytes`](#per-run-metadata-record) fields, recorded for *every* run
regardless of what the CLI prints; `signals.tokens` / `signals.cost` are the optional, CLI-dependent
extras layered on top.

### Run-history analytics

The append-only [run index](#run-index) accumulates one row per agent per run; the read-only
analytics surface ([`scripts/run-history-report.sh`](scripts/run-history-report.sh)) aggregates it
into cross-run trends **without ever mutating it**. It derives this metric set:

| metric | meaning |
|--------|---------|
| `runs` | total rows (one per agent per run) |
| `ok` / `failed` | rows whose outcome is `ok` (`error_class == "ok"`, or `rc == 0` for pre-8.2 rows) vs not |
| `success_rate` | `ok / runs` (0..1) |
| `error_class` | the per-class distribution, e.g. `{"ok": 12, "transient": 3, "auth": 1}` |
| `fallback` | `{ "count": n, "rate": r }` — rows where the agy quota fallback fired |
| `sec` / `bytes` | `{ "min", "max", "mean" }` over the **driver-measured** latency / size |
| `tokens` | `{ "counted", "unavailable", "sum", "mean" }` over numeric `signals.tokens` only |
| `cost` | `{ "counted", "unavailable", "sum" }` over numeric `signals.cost` only |

**The `unavailable`-exclusion rule is decisive:** `signals.tokens` / `signals.cost` aggregates count
**only present (numeric) values**; an `unavailable` row is **excluded from the denominator, never
counted as zero** (which would understate the true average). Each aggregate reports both the
`counted` and `unavailable` row counts so the exclusion is auditable.

The machine-readable JSON output shape is one document:

```json
{
  "runs": 16,
  "ok": 12,
  "failed": 4,
  "success_rate": 0.75,
  "error_class": { "ok": 12, "transient": 3, "auth": 1 },
  "fallback": { "count": 5, "rate": 0.3125 },
  "sec": { "min": 1, "max": 42, "mean": 8.5 },
  "bytes": { "min": 10, "max": 4096, "mean": 512.0 },
  "tokens": { "counted": 9, "unavailable": 7, "sum": 81000, "mean": 9000.0 },
  "cost": { "counted": 9, "unavailable": 7, "sum": 1.23 }
}
```

A human-readable table is also available. The surface is **strictly read-only** over the append-only
index, and the field contract it consumes is in
[`docs/run-record-contract.md`](docs/run-record-contract.md).

**Consumer caveat.** The `tokens` and `cost` aggregates are built from **best-effort,
CLI-self-reported** signals — they are **not billing-grade** and must not be treated as authoritative
cost (see [Cost, latency, and quality signals](#cost-latency-and-quality-signals)). For latency and
output size, trust the **driver-measured** `sec` and `bytes` aggregates (recorded for *every* run),
not an agent's self-reported numbers. A trend summarises what the CLIs reported, not an audited ledger.

## Safety

For the full trust-boundary analysis and the per-CLI enforcement matrix, see
[docs/threat-model.md](docs/threat-model.md); to report a vulnerability privately, see
[SECURITY.md](SECURITY.md).

- **Read-write is the default.** The agents can modify anything under `--target`. Point it
  at the tree you actually want changed; use `--read-only` when you only want analysis.
- **Non-cwd writes need `--yes`.** A write run whose `--target` is not the current working
  directory is refused unless you pass `--yes`, so a wrong/misremembered target can't launch
  a writing agent silently.
- **Plugin self-protection (both directions).** The script refuses to write inside its own
  plugin tree *and* refuses a `--target` that contains the plugin (e.g. the monorepo root,
  which would also expose sibling repos). Paths are resolved physically (`pwd -P`) so
  symlinks can't slip past the check.
- **External providers.** `agy`, `codex`, and `cursor` send the target tree to external
  services — never point them at private IP or secrets.
- **Transcript redaction (best-effort).** Before a transcript is persisted or echoed, the driver
  masks secret-shaped tokens (`sk-`/`pk-`, `gh*_`/`github_pat_`, `xox*-`, `AKIA…`, `Bearer`
  tokens, `KEY=`/`TOKEN=`/`SECRET=`/`PASSWORD=` assignments, and long high-entropy runs) as
  `<REDACTED>`. This is **length-bounded and best-effort, not a guarantee** of total secret
  removal — short or unusual secrets can slip through and long non-secret strings can be
  over-masked, so still treat transcripts as sensitive. See
  [docs/threat-model.md](docs/threat-model.md) for the threat-model entry.
- **Enforcement is uneven across CLIs** — see the caveats above: agy read-only is
  best-effort; claude write needs `bypassPermissions` for shell; cursor needs prior auth
  (`cursor-agent login`) and its read-only mode (`--mode plan`) is enforced. The canonical
  per-CLI enforcement matrix lives in
  [docs/threat-model.md](docs/threat-model.md#per-cli-read-only-enforcement-matrix); it is
  asserted against the driver's resolved argv by the offline test suite and **observed
  end-to-end** by the opt-in live harness (enforced agents leave a sandbox byte-identical;
  agy is reported best-effort — see [Live smoke](#live-smoke-opt-in)).
- **Verification is produced, not just advised.** After a write run on a git target the
  script prints `git status` / `git diff --stat`; if the target isn't a git repo it warns
  that there is no baseline to diff or revert. Still review the diff before trusting the
  agent's self-report.

## Testing

Offline, dependency-light tests live in `tests/`. They exercise `run-agent.sh` only
through `--dry-run`, `--list`, and its early-exit error paths, so **no external agent
CLI is launched** — they assert the `agents.json` tier→argv mapping, jq/python3 config
parity, the effort and write-mode safety gates, and that the version string stays in
lockstep across `plugin.json`, the skill frontmatter, and the README badge:

```bash
bash tests/run.sh
```

Every `cfg` config op (`default_tier`, `agents`, `enabled`, `tiers`, `model`, `effort`, `fallback`)
is **parity-gated**: the `jq` and `python3` backends must produce byte-identical output (the suite
checks `--list` and per-agent `--dry-run` across both, including malformed-config degradation). When
you add or change a config query type, update **both** backends in `scripts/run-agent.sh` and the
parity block in `tests/run.sh` together.

### Live smoke (opt-in)

`tests/run.sh` never launches a real CLI. To verify the driver actually round-trips against the
**real** agents, an opt-in harness lives in `tests/live-smoke.sh`. It is gated behind a single
arming switch — the `EXTERNAL_AGENTS_LIVE` environment variable (matching the existing
`EXTERNAL_AGENTS_*` convention) — so it is a no-op by default and is **never** part of the offline
CI gate:

```bash
bash tests/live-smoke.sh                 # unset/0 -> skips every live step, exits 0
EXTERNAL_AGENTS_LIVE=1 bash tests/live-smoke.sh   # 1 -> arms the harness against reachable CLIs
```

When armed, the harness scopes itself to the agents actually installed (via the driver's
`run-agent.sh --discover` surface): each **reachable** agent is queued for live checks, and each
**unreachable** one is skipped with a clear per-agent line. Absence of a CLI is never a failure — an
environment with no agents on `PATH` reports every agent skipped and still exits 0.

The **required CI gate is offline by design** (`shellcheck` + `tests/run.sh`) and never runs the live
harness — launching real CLIs costs money and ships the tree to third-party providers. Any live
verification must be a **separate, non-required, manual or scheduled** job, never a step added to the
required check job.

**To opt in:** install (and, for the agents that need it, sign in to) the CLIs you want to verify —
e.g. `cursor-agent login` — then run `EXTERNAL_AGENTS_LIVE=1 bash tests/live-smoke.sh`. Each line the
harness prints names exactly why a step ran or was skipped:

- `live smoke skipped (set EXTERNAL_AGENTS_LIVE=1)` — the harness is **not armed** (the default); no
  live work runs.
- `<agent> skipped (not reachable on PATH)` — the agent is armed-for but its CLI is not installed, so
  that agent is skipped (never a failure).
- `live smoke: reachable agents: …` — the agents that are installed and will be live-verified.

**Secret discipline:** the harness only ever **detects** auth (is the CLI present / does a cheap,
read-only probe succeed) — it never **captures, prints, or stores** tokens, API keys, or credentials.
No secret is read into a variable or written to any recorded evidence.

**Argv equivalence.** For each reachable agent the harness captures the **exact launch argv** the
driver builds for a real run (`run-agent.sh` records it to `$OUT/<agent>.argv` with the prompt masked
to `<PROMPT>`, so the record holds no prompt text or secret) and asserts it is **byte-identical** to
the `--dry-run` argv — across both modes (`--read-only`/`--write`) and both prompt sources
(`--prompt`/`--prompt-file`), covering every resolution path. This turns "the launch command is
correct" from an offline claim into a live-verified fact. Run it for one agent or all:

```bash
EXTERNAL_AGENTS_LIVE=1 bash tests/live-smoke.sh --agent codex   # one agent
EXTERNAL_AGENTS_LIVE=1 bash tests/live-smoke.sh                 # every reachable agent
```

**Non-mutation.** Each read-only run targets a disposable, git-backed sandbox (never the real
repo), and the harness snapshots it before/after. For the **enforced** agents
(`codex`/`claude`/`cursor`) any change to the tree is a **hard failure** — independent proof the
read-only guarantee held. For **agy**, whose read-only mode is **best-effort** (`--sandbox` is not a
hard write barrier), the harness only **reports** whether the tree changed, explicitly labelled
best-effort, and **never fails** on a change — agy is never over-claimed as enforced, matching the
[per-CLI enforcement matrix](docs/threat-model.md#per-cli-read-only-enforcement-matrix).

**Recorded evidence.** Each armed run composes one end-to-end read-only run per reachable agent
(argv-match + non-mutation + a successful transcript) and writes a deterministic per-agent status
record to `$EXTERNAL_AGENTS_OUT/live-smoke/status.txt` — one `<agent>  <status>` line (the full
**status vocabulary** is defined below) — so which agents are live-verified in the current
environment is auditable. The driver's per-agent
transcripts and masked argv records land under the same transcript dir (default
`~/.external-agents/logs/<project>`, overridable with `EXTERNAL_AGENTS_OUT`). To reproduce:

```bash
EXTERNAL_AGENTS_LIVE=1 bash tests/live-smoke.sh        # run, then inspect:
cat "${EXTERNAL_AGENTS_OUT:-$HOME/.external-agents/logs}"/live-smoke/status.txt
```

**Status vocabulary.** Each `<agent>  <status>` line carries exactly one token. What each asserts —
and, crucially, what it does **not**:

- `live-verified` — the agent round-tripped **at record time**: its launch argv matched `--dry-run`,
  the read-only run left the disposable sandbox unchanged (best-effort for `agy`), and it produced a
  successful (`rc=0`, non-empty) transcript. It does **not** assert the agent always works — a later
  auth, quota, or CLI change can break a previously verified agent, so re-run the harness to refresh.
- `failed` — the agent was reachable and checked, but a check failed (argv mismatch, an *enforced*
  agent mutated the tree, or a non-zero/empty transcript). A real, actionable failure.
- `reachable` — the CLI was found on `PATH` but no terminal verdict was assigned (an intermediate
  state, normally overwritten by `live-verified` / `failed` / `skipped-scoped-out`).
- `skipped-not-reachable` — armed for, but the CLI is not installed on `PATH`; skipped, never a failure.
- `skipped-scoped-out` — reachable, but excluded by an `--agent <name>` scope this run; not verified.
- `skipped-not-opted-in` — the harness was **not armed** (`EXTERNAL_AGENTS_LIVE` unset/`0`); no live
  work ran for any agent.
- `unknown` — no status was assigned for a known agent (a default guard); it should not appear in a
  normal armed run.

The honest boundary: a green offline `tests/run.sh` proves the plumbing; only a `live-verified` line
proves a *real* agent round-tripped — and only as of when that line was written, never "always works".

**Record stability (decision).** `status.txt` and `provenance.txt` are **best-effort, human-auditable
evidence — not a version-stable machine contract.** The `<agent>  <status>` line shape and the
provenance `key: value` lines are intended to stay stable, and the status vocabulary grows only
**additively** (a consumer should treat an unrecognized token leniently rather than fail), but the
record carries **no formal backward-compatibility guarantee** and is *not* version-gated. For machine
consumption prefer the driver's structured per-run records (`<agent>.meta.json` / `index.jsonl`); this
file exists to audit which agents were live-verified, not as a parsed API.

That transcript dir is **outside the repository** — raw transcripts (which can carry free-text or
PII) are **never committed**; only the offline, content-free tests live in the repo.

### End-to-end recipes (opt-in)

Beyond the smoke harness, reproducible per-agent **delegation recipes** live under `tests/e2e/` —
read-only review, read-write edit, and a non-git write — each driving a real agent against a
disposable git fixture and capturing uniform before/after evidence. They share the same
`EXTERNAL_AGENTS_LIVE` opt-in and skip-when-absent behavior, and are never part of the offline CI
gate. The read-only recipes assert the enforced agents (`codex`/`claude`/`cursor`) leave the fixture
unchanged, while **agy** read-only is captured as **best-effort** (observed, never asserted as
enforced). The shared contract and per-recipe steps are documented in
[docs/e2e-recipe.md](docs/e2e-recipe.md).

```bash
EXTERNAL_AGENTS_LIVE=1 bash tests/e2e/run-e2e.sh                 # all recipes, all reachable agents
EXTERNAL_AGENTS_LIVE=1 bash tests/e2e/review-readonly.sh codex   # one recipe, one agent
```

The read-write edit recipe confines all writes to the **throwaway fixture** (a non-cwd temp tree
outside the plugin tree, passed with `--yes`) and asserts the driver's post-write verification block
names the changed file — nothing in the real repo is ever touched.

A green offline `tests/run.sh` proves the recipe **plumbing** (fixtures, masked-argv capture, the
skip-when-unarmed path); only an armed run against an installed, authenticated CLI proves a given
agent actually round-trips. See [docs/e2e-recipe.md](docs/e2e-recipe.md#local-vs-live-readiness).

## Files

```
external-agents/
├── .claude-plugin/plugin.json      # plugin manifest
├── agents.json                     # enabled agents + per-tier model/effort map
├── commands/external-agents.md     # /external-agents slash command (thin)
├── skills/external-agents/SKILL.md # the natural-language brain
├── scripts/run-agent.sh            # the deterministic driver (all the logic)
├── scripts/bump-version.sh         # lockstep version bumper (plugin.json · SKILL.md · README badge · CHANGELOG)
├── tests/run.sh                    # offline test suite (run-agent + bump-version)
├── tests/live-smoke.sh             # opt-in live smoke harness (EXTERNAL_AGENTS_LIVE)
├── tests/e2e/                      # opt-in end-to-end delegation recipes:
│   ├── run-e2e.sh                  #   gated entry point (discovers agents, runs all recipes)
│   ├── review-readonly.sh          #   read-only review (enforced no-mutation; agy best-effort)
│   ├── edit-readwrite.sh           #   read-write edit on a git fixture (post-write verification)
│   ├── edit-non-git.sh             #   read-write on a non-git dir (no-baseline warning)
│   └── lib/                        #   fixture.sh + capture.sh (deterministic fixture + evidence)
├── docs/e2e-recipe.md              # the shared E2E recipe contract + per-recipe steps
├── RELEASING.md                    # release runbook (bump → tag → push)
└── .github/workflows/ci.yml        # CI: shellcheck + tests on push/PR
```

## Releasing

Cutting a release is a documented, repeatable procedure: run the lockstep
[`scripts/bump-version.sh`](scripts/bump-version.sh), then create and push the matching annotated
tag (the step the bumper deliberately leaves out). The full flow — clean tree, dry-run preview, real
bump, diff review, commit, `vX.Y.Z` tag, push — is in [RELEASING.md](RELEASING.md). The
`tag == v<version>` contract from that runbook is the single source: it is regression-pinned by the
offline tag-gate oracle in [`tests/run.sh`](tests/run.sh) (run `bash tests/run.sh`), which exercises
the match, mismatch, and no-tag cases against a throwaway repo, so the documented check cannot
silently drift.

## Contributing

Contributions are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) covers local setup, the CI-mirroring
validation loop (`shellcheck` + the `agents.json` schema check + `bash tests/run.sh`), the
interface/driver/adapter architecture and the safety invariants, the test expectations (extend the
offline suite; keep jq/python3 parity), and version/changelog discipline via
[`scripts/bump-version.sh`](scripts/bump-version.sh) (release flow in [RELEASING.md](RELEASING.md)).
