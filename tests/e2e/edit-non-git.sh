#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# tests/e2e/edit-non-git.sh — read-write delegation against a deliberately NON-git directory.
#
# Self-contained: sources the capture/gate helpers, honors the EXTERNAL_AGENTS_LIVE opt-in, and
# for each reachable agent drives run-agent.sh --write against a throwaway directory that is NOT a
# git repo, asserting the driver's no-baseline warning appears in captured stderr. See
# docs/e2e-recipe.md.
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
  echo "e2e edit-non-git skipped (set EXTERNAL_AGENTS_LIVE=1)"
  exit 0
fi

EDIT_PROMPT="${E2E_NONGIT_PROMPT:-Append one new line whose exact content is $E2E_FIXTURE_MARKER to notes.txt — and make only that single change.}"
E2E_OUT="${EXTERNAL_AGENTS_OUT:-$HOME/.external-agents/logs}/e2e/edit-non-git"
TIMEOUT="${EXTERNAL_AGENTS_LIVE_TIMEOUT:-120}"

# Agents: from args (run-e2e.sh passes the reachable set), else discover reachable here.
agents=("$@")
if [ "${#agents[@]}" -eq 0 ]; then
  while read -r a state _; do [ "$state" = "present" ] && agents+=("$a"); done < <("$RUN" --discover 2>/dev/null)
fi
[ "${#agents[@]}" -gt 0 ] || { echo "e2e edit-non-git: no agents to run (exit 0)"; exit 0; }

rv=0
for a in "${agents[@]}"; do
  # A DELIBERATELY non-git throwaway directory (no git init) — the driver has no baseline.
  ng="$(mktemp -d)"; printf 'plain seed\n' >"$ng/notes.txt"
  ev="$E2E_OUT/$a"; out="$(mktemp -d)"; proj="$out/$(basename "$ng")"
  mkdir -p "$ev"
  EXTERNAL_AGENTS_OUT="$out" "$RUN" --agent "$a" --write --yes --target "$ng" \
    --timeout "$TIMEOUT" --prompt "$EDIT_PROMPT" >"$ev/driver.out" 2>"$ev/driver.err"
  e2e_capture_post "$ng" "$proj" "$a" "$ev"   # git fields harmlessly empty on a non-git target
  rc="$(cat "$proj/$a.rc" 2>/dev/null || echo '?')"
  bytes=$(wc -c <"$proj/$a.md" 2>/dev/null | tr -d ' '); bytes="${bytes:-0}"
  if [ "$rc" = "0" ] && [ "$bytes" -gt 0 ]; then
    echo "e2e edit-non-git: $a  ok (rc=0 bytes=$bytes; evidence: $ev)"
  else
    echo "e2e edit-non-git: $a  FAIL (rc=$rc bytes=$bytes)" >&2; rv=1
  fi
  # The driver must WARN that there is no git baseline to diff or revert (run-agent.sh).
  if grep -q "no baseline to diff or revert" "$ev/driver.err" 2>/dev/null; then
    echo "e2e edit-non-git: $a  no-baseline warning captured (non-git target)"
  else
    echo "e2e edit-non-git: $a  FAIL: missing the driver's no-baseline warning" >&2; rv=1
  fi
  # And the driver must SUPPRESS the post-write verification block on a non-git target (no baseline).
  if grep -q "git changes after write" "$ev/driver.out" 2>/dev/null; then
    echo "e2e edit-non-git: $a  FAIL: post-write verification block unexpectedly present on a non-git target" >&2; rv=1
  else
    echo "e2e edit-non-git: $a  post-write block correctly suppressed (non-git target)"
  fi
  rm -rf "$ng" "$out"
done
exit "$rv"
