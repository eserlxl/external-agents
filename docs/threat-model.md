# Threat Model

> Security-posture reference for external-agents. It enumerates the trust boundaries, the assets
> worth protecting, the threats against each, and the existing driver control that mitigates each
> (citing `scripts/run-agent.sh`). See also the README [Safety](../README.md#safety) section for
> the user-facing summary.

## Trust boundaries

A dispatch crosses four boundaries, each less trusted than the last:

1. **Caller → driver.** The Claude Code session (or a user shell) invokes
   `scripts/run-agent.sh` with an agent, mode, target, and prompt. The driver is the single
   control point; the interface layers (skill, slash command) only resolve intent.
2. **Driver → external CLI.** The driver launches a local agent CLI (`agy`, `codex`, `claude`,
   `cursor-agent`) as a child process with a constructed argv. The CLI is trusted to obey its own
   flags but is otherwise opaque.
3. **External CLI → external provider.** `agy`, `codex`, and `cursor` send the target tree and
   prompt to a third-party model provider over the network. Everything past this boundary leaves
   the machine.
4. **Provider → transcript.** The CLI's stdout/stderr return to the driver and are persisted and
   echoed. Provider output is untrusted text that may contain secrets.

## Protected assets

- **The target tree** — the files under `--target`; a write run can modify them.
- **The plugin tree** — `external-agents` itself and any repo that contains it.
- **Secrets in transcripts** — tokens/keys that appear in a tree or in agent output.
- **Scarce model quota** — agy's limited 3rd-party (Claude/Opus) Antigravity quota.
- **Prompt integrity** — the task text must reach the agent unchanged and un-evaluated.

## Threats and mitigating controls

| Asset | Threat | Mitigating control (in `scripts/run-agent.sh`) |
|-------|--------|------------------------------------------------|
| Plugin tree | A write run targets the plugin itself or a parent that contains it (e.g. a monorepo root exposing sibling repos) | Containment gate refuses a `--target` inside the plugin (`:467`) or containing it (`:468`), after resolving both paths physically with `pwd -P` (`:457-460`) so symlinks cannot slip past |
| Target tree | A wrong/misremembered non-cwd target is silently written | A write run whose `--target` is not the current directory is refused unless `--yes` is passed (`:470-476`) |
| Target tree | A read-only intent silently degrades into a write run | `--read-only` and `--write` are mutually exclusive and rejected in either order (`:140`, `:143`) |
| Target tree | A read-only run is mistaken for an enforced guarantee on agy | agy `--sandbox` is best-effort; the driver prints a NOTE that it may still permit writes and to use codex/claude/cursor for a hard guarantee (`:503`) |
| Target tree | A write run leaves no way to inspect/revert changes | After a write on a git target the driver prints `git status`/`git diff --stat` (`:638`); on a non-git target it warns there is no baseline (`:507`) |
| Prompt integrity | The prompt is word-split, globbed, or `eval`'d (injection) | The prompt is always passed as a single argv element (`:518`, `:541`, `:543`, `:556`) or via stdin, never `eval`'d; the dry-run printer masks it at `PROMPT_IDX` |
| Scarce model quota | Limited 3rd-party / Opus quota is spent without a check | agy tiers with a `fallback` consult `antigravity-usage --json` and use the primary only when quota is positively confirmed, else the larger-limit Gemini fallback (`:521-532`); `--check` reports whether the quota CLI is present (`:384-387`) |
| Secrets in transcripts | A secret-shaped token persists to disk or echoes to stdout | Best-effort, length-bounded redaction of transcript content before it is persisted/echoed (see below) |
| External provider | The target tree is shipped to a third party that should not see it | The caller chooses `--target`; the docs warn never to point external agents at private IP or secrets, and the containment gate keeps the plugin/parent out of scope |

## Per-CLI read-only enforcement matrix

`--read-only` is enforced unevenly across CLIs. This matrix is the published source of truth that
Phase 6.4's accuracy test asserts against the driver's resolved read-only argv:

| agent | read-only mechanism | enforcement | source of truth (`scripts/run-agent.sh`) |
|-------|---------------------|-------------|------------------------------------------|
| agy    | `--sandbox` | **best-effort** — restricts the terminal but does not hard-block edit tools, so a read-only run *can* still mutate the tree | `:519` (`--sandbox`); runtime NOTE at `:503` |
| codex  | `-s read-only` | **enforced** | `:537` |
| claude | `--allowedTools Read Grep Glob` | **enforced** | `:543` |
| cursor | `--mode plan` | **enforced** (Cursor's no-edit planning mode) | `:553` |

For a hard read-only guarantee, fan out to codex/claude/cursor only, or point `--target` at a
throwaway copy; the driver prints the best-effort NOTE (`:503`) whenever agy runs read-only.

## Secret handling and transcript redaction

Agent transcripts can echo secrets that appear in a target tree or in an agent's own output.
Before any transcript is persisted under the logs directory or echoed to stdout, the driver runs
it through a **best-effort, length-bounded** redaction stage (`redact` in `scripts/run-agent.sh`)
that masks secret-shaped tokens — `sk-`/`pk-`, `gh*_`/`github_pat_`, `xox*-`, `AKIA…`, `Bearer`
tokens, `KEY=`/`TOKEN=`/`SECRET=`/`PASSWORD=` assignments, and long high-entropy runs — as
`<REDACTED>`.

**Limits (documented honestly).** Redaction is *not* a guarantee of total secret removal:

- short or unusually-shaped secrets below the length thresholds can pass through;
- long non-secret strings (e.g. base64 blobs, 40-character hashes) can be over-masked;
- only the stdout transcript and the echoed stderr tail are redacted.

So transcripts must still be treated as sensitive. The matching user-facing note is the README
[Safety → Transcript redaction](../README.md#safety) bullet.

## Run records are content-free

The per-run `meta.json` record and the `index.jsonl` row are **control-plane facts only** — the agent,
resolved model/tier/effort/mode, target path, exit code, timing, size, fallback flag, timestamp, and
best-effort cost/usage signals — built from values the driver resolved at launch/collect, **never**
parsed from the transcript. They therefore carry no prompt, no agent free-text, and no secret. The
field-by-field contract and stability policy are in
[run-record-contract.md](run-record-contract.md); the offline suite asserts the records stay
secret-free.

## Error classification and retry safety

Run outcomes are classified into a closed set — `ok`, `safety-refusal`, `timeout`, `transient`,
`auth`, `contract`, `unknown` (see the README
[Error classification](../README.md#error-classification) table and the `run_one` comment in
`scripts/run-agent.sh`, which state the same set). The security-relevant invariant: a
**`safety-refusal`** — the containment gate, the non-cwd `--yes` confirmation, the
`--read-only`/`--write` exclusion, or `--timeout` validation — is **never retryable**. Those gates are
deliberate refusals, not transient conditions, so an automated retry must never re-attempt a run a
safety gate rejected; only `transient` (and, opt-in, `timeout`) outcomes are eligible for retry.
