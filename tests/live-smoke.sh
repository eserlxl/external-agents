#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# external-agents/tests/live-smoke.sh — OPT-IN live smoke harness.
#
# Unlike tests/run.sh (which is fully offline and CLI-free), this harness MAY
# launch the real external agent CLIs (agy / codex / claude / cursor) to verify
# that the driver actually round-trips against them. It is therefore gated behind
# a single explicit arming switch and is NEVER part of the offline CI gate.
#
# ARMING SWITCH — EXTERNAL_AGENTS_LIVE  (the single opt-in for ALL live work):
#   unset or 0 : skip every live step, launch nothing, exit 0  (the default).
#   1          : arm the harness — discover reachable agents and run live checks.
#
# This mirrors the existing EXTERNAL_AGENTS_* convention (EXTERNAL_AGENTS_OUT,
# EXTERNAL_AGENTS_AGY_QUOTA_CMD, …). Run from anywhere:  bash tests/live-smoke.sh
set -uo pipefail

# --- arming gate: the one switch that decides whether ANY live work runs --------
# Read it BEFORE resolving anything else so an unarmed run is a pure no-op.
LIVE="${EXTERNAL_AGENTS_LIVE:-0}"
if [ "$LIVE" != "1" ]; then
  echo "live smoke skipped (set EXTERNAL_AGENTS_LIVE=1)"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
RUN="$ROOT/scripts/run-agent.sh"
[ -x "$RUN" ] || { echo "live smoke: driver not found at $RUN" >&2; exit 1; }

echo "external-agents live smoke: armed (EXTERNAL_AGENTS_LIVE=1)"

# Scope the harness to reachable agents and skip the rest with a clear per-agent line.
# Discovery is the driver's machine-readable --discover surface (same agent_bin /
# command -v probe as --check), so the harness never re-implements detection. Absence
# is NEVER a failure: an environment with no agent CLIs on PATH still exits 0.
# live_argv_record OUTDIR AGENT — print the masked launch-argv record run_one writes for
# AGENT under OUTDIR ($OUTDIR/<agent>.argv): the resolved argv with the prompt shown as
# <PROMPT>, secret/PII-free. The argv-equivalence check (next sub-phase) compares this
# against the agent's --dry-run argv to prove the live launch argv is correct.
# shellcheck disable=SC2329  # consumption seam — invoked by the argv-equivalence routine
live_argv_record() {
  cat "$1/$2.argv" 2>/dev/null
}

discovered="$("$RUN" --discover 2>/dev/null)"
reachable=()
while read -r a state _; do
  [ -n "$a" ] || continue
  if [ "$state" = "present" ]; then
    reachable+=("$a")
  else
    echo "live smoke: $a skipped (not reachable on PATH)"
  fi
done <<EOF
$discovered
EOF

if [ "${#reachable[@]}" -eq 0 ]; then
  echo "live smoke: no reachable agents — nothing to verify (exit 0)"
  exit 0
fi
echo "live smoke: reachable agents: ${reachable[*]}"
# Live checks over ${reachable[@]} (argv equivalence, non-mutation, transcript
# success) are added by the later Phase 2 sub-phases.
exit 0
