---
name: external-agents
description: >
  Delegate a task to external coding agents — the CLIs agy, codex, and cursor (and optionally
  claude), plus read-only cloud API advisors (claude-api, openai, gemini, openrouter) — running them
  as autonomous sub-agents, then collect each agent's response. Trigger when the user wants to "ask
  codex / agy / cursor / gemini / openai to ...", "have codex / agy / cursor <do X>", "delegate this
  to codex / agy / cursor", "run the external agent(s)", "fan this out to agy and codex", "use cursor
  / composer", "ask the API models / claude-api / openrouter to analyze ...", "get a second agent
  to ...", or "have the external agents review / analyze / implement / fix ...". The CLIs are
  read-write by default (they may edit files); the cloud API advisors are always read-only (analysis
  only). Switch to read-only when the user only wants analysis. Drives each agent via
  scripts/run-agent.sh; never reimplement the driving logic here.
license: GPL-3.0-or-later
metadata:
  plugin: external-agents
  version: "0.10.1"
---

# external-agents

Hand a task to an **external coding agent** running as its own process, then bring its
result back. The agents are real CLIs already on the machine:

- **agy** — multi-model agent (Gemini / Claude / GPT-OSS tiers; tier baked into the model name).
  Its `high`/`xhigh` tiers are **quota-aware**: a limited 3rd-party primary (Claude Sonnet/Opus)
  runs only when `antigravity-usage` confirms remaining quota — else it falls back to a
  larger-limit Gemini model. Needs the Antigravity IDE open (or `antigravity-usage login`);
  tell the user this if they want agy's Opus/Sonnet tiers and the run keeps falling back to Gemini.
  The fallback decision is **read-only** (never the quota-spending `wakeup`) and is verified against
  the real CLI by the opt-in live harness (`tests/live-smoke.sh`): primary iff available, else the
  Gemini fallback, degrading to the fallback whenever the quota is unconfirmable.
- **codex** — OpenAI Codex CLI (`codex exec`)
- **cursor** — Cursor's headless agent CLI (`cursor-agent`), running Cursor's own models (Composer 2.5)
- **claude** — a nested Claude Code session (available, not in the default `all` set)

Read-only **cloud API advisors** — direct provider endpoints with **no filesystem access** (they
analyze only the prompt you give them; used for repository-analysis panels). Disabled in `agents.json`
by default:

- **claude-api** — Anthropic Messages API · **openai** — OpenAI Chat Completions · **gemini** — Google
  `generateContent` · **openrouter** — OpenAI-compatible gateway to any model.

They are **always read-only** (a stateless API call can't touch the tree); an API-only run defaults to
`--read-only`. Keys resolve via Unix `pass` from each provider's env var
(`ANTHROPIC_API_KEY`/`OPENAI_API_KEY`/`GEMINI_API_KEY`→`GOOGLE_API_KEY`/`OPENROUTER_API_KEY`) — see the
README "Cloud API advisors" section.

You do **not** drive the CLIs by hand. A single deterministic script,
`scripts/run-agent.sh`, owns every flag, sandbox mode, parallel fan-out, timeout, and
transcript. Your job is to (1) read the user's intent, (2) resolve four things —
**agent, mode, target, prompt** — and (3) invoke the script.

## 1. Resolve the agent

- Names an agent ("ask **codex**", "have **agy**", "use **claude**", "use **cursor**" /
  "use **composer**", "ask **claude-api** / **openai** / **gemini** / **openrouter**") → that agent.
- "the external agents", "both", "all of them", "fan out", or names two+ agents →
  `all` (every agent enabled in `agents.json`, run in parallel).
- Unspecified → `all` if the user clearly wants breadth/a panel; otherwise ask which one,
  or default to `codex` for a single focused task.

## 2. Resolve the mode  (default: **read-write**)

- **read-write** (default): the user wants work done — "implement", "fix", "refactor",
  "add", "rename", "apply", "make the change". The agents may edit files and run tools.
- **read-only** (`--read-only`): the user only wants thinking — "review", "analyze",
  "audit", "explain", "evaluate", "what would you do", "don't change anything". Pass
  `--read-only` so the agents observe and report instead of editing the tree.

When in doubt between the two, prefer **read-only** and say so — it is the safe direction.

Three CLI-specific caveats to pass on to the user:

- **agy read-only is best-effort, not enforced.** `agy --sandbox` restricts the terminal
  but does not hard-block agy's file-edit tools, so a read-only fan-out that includes agy
  *could* still mutate the tree. For a hard guarantee, fan out to `codex`/`claude`/`cursor`
  only (their read-only modes are enforced), or point `--target` at a throwaway copy. The
  script prints a NOTE whenever agy runs read-only.
- **claude write tasks that must run shell commands** (build/test/git) need
  `--claude-perm bypassPermissions` — the default `acceptEdits` auto-accepts file edits
  but silently denies other Bash, so "implement X and run the tests" would edit but skip
  the tests and still exit 0. Add `--claude-perm bypassPermissions` for those tasks.
- **cursor needs prior auth, and its binary is `cursor-agent`.** The `cursor` agent calls
  `cursor-agent` (Cursor's headless CLI), not `cursor` (the IDE), and must be signed in
  first — `cursor-agent login` or a `CURSOR_API_KEY` — or the run fails. Its read-only mode
  (`--mode plan`) is enforced (analyze/plan, no edits), so it is a hard guarantee like
  codex/claude; it runs Cursor's own models (Composer 2.5).

The canonical per-CLI read-only enforcement matrix (agy best-effort vs codex/claude/cursor
enforced) lives in `docs/threat-model.md`. It is asserted against the driver's resolved argv by
the offline test suite, and **observed end-to-end** by the opt-in live harness
(`tests/live-smoke.sh`): an enforced read-only run must leave the sandbox byte-identical (a change
is a hard failure), while agy mutation is reported best-effort, never asserted. Keep these caveats
in sync with it.

## 3. Resolve the target  (default: current directory)

- Default `--target "$PWD"`.
- If the user names a subdirectory or repo ("in `src/auth`", "the planwright repo"),
  pass that as `--target`.
- **Safety gate (read-write only):** the agents can modify anything under `--target`, and
  agy/codex/cursor ship the tree to external providers. The script enforces this: a write run
  whose `--target` is **not the current working directory** is refused unless you pass
  `--yes`. So before a non-cwd write, **confirm scope with the user** (show them the
  resolved target and that agy/codex/cursor are external), and only then add `--yes`. Never
  target a tree holding private IP. The script also refuses to write inside its own
  plugin directory, or in any directory that *contains* the plugin (e.g. a monorepo root).

## 4. Compose the prompt and invoke

Write a clear, self-contained instruction for the sub-agent (it does not share your
context). Pass it on **stdin** via `--prompt-file -` so multi-line prompts need no quoting:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-agent.sh" \
  --agent codex --target "$PWD" --prompt-file - <<'PROMPT'
<the full task for the external agent>
PROMPT
```

- Read-only review fanned out to every agent:
  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-agent.sh" \
    --agent all --read-only --target "$PWD" --prompt-file - <<'PROMPT'
  Review the changes on the current branch for correctness and security. Cite file:line.
  PROMPT
  ```
- Single write task at a chosen effort tier:
  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/run-agent.sh" \
    --agent agy --effort high --target "$PWD" --prompt-file - <<'PROMPT'
  Implement <X>. Run the tests when done.
  PROMPT
  ```

**Effort tier (`--effort`).** The caller picks ONE level — `low | medium | high | xhigh` —
and `agents.json` maps it, per agent, to the right model + native effort (e.g. `--effort high`
→ agy `Claude Sonnet 4.6 (Thinking)` (quota-checked, else Gemini), codex `gpt-5.5` effort
`high`, claude `claude-opus-4-8` effort `high`, cursor `gpt-5.5-high`). Choose the tier from
the user's intent: quick/cheap scan → `low`/`medium`;
hard reasoning, security, or architecture → `high`/`xhigh`. Omit `--effort` to use the
config's `default_tier` (`medium`). A `--model M` still overrides the resolved model directly.

Other flags: `--model M`, `--claude-perm MODE` (use `bypassPermissions` for claude write
tasks needing shell), `--yes` (confirm a non-cwd write target), `--timeout S`, `--out DIR`
(the transcript base dir also honors the `EXTERNAL_AGENTS_OUT` env var).
Run `run-agent.sh --check` to verify the JSON reader + CLIs are installed, `--list` to see
the resolved tier table, and `--dry-run` to preview the exact argv before a real run.

## 5. Report back

The script echoes each agent's full transcript to stdout under a
`===== <agent> (rc=.. ..s ..bytes) =====` header, and also saves it under
`~/.external-agents/logs/<project>/<agent>.md`. Transcript content is run through a
**best-effort, length-bounded secret-redaction** stage before it is persisted or echoed (masking
`sk-`/`gh*_`/`Bearer`/`KEY=`-style tokens as `<REDACTED>`); this is not a guarantee, so do not rely
on it to scrub a transcript you would otherwise keep private.

- Summarise what each agent concluded or did; on `all`, note where they agree and disagree.
- **After a read-write run, verify before trusting it:** run `git status` / `git diff` to
  see what actually changed, build/test if applicable, and surface the diff to the user.
  The sub-agent's self-report is a claim, not proof.
- If an agent failed (non-zero rc / empty output), report its stderr tail and offer to
  retry (e.g. a longer `--timeout`, a different agent, or `--read-only`).
