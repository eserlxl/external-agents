#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Bump the external-agents plugin version in lockstep across the four version
# surfaces this repo ships: the plugin manifest (.claude-plugin/plugin.json),
# each skill's frontmatter (skills/*/SKILL.md), the README version badge, and
# the CHANGELOG.md entry. (This repo ships ONE manifest — there is no second
# host manifest — so the bumper touches only .claude-plugin/plugin.json.)
#
# This script updates version numbers and the changelog — it does NOT create a
# git tag or GitHub release. The full release procedure — clean tree, dry-run
# preview, real bump, commit, the annotated vX.Y.Z tag, push, and the
# tag-equals-version check, plus the cadence heuristic — is the canonical runbook
# in RELEASING.md; follow it when cutting a release. Run bump-version.sh freely
# during development.
#
# Usage:
#   scripts/bump-version.sh <major|minor|patch|X.Y.Z> [-m "changelog note"]
#
# Examples:
#   scripts/bump-version.sh patch
#   scripts/bump-version.sh minor -m "Add --read-only"
#   scripts/bump-version.sh 2.0.0 -m "Rewrite the dispatcher"
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_JSON="$ROOT/.claude-plugin/plugin.json"
CHANGELOG="$ROOT/CHANGELOG.md"
README="$ROOT/README.md"

# Portable repo-relative path. GNU realpath's relative mode is unavailable on
# stock macOS without Homebrew; python3 is already required by this script.
relpath() { python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "$1" "$ROOT"; }

usage() {
  echo "Usage: $(basename "$0") <major|minor|patch|X.Y.Z> [-m \"changelog note\"] [--dry-run]" >&2
  exit 1
}

[ $# -ge 1 ] || usage
[ "$1" = "-h" ] || [ "$1" = "--help" ] && { echo "Usage: $(basename "$0") <major|minor|patch|X.Y.Z> [-m \"changelog note\"] [--dry-run]"; exit 0; }
BUMP="$1"; shift
NOTE=""
DRY_RUN=""
while [ $# -gt 0 ]; do
  case "$1" in
    -m|--message)
      [ $# -ge 2 ] || { echo "Option $1 requires a value" >&2; usage; }
      NOTE="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help) echo "Usage: $(basename "$0") <major|minor|patch|X.Y.Z> [-m \"changelog note\"] [--dry-run]"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

for f in "$PLUGIN_JSON" "$CHANGELOG"; do
  [ -f "$f" ] || { echo "Missing required file: $f" >&2; exit 1; }
done

# All-or-nothing preflight: the JSON manifest is rewritten BEFORE the strict-UTF-8
# reads of SKILL.md/CHANGELOG.md below, so one bad byte there used to abort mid-run
# with the manifest already bumped — exactly the version drift the lockstep contract
# forbids. Decode-check every text file we will read before any write; a failure
# aborts with the tree untouched.
python3 - "$ROOT" "$CHANGELOG" "$README" <<'PY' || exit 1
import glob, os, sys
root, changelog, readme = sys.argv[1], sys.argv[2], sys.argv[3]
targets = [changelog]
if os.path.isfile(readme):
    targets.append(readme)
targets += sorted(glob.glob(os.path.join(root, "skills", "*", "SKILL.md")))
for path in targets:
    try:
        with open(path, encoding="utf-8") as fh:
            fh.read()
    except UnicodeDecodeError:
        rel = os.path.relpath(path, root)
        sys.stderr.write(f"bump-version: {rel} is not valid UTF-8; aborting before any edits\n")
        sys.exit(1)
PY

# Refuse to mutate a dirty tree so the bump's edits stay isolated and revertible.
# Skipped when not inside a git work tree (e.g. the test harness) or ALLOW_DIRTY=1.
if [ "${ALLOW_DIRTY:-0}" != "1" ] && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
    echo "Working tree not clean; commit or stash first, or set ALLOW_DIRTY=1." >&2
    exit 1
  fi
fi

CURRENT="$(python3 - "$PLUGIN_JSON" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["version"])
PY
)"

NEW="$(python3 - "$CURRENT" "$BUMP" <<'PY'
import re, sys
cur, bump = sys.argv[1], sys.argv[2]
# Accept an explicit target version: strict X.Y.Z, optionally with a SemVer
# pre-release (-rc1) and/or build (+meta) suffix, so a pre-release can be cut.
if re.fullmatch(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?", bump):
    print(bump); raise SystemExit
# A relative bump operates on the release core: strip any SemVer pre-release
# (-rc.1) / build (+meta) suffix from the current version first, so a bump from
# a pinned pre-release (e.g. 2.6.0-rc.1+build.5) increments cleanly instead of
# crashing on cur.split(".").
core = re.match(r"(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$", cur)
if not core:
    sys.stderr.write(f"Current version '{cur}' is not X.Y.Z\n"); raise SystemExit(1)
major, minor, patch = (int(g) for g in core.groups())
if bump == "major":   major, minor, patch = major + 1, 0, 0
elif bump == "minor": minor, patch = minor + 1, 0
elif bump == "patch": patch += 1
else:
    sys.stderr.write("bump must be one of: major | minor | patch | X.Y.Z\n"); raise SystemExit(1)
print(f"{major}.{minor}.{patch}")
PY
)"

DATE="$(date -u +%Y-%m-%d)"

# --- Transactional guard ---------------------------------------------------
# The JSON manifest, skill frontmatter, and CHANGELOG are rewritten as separate
# steps below; an interruption or a failed step between them would otherwise leave
# version drift across files (the lockstep contract forbids this). Back up every
# target up front and restore them ALL if any step fails or the run is interrupted,
# so a partial bump is impossible — the bump is all-or-nothing. (Skipped on
# --dry-run, which writes nothing.)
if [ -z "$DRY_RUN" ]; then
  _bump_targets=("$PLUGIN_JSON" "$CHANGELOG")
  [ -f "$README" ] && _bump_targets+=("$README")
  for _skill in "$ROOT"/skills/*/SKILL.md; do
    [ -f "$_skill" ] && _bump_targets+=("$_skill")
  done
  BUMP_BACKUP="$(mktemp -d)"
  for _i in "${!_bump_targets[@]}"; do
    cp -p "${_bump_targets[$_i]}" "$BUMP_BACKUP/$_i"
  done
  _bump_restore() {
    local _i
    local -a _failed=()
    for _i in "${!_bump_targets[@]}"; do
      if [ -f "$BUMP_BACKUP/$_i" ] && cp -p "$BUMP_BACKUP/$_i" "${_bump_targets[$_i]}" 2>/dev/null; then
        continue
      fi
      _failed+=("${_bump_targets[$_i]}")
    done
    if [ "${#_failed[@]}" -eq 0 ]; then
      echo "bump-version: a step failed or was interrupted; restored all files to their pre-bump state." >&2
    else
      echo "bump-version: a step failed or was interrupted; restore INCOMPLETE — could not restore: ${_failed[*]}. Recover manually from $BUMP_BACKUP before re-running." >&2
    fi
  }
  trap '_bump_restore' ERR INT TERM
fi

# --- Update JSON manifests -------------------------------------------------
if [ -z "$DRY_RUN" ]; then
python3 - "$PLUGIN_JSON" "$NEW" <<'PY'
import json, os, sys, tempfile
plugin_path, new = sys.argv[1:3]

def atomic_write(path, data):
    # Same-directory temp + os.replace. A plain open(path, "w") truncates the file
    # before the new bytes land, so a crash/OOM/power-loss between the truncate and the
    # completed write (the one window the ERR/INT/TERM backup-restore trap cannot catch)
    # would leave a partial/truncated manifest. The temp keeps the rename on one
    # filesystem (atomic); on any failure it is removed and the error re-raised, leaving
    # the original target untouched.
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".bump-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(data)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise

with open(plugin_path) as f:
    plugin = json.load(f)
plugin["version"] = new
atomic_write(plugin_path, json.dumps(plugin, indent=2) + "\n")
PY
fi

# --- Sync skill frontmatter versions --------------------------------------
SKILLS_SYNCED=""
for skill in "$ROOT"/skills/*/SKILL.md; do
  [ -f "$skill" ] || continue
  rel="$(relpath "$skill")"
  if [ -n "$DRY_RUN" ]; then
    # Probe with the SAME quoted-form pattern the real rewrite below uses, so --dry-run and
    # the real run classify a SKILL.md identically (an unquoted scalar is skipped by both).
    has_ver="$(python3 -c "import re,sys;t=open(sys.argv[1]).read();print('1' if re.search(r'\n  version:\s*\"[^\"]*\"', t) else '0')" "$skill")"
    if [ "$has_ver" = "1" ]; then SKILLS_SYNCED="$SKILLS_SYNCED $rel"; else echo "warning: no metadata 'version:' line in $rel; skipped" >&2; fi
  else
    changed="$(python3 - "$skill" "$NEW" <<'PY'
import os, re, sys, tempfile
path, new = sys.argv[1], sys.argv[2]

def atomic_write(path, data):
    # Same-directory temp + os.replace (see the JSON-manifest step above): never
    # truncate-then-write, so an interruption cannot leave a half-written SKILL.md.
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".bump-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(data)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise

with open(path) as f:
    text = f.read()
# Rewrite the metadata version line in the YAML frontmatter (2-space indent).
text, n = re.subn(r'(\n  version:\s*)"[^"]*"', rf'\g<1>"{new}"', text, count=1)
if n:
    atomic_write(path, text)
print(n)
PY
)"
    if [ "$changed" = "0" ]; then
      echo "warning: no metadata 'version:' line in $rel; skipped" >&2
    else
      SKILLS_SYNCED="$SKILLS_SYNCED $rel"
    fi
  fi
done

# --- Sync the README version badge ----------------------------------------
# Best-effort: rewrite the shields.io static version badge
# (.../badge/version-<v>-informational) so the README always advertises the
# current version. Skipped (with a warning) if the README or the badge is
# absent. Dashes/underscores/spaces in the version are shields-escaped.
README_SYNCED=""
if [ -f "$README" ]; then
  if [ -n "$DRY_RUN" ]; then
    has_badge="$(python3 -c "import re,sys;t=open(sys.argv[1]).read();print('1' if re.search(r'img\.shields\.io/badge/version-.*?-informational', t) else '0')" "$README")"
    if [ "$has_badge" = "1" ]; then README_SYNCED="$(relpath "$README")"; else echo "warning: no shields version badge in $(relpath "$README"); skipped" >&2; fi
  else
    changed="$(python3 - "$README" "$NEW" <<'PY'
import os, re, sys, tempfile
path, new = sys.argv[1], sys.argv[2]

def atomic_write(path, data):
    # Same-directory temp + os.replace (see the JSON-manifest step above): never
    # truncate-then-write, so an interruption cannot leave a half-written README.
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".bump-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(data)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise

# shields.io escapes '_'->'__', '-'->'--', ' '->'_' in the badge message.
msg = new.replace("_", "__").replace("-", "--").replace(" ", "_")
with open(path) as f:
    text = f.read()
# Replace the message segment between 'version-' and '-informational' on the badge URL.
text, n = re.subn(
    r'(img\.shields\.io/badge/version-).*?(-informational)',
    lambda m: m.group(1) + msg + m.group(2),
    text, count=1)
if n:
    atomic_write(path, text)
print(n)
PY
)"
    if [ "$changed" = "0" ]; then
      echo "warning: no shields version badge in $(relpath "$README"); skipped" >&2
    else
      README_SYNCED="$(relpath "$README")"
    fi
  fi
fi

# --- Prepend a CHANGELOG entry --------------------------------------------
if [ -z "$DRY_RUN" ]; then
python3 - "$CHANGELOG" "$NEW" "$DATE" "$NOTE" <<'PY'
import os, sys, tempfile
path, new, date, note = sys.argv[1:5]

def atomic_write(path, data):
    # Same-directory temp + os.replace (see the JSON-manifest step above): never
    # truncate-then-write, so an interruption cannot leave a half-written CHANGELOG.
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".bump-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(data)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise

note = note or "Version bump."
block = f"## [{new}] - {date}\n\n### Changed\n- {note}\n\n"
with open(path) as f:
    lines = f.readlines()
# Insert above the first existing version section; warn and append if none exists.
idx = next((i for i, ln in enumerate(lines) if ln.startswith("## [")), None)
if idx is None:
    sys.stderr.write("warning: no '## [' version section in changelog; appending entry at end\n")
    idx = len(lines)
lines[idx:idx] = [block]
atomic_write(path, "".join(lines))
PY
fi

# All writes succeeded — commit the transaction: drop the restore trap and clean up.
if [ -z "$DRY_RUN" ]; then
  trap - ERR INT TERM
  rm -rf "$BUMP_BACKUP"
fi

if [ -n "$DRY_RUN" ]; then
  echo "dry-run: $CURRENT -> $NEW (files not modified)"
  echo
  echo "Would add to CHANGELOG.md:"
  echo "## [$NEW] - $DATE"
  echo
  echo "### Changed"
  echo "- ${NOTE:-Version bump.}"
  # if/fi (not `[ ] && echo`): as the branch's LAST statement under set -e, a false `[ -n ]`
  # test would otherwise become the script's exit status, making --dry-run exit 1 whenever no
  # skill is syncable — while the real run exits 0. Keep the probe's exit code trustworthy.
  if [ -n "$SKILLS_SYNCED" ]; then echo "  would sync$SKILLS_SYNCED"; fi
  if [ -n "$README_SYNCED" ]; then echo "  would update README badge ($README_SYNCED)"; fi
else
  echo "Bumped: $CURRENT -> $NEW"
  echo "  updated $(relpath "$PLUGIN_JSON")"
  [ -n "$SKILLS_SYNCED" ] && echo "  updated$SKILLS_SYNCED"
  [ -n "$README_SYNCED" ] && echo "  updated $README_SYNCED (version badge)"
  echo "  changelog entry added ($DATE)"
  echo
  echo "Next: review the diff, commit, then refresh/reinstall in the host you are testing."
fi
