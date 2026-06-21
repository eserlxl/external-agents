#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# run-history-maintain.sh — bounded RETENTION / ROTATION of the append-only run index (index.jsonl).
# When a threshold is crossed it atomically rolls index.jsonl to a timestamped archive under
# EXTERNAL_AGENTS_OUT/archive and starts a fresh index — no rows lost, never touching the repo.
# Optionally prunes old archives. See RUNBOOK.md "Retention & rotation policy".
#
# Usage:  run-history-maintain.sh [--force] [--base DIR]
#   --force     rotate regardless of thresholds (still a no-op on a missing/empty index)
#   --base DIR  transcript base (default: ${EXTERNAL_AGENTS_OUT:-$HOME/.external-agents/logs})
# Env: EXTERNAL_AGENTS_INDEX_MAX_BYTES (default 10485760 = 10 MiB),
#      EXTERNAL_AGENTS_INDEX_MAX_ROWS  (default 50000),
#      EXTERNAL_AGENTS_ARCHIVE_KEEP    (default 0 = keep every archive).
set -uo pipefail

FORCE=0
BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1; shift;;
    --base)  [ $# -ge 2 ] || { echo "run-history-maintain: $1 needs a value" >&2; exit 2; }; BASE="$2"; shift 2;;
    -h|--help) sed -n '5,16p' "$0"; exit 0;;
    *) echo "run-history-maintain: unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$BASE" ] || BASE="${EXTERNAL_AGENTS_OUT:-$HOME/.external-agents/logs}"
INDEX="$BASE/index.jsonl"
ARCHIVE_DIR="$BASE/archive"
MAX_BYTES="${EXTERNAL_AGENTS_INDEX_MAX_BYTES:-10485760}"
MAX_ROWS="${EXTERNAL_AGENTS_INDEX_MAX_ROWS:-50000}"
KEEP="${EXTERNAL_AGENTS_ARCHIVE_KEEP:-0}"

if [ ! -f "$INDEX" ]; then
  echo "run-history-maintain: no index at $INDEX (nothing to rotate)"
  exit 0
fi
bytes="$(wc -c <"$INDEX" 2>/dev/null | tr -d ' ')"; [ -n "$bytes" ] || bytes=0
rows="$(wc -l <"$INDEX" 2>/dev/null | tr -d ' ')";  [ -n "$rows" ]  || rows=0

needs_rotate=0
[ "$FORCE" = "1" ]            && needs_rotate=1
[ "$bytes" -gt "$MAX_BYTES" ] && needs_rotate=1
[ "$rows"  -gt "$MAX_ROWS" ]  && needs_rotate=1
[ "$bytes" -eq 0 ]            && needs_rotate=0   # never rotate an empty index

if [ "$needs_rotate" = "0" ]; then
  echo "run-history-maintain: index within thresholds ($rows rows, $bytes bytes) — no rotation"
  exit 0
fi

ts="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo unknown)"
mkdir -p "$ARCHIVE_DIR" 2>/dev/null || { echo "run-history-maintain: cannot create $ARCHIVE_DIR" >&2; exit 1; }
dest="$ARCHIVE_DIR/index-$ts.jsonl"
i=0; while [ -e "$dest" ]; do i=$((i + 1)); dest="$ARCHIVE_DIR/index-$ts.$i.jsonl"; done
# Atomic rename within one filesystem (archive shares the base) — a concurrent appender lands in
# either the archived file or the fresh one, never a half-written row; no rows are lost.
mv "$INDEX" "$dest" || { echo "run-history-maintain: rotation (mv) failed" >&2; exit 1; }
: >"$INDEX" 2>/dev/null || true   # start a fresh empty index; the next append continues here
echo "run-history-maintain: rotated $rows row(s) -> $dest; fresh index at $INDEX"

# Prune: keep only the newest KEEP archives (0 = keep all). Order by MODIFICATION TIME, not name: a
# same-second rotation collision names the second file index-<ts>.1.jsonl, which sorts BEFORE the base
# index-<ts>.jsonl lexicographically — so a name sort would keep the older archive and prune the newer.
if [ "$KEEP" -gt 0 ]; then
  arcs=()
  # shellcheck disable=SC2012 # archive names are controlled (index-*.jsonl, no spaces/newlines); ls -t is portable, find -printf is not
  while IFS= read -r f; do [ -n "$f" ] && arcs+=("$f"); done < <(ls -t "$ARCHIVE_DIR"/index-*.jsonl 2>/dev/null)
  n=0
  for f in ${arcs[@]+"${arcs[@]}"}; do
    n=$((n + 1))
    [ "$n" -le "$KEEP" ] && continue
    rm -f "$f" 2>/dev/null && echo "run-history-maintain: pruned old archive $f"
  done
fi
