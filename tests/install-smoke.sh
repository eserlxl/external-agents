#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# external-agents/tests/install-smoke.sh — OPT-IN install / upgrade smoke harness.
#
# Proves the PACKAGE installs and upgrades from a published tag end to end — the one
# thing the offline gate (tests/run.sh) and the live agent smoke (tests/live-smoke.sh)
# cannot show. It clones the repo AT A TAG (never a branch) into a DISPOSABLE tree,
# "loads" the plugin from that checkout, and verifies the installed driver answers
# `scripts/run-agent.sh --check` (presence preflight — never an auth call) and
# `--version` (the lockstep version). The upgrade variant checks out an older tag then a
# newer tag and asserts `--version` advances.
#
# ARMING SWITCH — EXTERNAL_AGENTS_LIVE  (the single opt-in for ALL live work, shared with
# tests/live-smoke.sh):
#   unset or 0 : skip every step, touch nothing, exit 0  (the default — safe in CI).
#   1          : arm the harness — clone at a tag and verify install / upgrade.
#
# Optional knobs (only read when armed):
#   EXTERNAL_AGENTS_INSTALL_TAG    tag to install for the single-install check
#                                  (default: the newest vX.Y.Z tag).
#   EXTERNAL_AGENTS_UPGRADE_FROM   older tag for the upgrade check (default: the previous vX.Y.Z tag).
#   EXTERNAL_AGENTS_UPGRADE_TO     newer tag for the upgrade check (default: EXTERNAL_AGENTS_INSTALL_TAG).
#
# This NEVER touches the working tree: all work happens in a `git clone` under $TMPDIR.
# Sourceable: every step lives in a function and main() runs ONLY when this script is
# executed directly, so it can be sourced to unit-test the helpers offline.
# Run from anywhere:  bash tests/install-smoke.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

# installed_version CHECKOUT — print the version run-agent.sh reports from a checkout.
installed_version() {
  bash "$1/scripts/run-agent.sh" --version 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?' | head -1
}

# clone_at_tag TAG DEST — clone the real repo at TAG into DEST (a fresh dir). Returns non-zero
# if the clone or the detached checkout fails. A local clone is offline and fast.
clone_at_tag() {
  local tag="$1" dest="$2"
  git clone -q "$ROOT" "$dest" >/dev/null 2>&1 || return 1
  ( cd "$dest" && git -c advice.detachedHead=false checkout -q "$tag" ) >/dev/null 2>&1
}

# verify_install CHECKOUT — assert the loaded plugin's driver answers --check (presence verdict,
# never an auth call) and --version (a version string). Returns non-zero on failure.
verify_install() {
  local co="$1" rc=0 ver chk
  if [ -x "$co/scripts/run-agent.sh" ]; then
    echo "install smoke: driver present in the checkout"
  else
    echo "install smoke: FAIL driver missing in the checkout" >&2
    return 1
  fi
  # --check is a presence preflight (its exit code reflects missing CLIs); require only that it
  # RUNS and prints its preflight header — not that every agent CLI is installed (that is readiness).
  # Capture first, then grep: piping --check straight into grep would, under `set -o pipefail`,
  # surface --check's own non-zero exit (missing CLIs) and mask a matched header (false FAIL).
  chk="$(bash "$co/scripts/run-agent.sh" --check 2>&1)"
  if printf '%s\n' "$chk" | grep -q "external-agents preflight:"; then
    echo "install smoke: --check ran (presence preflight, no auth call)"
  else
    echo "install smoke: FAIL --check did not run" >&2
    rc=1
  fi
  ver="$(installed_version "$co")"
  if [ -n "$ver" ]; then
    echo "install smoke: --version reports $ver"
  else
    echo "install smoke: FAIL --version produced no version" >&2
    rc=1
  fi
  return "$rc"
}

# The newest / previous vX.Y.Z tags by version order.
newest_tag()   { git -C "$ROOT" tag -l 'v*' --sort=-v:refname | head -1; }
previous_tag() { git -C "$ROOT" tag -l 'v*' --sort=-v:refname | sed -n 2p; }

main() {
  local LIVE="${EXTERNAL_AGENTS_LIVE:-0}"
  if [ "$LIVE" != "1" ]; then
    echo "install smoke skipped (set EXTERNAL_AGENTS_LIVE=1)"
    return 0
  fi
  command -v git >/dev/null 2>&1 || { echo "install smoke: git unavailable — nothing to do (exit 0)"; return 0; }

  local install_tag="${EXTERNAL_AGENTS_INSTALL_TAG:-$(newest_tag)}"
  if [ -z "$install_tag" ]; then
    echo "install smoke: no vX.Y.Z tag found — nothing to install (exit 0)"
    return 0
  fi
  echo "external-agents install smoke: armed (EXTERNAL_AGENTS_LIVE=1)"

  local fails=0 d1 v_installed
  # 1) Single install: clone AT the install tag and verify the loaded driver.
  d1="$(mktemp -d)"
  if clone_at_tag "$install_tag" "$d1"; then
    echo "install smoke: installed $install_tag into a disposable clone"
    verify_install "$d1" || fails=$((fails + 1))
    v_installed="$(installed_version "$d1")"
    case "$install_tag" in
      "v$v_installed") echo "install smoke: tag $install_tag matches the reported version v$v_installed";;
      *)               echo "install smoke: NOTE tag $install_tag vs reported version $v_installed";;
    esac
  else
    echo "install smoke: FAIL could not clone at $install_tag" >&2
    fails=$((fails + 1))
  fi
  rm -rf "$d1"

  # 2) Upgrade: install FROM an older tag, then check out the newer tag, asserting --version advances.
  local from_tag="${EXTERNAL_AGENTS_UPGRADE_FROM:-$(previous_tag)}"
  local to_tag="${EXTERNAL_AGENTS_UPGRADE_TO:-$install_tag}"
  if [ -n "$from_tag" ] && [ "$from_tag" != "$to_tag" ]; then
    local du dv_from dv_to
    du="$(mktemp -d)"
    if clone_at_tag "$from_tag" "$du"; then
      dv_from="$(installed_version "$du")"
      ( cd "$du" && git -c advice.detachedHead=false checkout -q "$to_tag" ) >/dev/null 2>&1
      dv_to="$(installed_version "$du")"
      if [ -n "$dv_from" ] && [ -n "$dv_to" ] && [ "$dv_from" != "$dv_to" ] \
        && [ "$(printf '%s\n%s\n' "$dv_from" "$dv_to" | sort -V | head -1)" = "$dv_from" ]; then
        echo "install smoke: upgrade $from_tag -> $to_tag advances --version ($dv_from -> $dv_to)"
      else
        echo "install smoke: FAIL upgrade did not advance --version ($dv_from -> $dv_to)" >&2
        fails=$((fails + 1))
      fi
    else
      echo "install smoke: FAIL could not clone at $from_tag for the upgrade check" >&2
      fails=$((fails + 1))
    fi
    rm -rf "$du"
  else
    echo "install smoke: upgrade check skipped (need two distinct tags; from='$from_tag' to='$to_tag')"
  fi

  if [ "$fails" -gt 0 ]; then
    echo "install smoke: $fails check(s) failed" >&2
    return 1
  fi
  echo "install smoke: install + upgrade checks passed ($install_tag)"
  return 0
}

# Run main only when executed directly (not when sourced to unit-test the helpers).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  main "$@"
  exit $?
fi
