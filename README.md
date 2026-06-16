# external-agents

<div align="center">

[![Claude Code plugin](https://img.shields.io/badge/Claude%20Code-plugin-8A2BE2.svg)](https://docs.claude.com/en/docs/claude-code/overview)
[![Run external CLIs as sub-agents](https://img.shields.io/badge/dispatch-agy%20%C2%B7%20codex%20%C2%B7%20claude-0A7BBB.svg)](#what-it-drives)
[![version](https://img.shields.io/badge/version-0.3.0-informational.svg)](.claude-plugin/plugin.json)
[![License: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue.svg)](LICENSE)

</div>

A Claude Code plugin that runs **external coding-agent CLIs** — `agy` and `codex`
(and optionally `claude`) — as autonomous sub-agents from inside a Claude Code session.
Hand a task to one external agent or fan one prompt out to all of them in parallel, then
collect every response inline.

It is a *delegation* tool: an arbitrary task, your choice of agent, and **read-write by
default** so the agents can actually do work (use `--read-only` for analysis-only runs).

## What it drives

| agent  | cli         | read-write (default)                                            | read-only (`--read-only`)                       |
|--------|-------------|-----------------------------------------------------------------|-------------------------------------------------|
| agy    | `agy`       | `-p P --add-dir DIR --dangerously-skip-permissions [--model M]` | `-p P --sandbox --add-dir DIR [--model M]`      |
| codex  | `codex exec`| `-s workspace-write -C DIR --skip-git-repo-check [-m M] [-c model_reasoning_effort="E"] P` | `-s read-only -C DIR --skip-git-repo-check ... P` |
| claude | `claude`    | `-p P --permission-mode acceptEdits [--model M] [--effort E]`   | `-p P --allowedTools Read Grep Glob [--model M] [--effort E]` |

The prompt is always passed as a single argv element (or via stdin), never `eval`'d or
word-split, so it is injection-safe regardless of content.

Two CLI caveats worth knowing:

- **agy read-only is best-effort.** `agy --sandbox` restricts the terminal but does **not**
  hard-block agy's file-edit tools, so an agy read-only run *can* still mutate the tree.
  For an enforced read-only guarantee use `codex`/`claude` (their read-only modes are hard),
  or point `--target` at a throwaway copy. The script warns whenever agy runs read-only.
- **claude write + shell.** `--permission-mode acceptEdits` (the default) auto-accepts file
  edits but **denies** other Bash non-interactively — a "do X and run the tests" task will
  edit and then silently skip the tests at rc=0. For tasks that must build/test/run commands,
  pass `--claude-perm bypassPermissions`.

## Install

Load this directory into Claude Code as a local plugin (e.g. `/plugin` → add a local
directory pointing here), or symlink it into your plugins directory. Once loaded you get:

- the **`external-agents`** skill — triggers on natural language ("ask codex to …",
  "have the external agents review …", "delegate this to agy");
- the **`/external-agents`** slash command — explicit dispatch.

Requires `agy`, `codex`, and (for the `claude` agent) `claude` on `PATH`. Check with:

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

# preview the exact command without running it
bash scripts/run-agent.sh --agent agy --dry-run --prompt "..."
```

### Options

| flag | meaning |
|------|---------|
| `--agent A` | `agy` \| `codex` \| `claude` \| `all` (all enabled in `agents.conf`) |
| `--prompt P` / `--prompt-file F` / `--prompt-file -` | the task (literal, file, or stdin) |
| `--target DIR` | where the agents work (default: cwd) |
| `--write` / `--read-only` | read-write (default) vs analysis-only (mutually exclusive) |
| `--yes` / `-y` | confirm a write run whose `--target` is not the current directory |
| `--model M` / `--effort E` | per-run overrides (else `agents.conf`, else cli default) |
| `--claude-perm MODE` | claude write-mode permission mode (default `acceptEdits`; use `bypassPermissions` for shell) |
| `--timeout S` | per-agent timeout, seconds (default 1800) |
| `--out DIR` | transcript dir (default `~/.external-agents/logs/<project>`) |
| `--conf FILE` | agent defaults (default `agents.conf`) |
| `--list` / `--check` / `--dry-run` | inspect config / preflight CLIs / preview argv |

## Configuration — `agents.conf`

Per-agent default model and effort, one line each (`agent | model | effort`). Only the
agents listed here run under `--agent all`. Ships with `agy` + `codex` enabled and `claude`
commented out:

```
agy    | Gemini 3.1 Pro (High) |
codex  | gpt-5.5               | xhigh
# claude | claude-opus-4-8     | xhigh
```

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
- **External providers.** `agy` and `codex` send the target tree to external services — never
  point them at private IP or secrets.
- **Enforcement is uneven across CLIs** — see the two caveats above: agy read-only is
  best-effort; claude write needs `bypassPermissions` for shell.
- **Verification is produced, not just advised.** After a write run on a git target the
  script prints `git status` / `git diff --stat`; if the target isn't a git repo it warns
  that there is no baseline to diff or revert. Still review the diff before trusting the
  agent's self-report.

## Files

```
external-agents/
├── .claude-plugin/plugin.json     # plugin manifest
├── agents.conf                    # per-agent default model/effort
├── commands/external-agents.md    # /external-agents slash command (thin)
├── skills/external-agents/SKILL.md# the natural-language brain
└── scripts/run-agent.sh           # the deterministic driver (all the logic)
```
