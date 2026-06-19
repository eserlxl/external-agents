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
# Live checks (agent discovery, scoping, argv equivalence, non-mutation,
# transcript success) are added by the later Phase 2 sub-phases. Until then an
# armed run simply confirms the driver is present and exits cleanly.
exit 0
