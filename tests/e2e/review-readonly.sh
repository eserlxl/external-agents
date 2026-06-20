#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# tests/e2e/review-readonly.sh — the read-only review E2E recipe.
#
# Self-contained: sources the fixture/capture libs, honors the EXTERNAL_AGENTS_LIVE opt-in gate,
# and for each reachable agent drives run-agent.sh --read-only with a fixed review prompt against
# a throwaway git fixture, capturing the standard before/after evidence. Run via
# tests/e2e/run-e2e.sh (which passes the reachable agents) or directly. See docs/e2e-recipe.md.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$HERE/../.." && pwd -P)"
RUN="$ROOT/scripts/run-agent.sh"
# shellcheck source=/dev/null
. "$HERE/lib/fixture.sh"
# shellcheck source=/dev/null
. "$HERE/lib/capture.sh"

LIVE="${EXTERNAL_AGENTS_LIVE:-0}"
if [ "$LIVE" != "1" ]; then
  echo "e2e review-readonly skipped (set EXTERNAL_AGENTS_LIVE=1)"
  exit 0
fi

REVIEW_PROMPT="${E2E_REVIEW_PROMPT:-Review $E2E_FIXTURE_SEED and reply with one short observation. Do not edit anything.}"
E2E_OUT="${EXTERNAL_AGENTS_OUT:-$HOME/.external-agents/logs}/e2e/review-readonly"
TIMEOUT="${EXTERNAL_AGENTS_LIVE_TIMEOUT:-120}"

# Agents: from args (run-e2e.sh passes the reachable set), else discover reachable here.
agents=("$@")
if [ "${#agents[@]}" -eq 0 ]; then
  while read -r a state _; do [ "$state" = "present" ] && agents+=("$a"); done < <("$RUN" --discover 2>/dev/null)
fi
[ "${#agents[@]}" -gt 0 ] || { echo "e2e review-readonly: no agents to run (exit 0)"; exit 0; }

rv=0
for a in "${agents[@]}"; do
  fx="$(e2e_make_fixture)" || { echo "e2e review-readonly: $a  FAIL: could not create fixture" >&2; rv=1; continue; }
  ev="$E2E_OUT/$a"; out="$(mktemp -d)"; proj="$out/$(basename "$fx")"
  e2e_capture_pre "$fx" "$ev"
  # Capture the driver's own stderr (NOTEs, model line, agy best-effort warning) as evidence.
  EXTERNAL_AGENTS_OUT="$out" "$RUN" --agent "$a" --read-only --target "$fx" \
    --timeout "$TIMEOUT" --prompt "$REVIEW_PROMPT" >/dev/null 2>"$ev/driver.err"
  e2e_capture_post "$fx" "$proj" "$a" "$ev"
  rc="$(cat "$proj/$a.rc" 2>/dev/null || echo '?')"
  bytes=$(wc -c <"$proj/$a.md" 2>/dev/null | tr -d ' '); bytes="${bytes:-0}"
  if [ "$rc" = "0" ] && [ "$bytes" -gt 0 ]; then
    echo "e2e review-readonly: $a  ok (rc=0 bytes=$bytes; evidence: $ev)"
  else
    echo "e2e review-readonly: $a  FAIL (rc=$rc bytes=$bytes)" >&2; rv=1
  fi
  # Enforced agents (codex/claude/cursor) must leave the fixture byte-identical — any change to
  # git status --porcelain is a loud hard failure. (agy read-only is best-effort — next sub-phase.)
  case "$a" in
    codex|claude|cursor)
      if [ -s "$ev/post.status" ]; then
        echo "e2e review-readonly: $a  FAIL: enforced read-only MUTATED the fixture:" >&2
        sed 's/^/    /' "$ev/post.status" >&2; rv=1
      else
        echo "e2e review-readonly: $a  no-mutation: fixture unchanged (enforced read-only)"
      fi;;
    agy)
      # agy read-only is best-effort (--sandbox is NOT a hard write barrier): capture the
      # driver's best-effort warning and record the OBSERVED mutation status WITHOUT asserting a
      # hard guarantee — a change does NOT fail the recipe.
      if grep -q "best-effort" "$ev/driver.err" 2>/dev/null; then
        echo "e2e review-readonly: agy  best-effort warning captured (read-only is not enforced)"
      else
        echo "e2e review-readonly: agy  NOTE: expected best-effort warning not found in driver stderr" >&2
      fi
      if [ -s "$ev/post.status" ]; then
        echo "e2e review-readonly: agy  best-effort: fixture CHANGED (observed, not a guarantee)"
      else
        echo "e2e review-readonly: agy  best-effort: fixture unchanged (observed, not enforced)"
      fi;;
  esac
  rm -rf "$fx" "$out"
done
exit "$rv"
