# external-agents

<div align="center">

[![Claude Code plugin](https://img.shields.io/badge/Claude%20Code-plugin-8A2BE2.svg)](https://docs.claude.com/en/docs/claude-code/overview)
[![Run external CLIs as sub-agents](https://img.shields.io/badge/dispatch-agy%20%C2%B7%20codex%20%C2%B7%20claude%20%C2%B7%20cursor-0A7BBB.svg)](#what-it-drives)
[![version](https://img.shields.io/badge/version-0.5.0-informational.svg)](.claude-plugin/plugin.json)
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
**or** `python3` to read `agents.json`. Check with:

```bash
bash scripts/run-agent.sh --check
```

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
| `--out DIR` | transcript dir (default `~/.external-agents/logs/<project>`) |
| `--conf FILE` | agent config JSON (default `agents.json`) |
| `--list` / `--check` / `--dry-run` | inspect config / preflight reader + CLIs / preview argv |

## Configuration — `agents.json`

The caller picks **one effort level** — `low`, `medium`, `high`, or `xhigh` — and
`agents.json` maps that tier to the right **model + native effort for each agent**. So a
single `--effort high` resolves, per agent, to:

| `--effort` | agy (tier baked into model) | codex | claude | cursor (tier baked into model) |
|------------|-----------------------------|-------|--------|--------------------------------|
| `low`      | `Gemini 3.5 Flash (Low)`    | `gpt-5.5` effort `low`    | `claude-haiku-4-5`  | `composer-2.5` |
| `medium`   | `Gemini 3.5 Flash (Medium)` | `gpt-5.5` effort `medium` | `claude-sonnet-4-6` | `composer-2.5` |
| `high`     | `Gemini 3.5 Flash (High)`   | `gpt-5.5` effort `high`   | `claude-opus-4-8` effort `high`  | `composer-2.5` |
| `xhigh`    | `Gemini 3.1 Pro (High)`     | `gpt-5.5` effort `xhigh`  | `claude-opus-4-8` effort `xhigh` | `composer-2.5` |

`agy` and `cursor` bake the tier into the model name and ignore a separate effort;
`codex`/`claude` take model and effort separately. Cursor's Composer 2.5 self-calibrates its
own effort, so its tiers ship identical — point a tier at a different model (`cursor-agent
models` lists them once you are signed in) if you want per-tier differentiation. With no
`--effort`, the config's `default_tier` is used (ships as `xhigh`). A per-run `--model M`
overrides only the resolved model — the native effort still comes from the tier.

`enabled: true` agents run under `--agent all`; a named `--agent agy|codex|claude|cursor` runs
even if disabled. Ships with `agy` + `codex` + `cursor` enabled and `claude` disabled:

```json
{
  "default_tier": "xhigh",
  "agents": {
    "agy": {
      "enabled": true,
      "tiers": {
        "low":   { "model": "Gemini 3.5 Flash (Low)" },
        "xhigh": { "model": "Gemini 3.1 Pro (High)" }
      }
    },
    "codex":  { "enabled": true,  "tiers": { "high": { "model": "gpt-5.5", "effort": "high" } } },
    "claude": { "enabled": false, "tiers": { "low":  { "model": "claude-haiku-4-5" } } },
    "cursor": { "enabled": true,  "tiers": { "xhigh": { "model": "composer-2.5" } } }
  }
}
```

Run `bash scripts/run-agent.sh --list` to print the full resolved table, enabled status,
and `default_tier`. Reading the JSON needs `jq` (preferred) or `python3` on `PATH`.

## Safety

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
- **Enforcement is uneven across CLIs** — see the caveats above: agy read-only is
  best-effort; claude write needs `bypassPermissions` for shell; cursor needs prior auth
  (`cursor-agent login`) and its read-only mode (`--mode plan`) is enforced.
- **Verification is produced, not just advised.** After a write run on a git target the
  script prints `git status` / `git diff --stat`; if the target isn't a git repo it warns
  that there is no baseline to diff or revert. Still review the diff before trusting the
  agent's self-report.

## Files

```
external-agents/
├── .claude-plugin/plugin.json     # plugin manifest
├── agents.json                    # enabled agents + per-tier model/effort map
├── commands/external-agents.md    # /external-agents slash command (thin)
├── skills/external-agents/SKILL.md# the natural-language brain
└── scripts/run-agent.sh           # the deterministic driver (all the logic)
```
