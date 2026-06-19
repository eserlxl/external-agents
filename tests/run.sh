#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Focused, offline tests for the external-agents plugin.
#
# Everything here is deterministic and CLI-free: run-agent.sh is exercised only
# through --dry-run (argv resolution), --list (config parsing), and early-exit
# error/safety paths, so NO external agent CLI (agy/codex/claude/cursor) is ever
# launched. Run from anywhere:  bash tests/run.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
RUN="$ROOT/scripts/run-agent.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

# assert_contains DESC HAYSTACK NEEDLE
assert_contains() { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "missing: $3";; esac; }
# assert_exit DESC EXPECTED ACTUAL
assert_exit() { if [ "$3" = "$2" ]; then ok "$1"; else bad "$1" "expected exit $2, got $3"; fi; }

# dry DESC NEEDLE -- <run-agent args...>
# Captures `run-agent.sh --dry-run ...` stdout and asserts NEEDLE is present.
dry() {
  local desc="$1" needle="$2"; shift 2; [ "$1" = "--" ] && shift
  local out; out="$(bash "$RUN" --dry-run "$@" --prompt 'hello world' 2>/dev/null)"
  assert_contains "$desc" "$out" "$needle"
}

echo "== run-agent.sh --dry-run argv resolution (agents.json tier mapping) =="
dry "agy read-only -> --sandbox"                 "--sandbox"                     -- --agent agy    --read-only --effort medium
dry "agy read-only -> mapped Gemini model"       "Gemini 3.5 Flash (Medium)"     -- --agent agy    --read-only --effort medium
dry "agy write -> skip-permissions"              "--dangerously-skip-permissions" -- --agent agy    --write     --effort medium
dry "codex read-only -> -s read-only"            "-s read-only"                  -- --agent codex  --read-only --effort high
dry "codex high -> model_reasoning_effort"       'model_reasoning_effort="high"' -- --agent codex  --read-only --effort high
dry "codex write -> -s workspace-write"          "-s workspace-write"            -- --agent codex  --write     --effort high
dry "claude write -> permission-mode acceptEdits" "--permission-mode acceptEdits" -- --agent claude --write     --effort high
dry "claude high -> --effort high"               "--effort high"                 -- --agent claude --write     --effort high
dry "claude read-only -> allowedTools"           "--allowedTools"                -- --agent claude --read-only --effort high
dry "cursor read-only -> --mode plan"            "--mode plan"                   -- --agent cursor --read-only --effort medium
dry "cursor read-only -> composer-2.5"           "composer-2.5"                  -- --agent cursor --read-only --effort medium
dry "cursor write -> --force"                    "--force"                       -- --agent cursor --write     --effort medium
dry "cursor binary is cursor-agent"              "cursor-agent"                  -- --agent cursor --write     --effort medium

echo "== jq / python3 config-backend parity (--list byte-identical) =="
out_jq="$(bash "$RUN" --list 2>/dev/null)"
tdir="$(mktemp -d)"
mkdir -p "$tdir/bin"
for t in bash env python3 grep dirname basename cat sed sort tr cut wc paste date mktemp git head tail; do
  s="$(command -v "$t" 2>/dev/null)" && ln -s "$s" "$tdir/bin/$t" 2>/dev/null || true
done
# Restricted PATH hides jq but keeps python3 -> forces the python backend.
out_py="$(PATH="$tdir/bin" "$tdir/bin/bash" "$RUN" --list 2>/dev/null)"
rm -rf "$tdir"
if [ -n "$out_jq" ] && [ -n "$out_py" ]; then
  if [ "$out_jq" = "$out_py" ]; then
    ok "jq and python3 --list output identical"
  else
    bad "jq and python3 --list output identical" "backends diverged"
  fi
else
  printf '  skip jq/python3 parity (could not run both backends in this environment)\n'
fi

echo "== effort + write-mode safety gates (early exit, no agent launched) =="
bash "$RUN" --agent codex --effort bogus --dry-run --prompt x >/dev/null 2>&1
assert_exit "unknown --effort tier exits 2" 2 "$?"

# Write target == the plugin tree itself -> refused before any launch.
bash "$RUN" --agent codex --target "$ROOT" --prompt x >/dev/null 2>&1
assert_exit "write into plugin tree exits 2" 2 "$?"

# Write target outside cwd without --yes -> refused before any launch.
otherdir="$(mktemp -d)"
bash "$RUN" --agent codex --target "$otherdir" --prompt x >/dev/null 2>&1
assert_exit "non-cwd write without --yes exits 2" 2 "$?"
rmdir "$otherdir" 2>/dev/null || true

# --timeout must be a positive integer, validated up front (before any launch).
bash "$RUN" --agent codex --dry-run --timeout abc --prompt x >/dev/null 2>&1
assert_exit "--timeout abc exits 2" 2 "$?"
bash "$RUN" --agent codex --dry-run --timeout 0 --prompt x >/dev/null 2>&1
assert_exit "--timeout 0 exits 2" 2 "$?"
bash "$RUN" --agent codex --dry-run --timeout 30 --prompt x >/dev/null 2>&1
assert_exit "valid --timeout 30 accepted" 0 "$?"

echo "== version lockstep (plugin.json == SKILL.md == README badge) =="
pv="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT/.claude-plugin/plugin.json")"
sv="$(grep -oE '^  version: "[^"]+"' "$ROOT/skills/external-agents/SKILL.md" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
rvraw="$(grep -oE 'badge/version-.*-informational' "$ROOT/README.md" | head -1 | sed -E 's#badge/version-(.*)-informational#\1#')"
# Reverse the shields.io message escaping ('--'->'-', '__'->'_').
rv="$(printf '%s' "$rvraw" | sed -e 's/--/-/g' -e 's/__/_/g')"
if [ "$pv" = "$sv" ] && [ "$pv" = "$rv" ]; then
  ok "all version strings agree ($pv)"
else
  bad "all version strings agree" "plugin.json=$pv SKILL.md=$sv README=$rv"
fi

out="$(bash "$RUN" --version 2>/dev/null)"
assert_contains "run-agent.sh --version prints the plugin version" "$out" "$pv"
out="$(bash "$RUN" -V 2>/dev/null)"
assert_contains "run-agent.sh -V prints the plugin version" "$out" "$pv"

echo "== bump-version.sh version compute (--dry-run, no writes) =="
BV="$ROOT/scripts/bump-version.sh"
core="${pv%%-*}"   # current release core, pre-release suffix stripped
IFS=. read -r _ma _mi _pa <<<"$core"
if [ -n "${_pa:-}" ]; then
  exp_patch="$_ma.$_mi.$((_pa + 1))"
  exp_minor="$_ma.$((_mi + 1)).0"
  exp_major="$((_ma + 1)).0.0"
  # ALLOW_DIRTY=1 bypasses the dirty-tree guard; --dry-run modifies nothing.
  assert_contains "bump patch -> $exp_patch" "$(ALLOW_DIRTY=1 bash "$BV" patch --dry-run 2>/dev/null)" "-> $exp_patch"
  assert_contains "bump minor -> $exp_minor" "$(ALLOW_DIRTY=1 bash "$BV" minor --dry-run 2>/dev/null)" "-> $exp_minor"
  assert_contains "bump major -> $exp_major" "$(ALLOW_DIRTY=1 bash "$BV" major --dry-run 2>/dev/null)" "-> $exp_major"
  assert_contains "explicit X.Y.Z target"   "$(ALLOW_DIRTY=1 bash "$BV" 2.5.0 --dry-run 2>/dev/null)" "-> 2.5.0"
  assert_contains "explicit pre-release"     "$(ALLOW_DIRTY=1 bash "$BV" 2.0.0-rc.1 --dry-run 2>/dev/null)" "-> 2.0.0-rc.1"
else
  printf '  skip bump-version compute (could not parse current version %s)\n' "$pv"
fi

echo "== agy quota-aware fallback model pick (--dry-run, stubbed quota) =="
PRIMARY="Claude Sonnet 4.6 (Thinking)"   # agy 'high' tier primary model
FALLBACK="Gemini 3.5 Flash (High)"       # agy 'high' tier Gemini fallback
stub="$(mktemp)"
# agy_pick JSON -> resolved agy --dry-run argv, with the quota CLI stubbed to emit JSON.
agy_pick() {
  printf '%s' "$1" >"$stub"
  EXTERNAL_AGENTS_AGY_QUOTA_CMD="cat $stub" bash "$RUN" --agent agy --effort high --dry-run --prompt x 2>/dev/null
}
assert_contains "agy quota available keeps primary" \
  "$(agy_pick "{\"models\":[{\"label\":\"$PRIMARY\",\"remainingPercentage\":0.5,\"isExhausted\":false}]}")" "$PRIMARY"
assert_contains "agy quota exhausted -> fallback" \
  "$(agy_pick "{\"models\":[{\"label\":\"$PRIMARY\",\"isExhausted\":true}]}")" "$FALLBACK"
assert_contains "agy label-not-found -> fallback" \
  "$(agy_pick '{"models":[]}')" "$FALLBACK"
assert_contains "agy quota CLI unavailable -> fallback" \
  "$(EXTERNAL_AGENTS_AGY_QUOTA_CMD=false bash "$RUN" --agent agy --effort high --dry-run --prompt x 2>/dev/null)" "$FALLBACK"
rm -f "$stub"

echo "== bump-version.sh lockstep write (mktemp fixture, real repo untouched) =="
ft="$(mktemp -d)"
mkdir -p "$ft/scripts" "$ft/.claude-plugin" "$ft/skills/external-agents"
cp "$ROOT/scripts/bump-version.sh" "$ft/scripts/"
cp "$ROOT/.claude-plugin/plugin.json" "$ft/.claude-plugin/"
cp "$ROOT/CHANGELOG.md" "$ROOT/README.md" "$ft/"
cp "$ROOT/skills/external-agents/SKILL.md" "$ft/skills/external-agents/"
# ALLOW_DIRTY=1 so the dirty-tree guard self-skips wherever mktemp lands.
ALLOW_DIRTY=1 bash "$ft/scripts/bump-version.sh" 1.2.3 >/dev/null 2>&1
assert_exit "bump-version.sh write run succeeds" 0 "$?"
assert_contains "bump write: plugin.json -> 1.2.3" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ft/.claude-plugin/plugin.json" 2>/dev/null)" "1.2.3"
grep -q '^  version: "1.2.3"' "$ft/skills/external-agents/SKILL.md"; assert_exit "bump write: SKILL.md frontmatter synced" 0 "$?"
grep -q 'version-1.2.3-informational' "$ft/README.md"; assert_exit "bump write: README badge synced" 0 "$?"
grep -q '## \[1.2.3\]' "$ft/CHANGELOG.md"; assert_exit "bump write: CHANGELOG entry added" 0 "$?"
rm -rf "$ft"

echo "== --check preflight (diagnostic; restricted PATH, no agent CLIs) =="
# Run --check with a PATH that holds the shell utilities but NONE of the agent CLIs,
# so every candidate (agy/codex/claude/cursor) must be reported missing and the exit
# code must reflect it. Reuses the restricted-bin technique from the parity test above.
cdir="$(mktemp -d)"
mkdir -p "$cdir/bin"
for t in bash env python3 grep dirname basename cat sed sort tr cut wc paste date mktemp git head tail; do
  s="$(command -v "$t" 2>/dev/null)" && ln -s "$s" "$cdir/bin/$t" 2>/dev/null || true
done
chk_out="$(PATH="$cdir/bin" "$cdir/bin/bash" "$RUN" --check 2>&1)"; chk_rc=$?
rm -rf "$cdir"
assert_contains "--check prints the preflight header"        "$chk_out" "external-agents preflight:"
assert_contains "--check probes cursor as the cursor-agent binary" "$chk_out" "need cursor-agent on PATH"
assert_exit     "--check exits non-zero when agent CLIs are missing" 1 "$chk_rc"

echo "== shellcheck (regression guard) =="
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck "$ROOT/scripts/run-agent.sh" "$ROOT/scripts/bump-version.sh" >/dev/null 2>&1; then
    ok "scripts/*.sh are shellcheck-clean"
  else
    bad "scripts/*.sh are shellcheck-clean" "run: shellcheck scripts/run-agent.sh scripts/bump-version.sh"
  fi
else
  printf '  skip shellcheck (not installed)\n'
fi

echo
echo "tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
