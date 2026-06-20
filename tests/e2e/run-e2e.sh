#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# tests/e2e/run-e2e.sh — opt-in entry point for the end-to-end delegation recipes.
#
# Gated on EXTERNAL_AGENTS_LIVE — the SAME single arming switch as the live smoke harness — so it
# is a no-op by default and is NEVER part of the offline CI gate (shellcheck + tests/run.sh). It
# discovers reachable agents, then dispatches each recipe under tests/e2e/ (added by the Phase
# 3.2-3.4 plan items), passing the reachable set. See docs/e2e-recipe.md.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$HERE/../.." && pwd -P)"
RUN="$ROOT/scripts/run-agent.sh"

# Opt-in gate: unset/0 skips every recipe and exits 0.
LIVE="${EXTERNAL_AGENTS_LIVE:-0}"
if [ "$LIVE" != "1" ]; then
  echo "e2e recipes skipped (set EXTERNAL_AGENTS_LIVE=1)"
  exit 0
fi
[ -x "$RUN" ] || { echo "e2e: driver not found at $RUN" >&2; exit 1; }
echo "external-agents e2e recipes: armed (EXTERNAL_AGENTS_LIVE=1)"

# Per-agent CLI detection via the driver's --discover (same command -v probe as --check). An
# agent whose CLI is absent is skipped cleanly; absence is never a failure.
reachable=()
while read -r a state _; do
  [ -n "$a" ] || continue
  if [ "$state" = "present" ]; then reachable+=("$a"); else echo "e2e: $a skipped (not reachable on PATH)"; fi
done < <("$RUN" --discover 2>/dev/null)

if [ "${#reachable[@]}" -eq 0 ]; then
  echo "e2e: no reachable agents — nothing to do (exit 0)"
  exit 0
fi
echo "e2e: reachable agents: ${reachable[*]}"

# Dispatch each recipe that exists, passing the reachable agents. Recipes are self-contained
# (they source the fixture/capture libs themselves) and are added by Phase 3.2-3.4.
rv=0
for recipe in review-readonly edit-readwrite edit-non-git; do
  script="$HERE/$recipe.sh"
  [ -f "$script" ] || continue
  echo "e2e: running recipe '$recipe'"
  bash "$script" "${reachable[@]}" || rv=1
done
exit "$rv"
