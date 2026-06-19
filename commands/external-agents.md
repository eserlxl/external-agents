---
description: Delegate a task to external coding-agent CLIs (agy / codex / claude) as autonomous sub-agents and collect their responses. Optional leading agent selector; read-write by default, `read-only` for analysis-only.
argument-hint: "[agy|codex|claude|all] [read-only] [low|medium|high|xhigh] <task for the external agent(s)>"
---

You are dispatching the **external-agents** skill on behalf of the `/external-agents`
helper command. Do **not** reimplement any driving logic here — resolve the arguments
below, then invoke the skill (Skill tool `external-agents:external-agents` on Claude Code;
otherwise load `skills/external-agents/SKILL.md`) and let it do everything: agent
selection, mode, target, prompt hand-off via `scripts/run-agent.sh`, and reporting back.

Raw arguments: `$ARGUMENTS`

Resolve them, then hand off to the skill:

1. **Agent.** If the first token is `agy`, `codex`, `claude`, or `all`, that is the agent;
   strip it. Otherwise leave the agent unspecified (the skill decides — `all` for a panel,
   else a single agent).
2. **Mode.** If the next token is `read-only` (or `--read-only` / `readonly`), strip it and
   run the skill in read-only mode. Otherwise the default is read-write (the agents may
   edit files).
3. **Effort.** If the next token is `low`, `medium`, `high`, or `xhigh`, strip it and pass it
   as the effort tier (`--effort`); each agent maps it to its own model + native effort.
   Otherwise leave it unset (the skill uses `agents.json`'s `default_tier`).
4. **Target.** Default the current directory unless the remaining text names a path.
5. **Prompt.** Everything left is the task to hand to the external agent(s).

If `$ARGUMENTS` is empty, ask the user what they want the external agent(s) to do (and,
if not obvious, which agent and whether it should be read-only).
