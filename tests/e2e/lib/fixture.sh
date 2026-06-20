#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# tests/e2e/lib/fixture.sh — deterministic throwaway git fixture for the E2E recipes.
#
# Sourceable library: it defines helpers and runs nothing on its own, so a recipe (or the
# offline self-check in tests/run.sh) sources it and calls e2e_make_fixture. Every fixture is a
# fresh git-initialized temp tree, GUARANTEED outside the plugin tree, with a known seed file and
# exactly ONE initial commit — so a recipe's before/after diffs are deterministic.
#
# shellcheck disable=SC2329,SC2034  # sourced library: helpers/constants used by recipes + tests/run.sh

# The known seed file every fixture contains, and the deterministic, reversible marker line the
# read-write edit recipe asks the agent to append to it — so the expected diff is predictable.
E2E_FIXTURE_SEED="seed.txt"
E2E_FIXTURE_MARKER="reviewed-ok"

# e2e_make_fixture — create a fresh git-initialized throwaway tree and print its path. Seeded
# with $E2E_FIXTURE_SEED and exactly one initial commit. The caller removes it (rm -rf) when done.
e2e_make_fixture() {
  local root fx
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"   # plugin root (lib -> e2e -> tests -> root)
  fx="$(mktemp -d)" || return 1
  case "$fx/" in "$root/"*)
    echo "e2e_make_fixture: refusing a fixture inside the plugin tree ($fx)" >&2; rm -rf "$fx"; return 1;;
  esac
  printf 'line one\nline two\n' >"$fx/$E2E_FIXTURE_SEED"
  ( cd "$fx" && git init -q && git add -A \
      && git -c user.email=e2e@local -c user.name=e2e commit -qm "e2e fixture seed" ) >/dev/null 2>&1
  printf '%s' "$fx"
}

# e2e_fixture_commit_count DIR — print the number of commits in the fixture's history.
e2e_fixture_commit_count() {
  git -C "$1" rev-list --count HEAD 2>/dev/null
}

# e2e_fixture_reset DIR — restore the fixture to its initial commit (drop any edit AND any
# untracked file), so each agent in a recipe starts from the same clean baseline and the
# expected diff stays predictable.
e2e_fixture_reset() {
  git -C "$1" reset -q --hard HEAD >/dev/null 2>&1
  git -C "$1" clean -qfd >/dev/null 2>&1
}
