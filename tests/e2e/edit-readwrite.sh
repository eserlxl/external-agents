#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# tests/e2e/edit-readwrite.sh — the read-write edit E2E recipe.
#
# Self-contained: sources the fixture/capture libs, honors the EXTERNAL_AGENTS_LIVE opt-in gate,
# and for each reachable agent drives run-agent.sh in read-write mode with a deterministic
# tiny-edit prompt against a fresh throwaway git fixture, capturing the before/after evidence and
# asserting the agent produced a changed file. Run via tests/e2e/run-e2e.sh or directly.
# See docs/e2e-recipe.md.
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
  echo "e2e edit-readwrite skipped (set EXTERNAL_AGENTS_LIVE=1)"
  exit 0
fi

# Deterministic, reversible edit: append the known marker line to the seed file, so the expected
# diff is predictable across agents.
EDIT_PROMPT="${E2E_EDIT_PROMPT:-Append one new line to $E2E_FIXTURE_SEED whose exact content is: $E2E_FIXTURE_MARKER — and make only that single change.}"
E2E_OUT="${EXTERNAL_AGENTS_OUT:-$HOME/.external-agents/logs}/e2e/edit-readwrite"
TIMEOUT="${EXTERNAL_AGENTS_LIVE_TIMEOUT:-120}"

# Agents: from args (run-e2e.sh passes the reachable set), else discover reachable here.
agents=("$@")
if [ "${#agents[@]}" -eq 0 ]; then
  while read -r a state _; do [ "$state" = "present" ] && agents+=("$a"); done < <("$RUN" --discover 2>/dev/null)
fi
[ "${#agents[@]}" -gt 0 ] || { echo "e2e edit-readwrite: no agents to run (exit 0)"; exit 0; }

# One fixture, reset to its initial commit before each agent so every run starts identically.
fx="$(e2e_make_fixture)" || { echo "e2e edit-readwrite: FAIL: could not create fixture" >&2; exit 1; }
rv=0
for a in "${agents[@]}"; do
  e2e_fixture_reset "$fx"
  ev="$E2E_OUT/$a"; out="$(mktemp -d)"; proj="$out/$(basename "$fx")"
  e2e_capture_pre "$fx" "$ev"
  # Capture the driver's stdout (it PRODUCES the post-write verification block) and stderr.
  EXTERNAL_AGENTS_OUT="$out" "$RUN" --agent "$a" --write --yes --target "$fx" \
    --timeout "$TIMEOUT" --prompt "$EDIT_PROMPT" >"$ev/driver.out" 2>"$ev/driver.err"
  e2e_capture_post "$fx" "$proj" "$a" "$ev"
  rc="$(cat "$proj/$a.rc" 2>/dev/null || echo '?')"
  bytes=$(wc -c <"$proj/$a.md" 2>/dev/null | tr -d ' '); bytes="${bytes:-0}"
  if [ "$rc" = "0" ] && [ "$bytes" -gt 0 ]; then
    echo "e2e edit-readwrite: $a  ok (rc=0 bytes=$bytes; evidence: $ev)"
  else
    echo "e2e edit-readwrite: $a  FAIL (rc=$rc bytes=$bytes)" >&2; rv=1
  fi
  # A write run must produce a changed file in the fixture.
  if [ -s "$ev/post.status" ]; then
    echo "e2e edit-readwrite: $a  changed-file: $(wc -l <"$ev/post.status" | tr -d ' ') path(s) changed"
  else
    echo "e2e edit-readwrite: $a  FAIL: write run produced no change in the fixture" >&2; rv=1
  fi
  # The driver PRODUCES a post-write verification block on a git target — assert it ran and named
  # the actual changed path (the driver's printed block echoes git status --porcelain / diff --stat).
  changed_path="$(awk 'NR==1{print $2}' "$ev/post.status" 2>/dev/null)"
  if grep -q "git changes after write" "$ev/driver.out" 2>/dev/null \
     && [ -n "$changed_path" ] && grep -qF -- "$changed_path" "$ev/driver.out" 2>/dev/null; then
    echo "e2e edit-readwrite: $a  post-write verification: block present and names '$changed_path'"
  else
    echo "e2e edit-readwrite: $a  FAIL: post-write verification block missing or does not name the changed file" >&2; rv=1
  fi
  rm -rf "$out"
done
rm -rf "$fx"
exit "$rv"
