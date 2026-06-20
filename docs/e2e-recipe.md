<!-- SPDX-FileCopyrightText: 2026 Eser KUBALI -->
<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# End-to-end delegation recipes

This document is the **shared contract** every per-agent end-to-end (E2E) recipe under
`tests/e2e/` conforms to. An E2E recipe drives one real external agent through `run-agent.sh`
against a **disposable throwaway fixture** and captures uniform before/after evidence, so a
maintainer can reproduce a delegation and inspect exactly what happened — without ever touching a
real repository or shipping private code.

Like the [live smoke harness](../README.md#live-smoke-opt-in), the E2E recipes are **opt-in** and
**never part of the offline CI gate** (which stays `shellcheck` + `tests/run.sh`). They launch real
CLIs (cost + ship the tree to third-party providers), so they run only when explicitly armed.

## The shared contract

Every recipe MUST:

1. **Gate on the single opt-in switch.** Reuse Phase 2's gating shape: the
   `EXTERNAL_AGENTS_LIVE` environment variable (unset/`0` skips every live step and exits 0;
   `1` arms the recipe). A recipe also skips, cleanly and non-fatally, any agent whose CLI is not
   on `PATH` (per-agent `command -v`). Absence of a CLI or the opt-in is **never a failure**.

2. **Target a deterministic, disposable git fixture** — never the real repo. The fixture is a
   freshly git-initialized temp tree (created under `$TMPDIR`, guaranteed outside the plugin tree)
   with a **known seed file** and exactly **one initial commit**, so before/after diffs are
   deterministic. The helper that builds it lives in `tests/e2e/lib/fixture.sh`.

3. **Capture the standard before/after evidence** into a throwaway evidence directory (under
   `EXTERNAL_AGENTS_OUT`). The helper lives in `tests/e2e/lib/capture.sh`. The evidence fields are
   exactly the driver's own outputs (see below) plus the fixture's pre-run git state.

## Evidence fields (match the driver's actual outputs)

The driver emits these per run; an E2E recipe records the same fields verbatim, so the recorded
evidence never drifts from what `run-agent.sh` actually produces:

| field | source in `scripts/run-agent.sh` | meaning |
|-------|----------------------------------|---------|
| resolved argv | `--dry-run` printer / the `$OUT/<agent>.argv` record | the exact launch argv, with the prompt masked to `<PROMPT>` (secret-free) |
| `rc` | collect loop (`$OUT/<agent>.rc`) | the agent process exit code (`PIPESTATUS[0]`) |
| `sec` | collect loop (`$OUT/<agent>.sec`) | wall-clock seconds the run took |
| `bytes` | collect loop (`wc -c <$OUT/<agent>.md`) | size of the redacted transcript |
| transcript | `$OUT/<agent>.md` (redacted) | the agent's response, after best-effort secret redaction |
| `===== <agent> (rc=… …s … bytes) =====` | collect loop header | the per-agent banner |
| `===== git changes after write (in <target>) =====` | post-write block | present only on a **write** run against a **git** target |
| `git status --porcelain` / `git diff --stat` | post-write block | what actually changed in the target tree after a write |

The pre-run evidence a recipe adds: the fixture path, its initial commit sha, and `git status
--porcelain` (clean) before the run — so the after-state is comparable against a known baseline.

### Read-only enforcement in the recipes

A read-only recipe checks the fixture's post-run `git status --porcelain`. For the **enforced**
agents (`codex`/`claude`/`cursor`) an empty status is asserted — any change is a **hard failure**.
For **agy**, whose read-only mode is **best-effort** (`agy --sandbox` is not a hard write barrier),
the recipe instead **captures the driver's best-effort warning** and records the **observed**
mutation status as evidence **without asserting a hard guarantee** — a change does not fail the
recipe. agy read-only is therefore **never** claimed as enforced anywhere in the recipes; for a hard
guarantee use codex/claude/cursor or point the run at a throwaway copy (which is exactly what these
recipes do).

## Recipes

Each recipe is a self-contained script under `tests/e2e/`, run via the `tests/e2e/run-e2e.sh`
entry point. The per-recipe sections are documented below.

### Read-only review (`review-readonly.sh`)

Drives each reachable agent through `run-agent.sh --read-only` with a fixed review prompt against a
fresh fixture, then checks the run succeeded and (for enforced agents) left the tree byte-identical.

- **Prompt:** `Review seed.txt and reply with one short observation. Do not edit anything.`
  (override with `E2E_REVIEW_PROMPT`).
- **Driver argv:** the recipe uses `run-agent.sh --read-only`, so each agent resolves to its enforced
  read-only argv — e.g. `codex exec -s read-only -C <fixture> --skip-git-repo-check <PROMPT>`,
  `claude -p <PROMPT> --allowedTools Read Grep Glob`, `cursor-agent -p --mode plan --trust --workspace
  <fixture> -- <PROMPT>`, `agy -p <PROMPT> --sandbox --add-dir <fixture>`.
- **Expected transcript:** a non-empty, redacted response with `rc=0` (`bytes>0`). Per-run evidence
  lands under `$EXTERNAL_AGENTS_OUT/e2e/review-readonly/<agent>/`: `argv`, `pre.sha`, `pre.status`,
  `post.status`, `post.diffstat`, `run.txt` (rc/sec/bytes/transcript path), and `driver.err`.
- **No-mutation:** enforced agents (`codex`/`claude`/`cursor`) — `post.status` MUST be empty; any
  change is a **hard failure**. agy — **best-effort**: the change is observed and the driver's
  best-effort warning captured, never asserted (see *Read-only enforcement in the recipes*).
- **Opt-in/skip:** unset `EXTERNAL_AGENTS_LIVE` → the recipe prints a skip line and exits 0; an
  unreachable agent is skipped cleanly.

```bash
EXTERNAL_AGENTS_LIVE=1 bash tests/e2e/review-readonly.sh codex   # one agent
EXTERNAL_AGENTS_LIVE=1 bash tests/e2e/run-e2e.sh                 # all reachable agents, all recipes
```

### Read-write edit (`edit-readwrite.sh`)

Drives each reachable agent through `run-agent.sh` in **read-write** mode with a deterministic
tiny-edit prompt, proves a real write round-trips, and checks the driver's post-write verification.

- **Prompt:** append one new line whose exact content is `reviewed-ok` (the `E2E_FIXTURE_MARKER`) to
  `seed.txt` — a reversible, predictable edit (override with `E2E_EDIT_PROMPT`).
- **Driver argv:** the recipe uses `run-agent.sh --write --yes`, so each agent resolves to its
  read-write argv — e.g. `codex exec -s workspace-write -C <fixture> --skip-git-repo-check <PROMPT>`,
  `claude -p <PROMPT> --permission-mode acceptEdits`, `cursor-agent -p --force --trust --workspace
  <fixture> -- <PROMPT>`, `agy -p <PROMPT> --add-dir <fixture> --dangerously-skip-permissions`.
- **Expected changed file:** the fixture's post-run `git status --porcelain` is non-empty (the agent
  made an edit), e.g. ` M seed.txt`.
- **Expected post-write verification:** the driver PRODUCES, on stdout, the
  `===== git changes after write (in <fixture>) =====` block with `git status --porcelain` and
  `git diff --stat` naming the changed file (e.g. `seed.txt | 1 +`). The recipe asserts the block is
  present and names the actual change.
- **Fixture handling:** one fixture, reset to its initial commit (`e2e_fixture_reset`) before each
  agent — so every run starts identically and the diff stays predictable.
- **Safety gates:** writes are confined to the **throwaway fixture** (a non-cwd temp tree, passed
  with `--yes`); the driver refuses to write inside or above the plugin tree, and the fixture is
  always created under `$TMPDIR`, outside the plugin tree. Nothing in the real repo is ever touched.
- **Opt-in/skip:** unset `EXTERNAL_AGENTS_LIVE` → the recipe prints a skip line and exits 0.

```bash
EXTERNAL_AGENTS_LIVE=1 bash tests/e2e/edit-readwrite.sh codex    # one agent
```

### Non-git write (`edit-non-git.sh`)

Drives each reachable agent through `run-agent.sh --write` against a deliberately **non-git**
throwaway directory, to exercise the driver's no-baseline path.

- **Prompt:** append the marker line to `notes.txt` (override with `E2E_NONGIT_PROMPT`).
- **Driver argv:** the same read-write argv as the edit recipe — the target just isn't a git repo.
- **No-baseline warning:** the driver WARNS `--target is not a git repo; no baseline to diff or
  revert after writes` on stderr — the recipe asserts it is captured in `driver.err`.
- **Suppressed verification:** with no git baseline the driver SUPPRESSES the
  `===== git changes after write =====` block — the recipe asserts it is absent from stdout.
- **Opt-in/skip:** unset `EXTERNAL_AGENTS_LIVE` → skip + exit 0.

```bash
EXTERNAL_AGENTS_LIVE=1 bash tests/e2e/edit-non-git.sh codex
```

## Per-agent reproducibility checklist

To reproduce the full Phase 3 evidence for one agent `<a>`:

1. Install and authenticate the agent's CLI; confirm with `run-agent.sh --check` (or `--discover`).
2. Run all recipes via the entry point, or one recipe directly:
   ```bash
   EXTERNAL_AGENTS_LIVE=1 bash tests/e2e/run-e2e.sh
   ```
3. Inspect the per-recipe evidence under `$EXTERNAL_AGENTS_OUT/e2e/<recipe>/<a>/` — each carries
   `argv` (masked launch argv), `run.txt` (rc/sec/bytes/transcript path), and `driver.err`. The
   expected per-recipe outcome:

   | recipe | expected evidence |
   |--------|-------------------|
   | `review-readonly` | `rc=0`, non-empty transcript; `post.status` **empty** for enforced agents (agy best-effort observed) |
   | `edit-readwrite`  | `rc=0`, a changed file (`post.status` non-empty) and the `===== git changes after write =====` block in `driver.out` naming it |
   | `edit-non-git`    | `rc=0`, the no-baseline warning in `driver.err`, and **no** post-write block in `driver.out` |

4. Net expectation: enforced agents leave the read-only fixture byte-identical; the write recipes
   produce a changed file (git target) and the documented warning + suppressed block (non-git target).
