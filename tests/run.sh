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
assert_exit() { [ "$3" = "$2" ] && ok "$1" || bad "$1" "expected exit $2, got $3"; }

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
  [ "$out_jq" = "$out_py" ] && ok "jq and python3 --list output identical" \
    || bad "jq and python3 --list output identical" "backends diverged"
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
