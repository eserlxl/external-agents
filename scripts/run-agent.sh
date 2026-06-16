#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# external-agents/scripts/run-agent.sh — dispatch ONE prompt to external coding
# agent CLIs (agy / codex / claude) as autonomous sub-agents, then collect each
# agent's response. This generalises council/run-council.sh from a fixed,
# read-only evaluation panel to an arbitrary task the agents may carry out in
# the working tree.
#
# The runner only knows how to *drive* each cli. The prompt is always passed as a
# single argv element (never eval'd, never word-split), so it is injection-safe:
#
#   READ-WRITE  (default — agents MAY edit files / run tools in the target):
#     agy     agy -p PROMPT --add-dir DIR --dangerously-skip-permissions [--model M]
#     codex   codex exec -s workspace-write -C DIR --skip-git-repo-check [-m M] [-c model_reasoning_effort="E"] PROMPT
#     claude  claude -p PROMPT --permission-mode acceptEdits [--model M] [--effort E]
#             NOTE: acceptEdits auto-accepts file EDITS but denies other shell
#             commands non-interactively. For tasks that must build / test / run
#             commands, pass --claude-perm bypassPermissions.
#
#   READ-ONLY  (--read-only — agents observe and report; codex/claude are HARD
#               read-only, agy is best-effort):
#     agy     agy -p PROMPT --sandbox --add-dir DIR [--model M]
#             NOTE: agy --sandbox restricts the terminal but does NOT block agy's
#             file-edit tools, so agy read-only is best-effort, NOT enforced. Use
#             codex/claude for a hard guarantee, or point --target at a throwaway copy.
#     codex   codex exec -s read-only -C DIR --skip-git-repo-check [-m M] [-c model_reasoning_effort="E"] PROMPT
#     claude  claude -p PROMPT --allowedTools Read Grep Glob [--model M] [--effort E]
#
#   (agy and claude run with cwd=DIR; codex takes -C DIR.)
#
# Usage:
#   run-agent.sh --agent <agy|codex|claude|all> (--prompt "..." | --prompt-file F | --prompt-file -)
#                [--target DIR] [--read-only | --write] [--model M] [--effort E]
#                [--claude-perm MODE] [--timeout SECS] [--out DIR] [--conf FILE]
#                [--list] [--check] [--dry-run] [-h | --help]
#
# --agent all  fans out to every agent ENABLED in agents.conf, in parallel.
# Transcripts land under --out (default ~/.external-agents/logs/<project>/<agent>.md)
# AND are echoed to stdout so the caller (Claude) sees every response inline.
#
# SAFETY: in the default read-write mode the agents can modify whatever is under
# --target. Point --target at the tree you actually want changed, and NEVER at a
# tree containing private IP you would not ship to an external provider (agy and
# codex are external services). Use --read-only when you only want analysis.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_ROOT="$(cd "$HERE/.." && pwd -P)"

AGENT=""
PROMPT=""
PROMPT_FILE=""
TARGET="$(pwd)"
MODE="write"                 # write (default) | readonly
MODE_SET=""                  # set once --read-only/--write is given explicitly
MODEL=""                     # per-run override; else from agents.conf / cli default
EFFORT=""                    # per-run override; else from agents.conf / cli default
CLAUDE_PERM="acceptEdits"    # claude write-mode permission mode
OUT=""                       # default resolved after TARGET
CONF="$PLUGIN_ROOT/agents.conf"
TIMEOUT=1800
YES=0
LIST=0
CHECK=0
DRYRUN=0

usage() {
  cat <<'EOF'
run-agent.sh — dispatch ONE prompt to external coding agent CLIs
(agy / codex / claude) as autonomous sub-agents, then collect each response.

Usage:
  run-agent.sh --agent <agy|codex|claude|all> (--prompt "..." | --prompt-file F | --prompt-file -)
               [--target DIR] [--read-only | --write] [--model M] [--effort E]
               [--claude-perm MODE] [--timeout SECS] [--out DIR] [--conf FILE]
               [--list] [--check] [--dry-run] [-h | --help]

  --agent       agy | codex | claude | all  (all = every agent enabled in agents.conf)
  --prompt      the task/prompt (single argv element; never word-split)
  --prompt-file read the prompt from a file, or - for stdin
  --target DIR  directory the agents work in (default: cwd)
  --write       read-write mode: agents MAY edit files / run tools (DEFAULT)
  --read-only   agents observe and report, never mutate (the council's config)
  --model M     model override (else from agents.conf, else the cli default)
  --effort E    reasoning effort override (codex/claude; agy bakes it into the model)
  --claude-perm claude write-mode permission mode (default: acceptEdits)
  --timeout S   per-agent timeout in seconds (default: 1800)
  --out DIR     transcript dir (default: ~/.external-agents/logs/<project>)
  --conf FILE   agent defaults (default: <plugin>/agents.conf)
  --list        print the parsed agent config and exit
  --check       preflight: report whether each candidate CLI is on PATH; exit non-zero if any missing
  --dry-run     print each agent's resolved launch argv without running it
  --yes, -y     confirm a write run whose --target is not the current directory

SAFETY: in the default --write mode the agents can modify whatever is under --target.
Never point --target at private IP you would not ship to an external provider.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0;;
    --agent) AGENT="$2"; shift 2;;
    --prompt) PROMPT="$2"; shift 2;;
    --prompt-file) PROMPT_FILE="$2"; shift 2;;
    --target) TARGET="$2"; shift 2;;
    --read-only|--readonly)
      [ -n "$MODE_SET" ] && [ "$MODE" != "readonly" ] && { echo "run-agent: --read-only and --write are mutually exclusive" >&2; exit 2; }
      MODE="readonly"; MODE_SET=1; shift;;
    --write)
      [ -n "$MODE_SET" ] && [ "$MODE" != "write" ] && { echo "run-agent: --read-only and --write are mutually exclusive" >&2; exit 2; }
      MODE="write"; MODE_SET=1; shift;;
    --model) MODEL="$2"; shift 2;;
    --effort) EFFORT="$2"; shift 2;;
    --claude-perm) CLAUDE_PERM="$2"; shift 2;;
    --timeout) TIMEOUT="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --conf) CONF="$2"; shift 2;;
    --list) LIST=1; shift;;
    --check) CHECK=1; shift;;
    -y|--yes) YES=1; shift;;
    --dry-run) DRYRUN=1; shift;;
    *) echo "run-agent: unknown arg: $1" >&2; usage >&2; exit 2;;
  esac
done

trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

conf_model()  { local a="$1" i; for i in "${!AGENTS[@]}"; do [ "${AGENTS[$i]}" = "$a" ] && { printf '%s' "${CMODELS[$i]}"; return; }; done; }
conf_effort() { local a="$1" i; for i in "${!AGENTS[@]}"; do [ "${AGENTS[$i]}" = "$a" ] && { printf '%s' "${CEFFORTS[$i]}"; return; }; done; }
is_enabled()  { local a="$1" i; for i in "${!AGENTS[@]}"; do [ "${AGENTS[$i]}" = "$a" ] && return 0; done; return 1; }

# --- parse agents.conf  (lines: agent | model | effort ; '#' comments) -----------
# Duplicate agent lines are ignored (first wins) so `--agent all` never launches
# the same agent twice racing on one set of per-agent output files.
AGENTS=(); CMODELS=(); CEFFORTS=()
if [ -f "$CONF" ]; then
  while IFS='|' read -r c1 c2 c3 || [ -n "$c1" ]; do
    a="$(trim "$c1")"
    case "$a" in ""|\#*) continue;; esac
    is_enabled "$a" && continue
    AGENTS+=("$a"); CMODELS+=("$(trim "$c2")"); CEFFORTS+=("$(trim "$c3")")
  done < "$CONF"
fi

if [ "$LIST" = "1" ]; then
  echo "external-agents config ($CONF):"
  if [ "${#AGENTS[@]}" -eq 0 ]; then echo "  (no agents enabled)"; fi
  for i in "${!AGENTS[@]}"; do
    printf '  %-7s model=%-24s effort=%s\n' "${AGENTS[$i]}" "${CMODELS[$i]:-(cli default)}" "${CEFFORTS[$i]:-(cli default)}"
  done
  exit 0
fi

# Which agents will run?  'all' = every enabled agent; otherwise the named one.
RUN=()
if [ "$AGENT" = "all" ]; then
  RUN=("${AGENTS[@]}")
  [ "${#RUN[@]}" -gt 0 ] || { echo "run-agent: --agent all but no agents enabled in $CONF" >&2; exit 2; }
elif [ -n "$AGENT" ]; then
  case "$AGENT" in agy|codex|claude) RUN=("$AGENT");; *) echo "run-agent: unknown agent '$AGENT' (want agy|codex|claude|all)" >&2; exit 2;; esac
fi

if [ "$CHECK" = "1" ]; then
  # Preflight: is each candidate agent's CLI on PATH? Exit non-zero if any is missing.
  echo "external-agents preflight:"
  missing=0
  cand=("${RUN[@]}"); [ "${#cand[@]}" -eq 0 ] && cand=(agy codex claude)
  seen=""
  for a in "${cand[@]}"; do
    case ",$seen," in *",$a,"*) continue;; esac; seen="$seen,$a"
    if command -v "$a" >/dev/null 2>&1; then
      printf '  ok   %-7s %s\n' "$a" "$(command -v "$a")"
    else
      printf '  MISS %-7s not on PATH\n' "$a"; missing=$((missing + 1))
    fi
  done
  echo "external-agents: $missing missing"
  [ "$missing" -eq 0 ]; exit $?
fi

# --- validate the run request -----------------------------------------------------
[ -n "$AGENT" ] || { echo "run-agent: --agent is required (agy|codex|claude|all)" >&2; exit 2; }
[ -d "$TARGET" ] || { echo "run-agent: --target '$TARGET' is not a directory" >&2; exit 2; }
# Resolve physically (pwd -P) so symlinked targets/installs can't slip past the
# prefix checks below — the kernel resolves cd "$TARGET" physically at launch anyway.
TARGET="$(cd "$TARGET" && pwd -P)"
INVOKED_FROM="$(pwd -P)"

# Write-mode safety gates (skipped for --dry-run, which launches nothing).
if [ "$MODE" = "write" ] && [ "$DRYRUN" = "0" ]; then
  # 1. Keep writing agents out of the plugin's own tree, in BOTH directions:
  #    target inside the plugin, or target an ancestor that contains the plugin
  #    (e.g. the monorepo root, which would also expose every sibling repo).
  case "$TARGET/" in "$PLUGIN_ROOT/"*) echo "run-agent: refusing to write inside the plugin tree ($PLUGIN_ROOT). Use --target or --read-only." >&2; exit 2;; esac
  case "$PLUGIN_ROOT/" in "$TARGET/"*) echo "run-agent: refusing to write with --target '$TARGET' — it contains the plugin tree (and likely sibling repos). Narrow --target or use --read-only." >&2; exit 2;; esac
  # 2. A write target that isn't the directory you launched from is the classic
  #    foot-gun (wrong tree, monorepo root, private IP). Require an explicit --yes.
  if [ "$TARGET" != "$INVOKED_FROM" ] && [ "$YES" = "0" ]; then
    {
      echo "run-agent: write run on a non-cwd target needs confirmation."
      echo "  target : $TARGET"
      echo "  agents : ${RUN[*]}  (agy/codex ship this whole tree to EXTERNAL providers)"
      echo "  re-run with --yes once you've confirmed the scope, or use --read-only."
    } >&2
    exit 2
  fi
fi

# Resolve the prompt (literal --prompt, a file, or stdin via --prompt-file -).
if [ -n "$PROMPT_FILE" ]; then
  if [ "$PROMPT_FILE" = "-" ]; then PROMPT="$(cat)"; else
    [ -f "$PROMPT_FILE" ] || { echo "run-agent: --prompt-file '$PROMPT_FILE' not found" >&2; exit 2; }
    PROMPT="$(cat "$PROMPT_FILE")"
  fi
fi
[ -n "$PROMPT" ] || { echo "run-agent: empty prompt (pass --prompt or --prompt-file)" >&2; exit 2; }

# project id mirrors run-council.sh: a sub-dir of a repo nests under <repo>/<leaf>.
LEAF="$(basename "$TARGET")"
TOP="$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null || true)"
if   [ -n "$TOP" ] && [ "$TARGET" != "$TOP" ]; then PROJECT="$(basename "$TOP")/$LEAF"
elif [ -n "$TOP" ]; then PROJECT="$(basename "$TOP")"
else PROJECT="$LEAF"; fi
[ -z "$OUT" ] && OUT="${EXTERNAL_AGENTS_OUT:-$HOME/.external-agents/logs}/$PROJECT"
if [ "$DRYRUN" = "0" ]; then mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd -P)"; fi

# agy --sandbox is best-effort, NOT a hard write barrier (see header) — warn so a
# read-only run is never mistaken for an enforced guarantee.
if [ "$MODE" = "readonly" ]; then
  for a in "${RUN[@]}"; do [ "$a" = "agy" ] && { echo "run-agent: NOTE — agy read-only relies on --sandbox, which is best-effort and may still permit writes. For a hard guarantee use codex/claude, or target a throwaway copy." >&2; break; }; done
fi
# A write run with no git baseline has no diff/revert recovery path — warn.
if [ "$MODE" = "write" ] && [ "$DRYRUN" = "0" ] && [ -z "$TOP" ]; then
  echo "run-agent: NOTE — --target is not a git repo; no baseline to diff or revert after writes. Consider 'git init' or a backup first." >&2
fi

# --- build one agent's argv  (echoes resolved model/effort to stderr) -------------
build_argv() {  # agent ; sets global ARGV[]
  local a="$1" m e
  m="${MODEL:-$(conf_model "$a")}"
  e="${EFFORT:-$(conf_effort "$a")}"
  ARGV=()
  case "$a" in
    agy)
      ARGV=(agy -p "$PROMPT" --add-dir "$TARGET"); PROMPT_IDX=2
      [ "$MODE" = "readonly" ] && ARGV+=(--sandbox) || ARGV+=(--dangerously-skip-permissions)
      [ -n "$m" ] && ARGV+=(--model "$m");;
    codex)
      if [ "$MODE" = "readonly" ]; then ARGV=(codex exec -s read-only -C "$TARGET" --skip-git-repo-check)
      else ARGV=(codex exec -s workspace-write -C "$TARGET" --skip-git-repo-check); fi
      [ -n "$m" ] && ARGV+=(-m "$m")
      [ -n "$e" ] && ARGV+=(-c "model_reasoning_effort=\"$e\"")
      ARGV+=("$PROMPT"); PROMPT_IDX=$(( ${#ARGV[@]} - 1 ));;
    claude)
      if [ "$MODE" = "readonly" ]; then ARGV=(claude -p "$PROMPT" --allowedTools Read Grep Glob)
      else ARGV=(claude -p "$PROMPT" --permission-mode "$CLAUDE_PERM"); fi
      PROMPT_IDX=2
      [ -n "$m" ] && ARGV+=(--model "$m")
      [ -n "$e" ] && ARGV+=(--effort "$e");;
    *) echo "run-agent: unknown agent '$a'" >&2; return 1;;
  esac
  return 0
}

run_one() {  # agent  (cwd=TARGET) — stdout->$OUT/<a>.md, stderr->.err, rc/.sec
  local a="$1" t0 t1 rc
  build_argv "$a" || return 1
  t0=$(date +%s 2>/dev/null || echo 0)
  ( cd "$TARGET" && timeout "$TIMEOUT" "${ARGV[@]}" ) >"$OUT/$a.md" 2>"$OUT/$a.err"
  rc=$?
  t1=$(date +%s 2>/dev/null || echo 0)
  echo "$rc" >"$OUT/$a.rc"; echo "$((t1 - t0))" >"$OUT/$a.sec"
}

# --- dry-run: print resolved argv and exit ----------------------------------------
if [ "$DRYRUN" = "1" ]; then
  echo "external-agents dry-run  (mode=$MODE  target=$TARGET)"
  for a in "${RUN[@]}"; do
    build_argv "$a" || continue
    line=""
    for i in "${!ARGV[@]}"; do
      tok="${ARGV[$i]}"
      if [ "$i" = "$PROMPT_IDX" ]; then tok="<PROMPT>"
      else case "$tok" in *[[:space:]]*) tok="'$tok'";; esac
      fi
      line="$line $tok"
    done
    printf '  %-7s %s\n' "$a" "${line# }"
  done
  exit 0
fi

# --- run (parallel for 'all') -----------------------------------------------------
echo "external-agents: $AGENT on $PROJECT ($TARGET)  mode=$MODE  timeout=${TIMEOUT}s" >&2
PIDS=()
for a in "${RUN[@]}"; do
  printf '  -> %-7s model=%-22s effort=%s\n' "$a" "${MODEL:-$(conf_model "$a")}" "${EFFORT:-$(conf_effort "$a")}" >&2
  run_one "$a" & PIDS+=($!)
done
for p in "${PIDS[@]}"; do wait "$p"; done

# --- collect: echo every transcript to stdout, summarise to stderr ----------------
ok=0; fail=0
for a in "${RUN[@]}"; do
  rc="$(cat "$OUT/$a.rc" 2>/dev/null || echo '?')"
  sec="$(cat "$OUT/$a.sec" 2>/dev/null || echo '?')"
  bytes=$(wc -c <"$OUT/$a.md" 2>/dev/null | tr -d ' ')
  echo "===== $a (rc=$rc ${sec}s ${bytes:-0} bytes) ====="
  cat "$OUT/$a.md" 2>/dev/null
  if [ "$rc" != "0" ] || [ "${bytes:-0}" -lt 1 ]; then
    echo "----- $a stderr -----"; cat "$OUT/$a.err" 2>/dev/null
  fi
  echo
  if [ "$rc" = "0" ] && [ "${bytes:-0}" -gt 0 ]; then ok=$((ok+1)); else fail=$((fail+1)); fi
done
# After a write run, PRODUCE the verification (not just recommend it): show what
# actually changed in the target's git tree so the caller can inspect before trusting.
if [ "$MODE" = "write" ] && [ -n "$TOP" ]; then
  echo "===== git changes after write (in $TARGET) ====="
  git -C "$TARGET" status --porcelain 2>/dev/null
  git -C "$TARGET" --no-pager diff --stat 2>/dev/null
  echo
fi
echo "external-agents: $ok ok, $fail failed  (transcripts in $OUT)" >&2
[ "$fail" -eq 0 ]
