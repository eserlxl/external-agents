# Releasing external-agents

This runbook takes a maintainer from a clean working tree to a **pushed, tagged,
changelog-complete release**. It is anchored on
[`scripts/bump-version.sh`](scripts/bump-version.sh), which bumps the version **in lockstep** across
the four surfaces this repo ships — the plugin manifest (`.claude-plugin/plugin.json`), each skill's
frontmatter (`skills/*/SKILL.md`), the README version badge, and `CHANGELOG.md` — but deliberately
**does not** create a git tag or GitHub release. This runbook covers those final steps the bumper
leaves out.

## When to cut a release

Tag at meaningful milestones, not on every commit: roughly **every 25–50 commits**, or whenever a
meaningful feature ships (a new flag, a new agent, a major behaviour change). Run `bump-version.sh`
freely during development; tag and push only at the milestone.

## Steps

1. **Confirm a clean tree and green CI.** The bumper refuses a dirty tree (unless `ALLOW_DIRTY=1`),
   so commit or stash first, then run the offline gate locally — it must be green:

   ```bash
   git status --porcelain        # expect no output
   shellcheck scripts/run-agent.sh scripts/bump-version.sh
   bash tests/run.sh
   ```

2. **Preview the bump (`--dry-run`).** The bump level is the **first positional**; append
   `--dry-run` to preview without writing anything. Confirm the computed version and the changelog
   block before touching any file:

   ```bash
   bash scripts/bump-version.sh <major|minor|patch|X.Y.Z> --dry-run -m "one-line changelog note"
   ```

   The preview prints the current→new version, the CHANGELOG block it would prepend, and which
   lockstep surfaces it would sync. For example, `minor --dry-run -m example` on `0.6.0` prints:

   ```text
   dry-run: 0.6.0 -> 0.7.0 (files not modified)

   Would add to CHANGELOG.md:
   ## [0.7.0] - <today, UTC>

   ### Changed
   - example
     would sync skills/external-agents/SKILL.md
     would update README badge (README.md)
   ```

   Re-run until the version and note read correctly; nothing is written until you drop `--dry-run`.
   (The level is the first positional — `<level> --dry-run`, **not** `--dry-run <level>`.)

3. **Run the real bump.** Drop `--dry-run` to write the lockstep edits and prepend the CHANGELOG
   entry:

   ```bash
   bash scripts/bump-version.sh <major|minor|patch|X.Y.Z> -m "one-line changelog note"
   ```

4. **Review the diff.** The bump should touch only the version surfaces and the CHANGELOG:

   ```bash
   git --no-pager diff
   ```

5. **Commit the release.** Use a clear release subject:

   ```bash
   git add -A
   git commit -m "Release vX.Y.Z"
   ```

6. **Create the annotated tag.** The tag name **must** be `vX.Y.Z` matching the version the bumper
   wrote (the lockstep set above):

   ```bash
   git tag -a vX.Y.Z -m "external-agents vX.Y.Z"
   ```

7. **Push the commit and the tag.**

   ```bash
   git push origin HEAD
   git push origin vX.Y.Z
   ```

After pushing, CI runs the offline gate (`shellcheck` + `tests/run.sh`) on the release commit; create
a GitHub release from the pushed tag if you publish one.
