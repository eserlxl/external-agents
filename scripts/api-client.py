#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Eser KUBALI
# SPDX-License-Identifier: GPL-3.0-or-later
#
# external-agents/scripts/api-client.py — drive a CLOUD API model as a READ-ONLY
# advisor. Unlike the agentic CLIs (agy/codex/claude/cursor), a raw completion
# endpoint has no filesystem access, so this is a hard read-only call: it sends the
# prompt (assembled by the caller, e.g. a council/conclave panel, WITH whatever repo
# context it wants) and prints the model's text answer to stdout. It never reads,
# writes, or executes anything in the working tree.
#
# Stdlib only (urllib + json) — no pip installs, matching the driver's dependency
# discipline. Invoked by scripts/run-agent.sh's argv_api builder as:
#
#     python3 api-client.py --provider <p> --model M [--effort E] --prompt P
#
# Providers (--provider): anthropic | openai | gemini | openrouter.
#
# API KEY RESOLUTION (per provider, secure-by-preference):
#   Each provider has a standard env var that names a `pass` ENTRY (not the raw key):
#       anthropic  -> ANTHROPIC_API_KEY
#       openai     -> OPENAI_API_KEY
#       gemini     -> GEMINI_API_KEY, else GOOGLE_API_KEY
#       openrouter -> OPENROUTER_API_KEY
#   - If `pass` is on PATH (and EXTERNAL_AGENTS_NO_PASS is unset): the env var's value
#     is treated as a `pass` entry name and the key is read via `pass show <entry>`
#     (first line). The secret therefore never appears in argv — only the entry name,
#     which is not sensitive.
#   - If `pass` is NOT installed (e.g. CI), or EXTERNAL_AGENTS_NO_PASS=1: the env var's
#     value is used as the literal key.
#   - Missing / unresolvable -> an `authentication failed`-shaped error (exit 4) so the
#     driver's error taxonomy classifies it as `auth`. No network call is made.
# The resolved key is sent only in the request header — never printed, logged, or placed
# in argv.
import argparse
import json
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.request

# Per-provider standard env var(s); the FIRST set one holds the `pass` entry (or literal key).
KEY_ENVS = {
    "anthropic": ["ANTHROPIC_API_KEY"],
    "openai": ["OPENAI_API_KEY"],
    "gemini": ["GEMINI_API_KEY", "GOOGLE_API_KEY"],
    "openrouter": ["OPENROUTER_API_KEY"],
}


def _truthy(v):
    return str(v).strip().lower() not in ("", "0", "false", "no", "off")


def fail(msg, code):
    """Print a classifier-shaped message to stderr and exit. The wording is chosen so
    scripts/run-agent.sh's classify_outcome maps it to the right error class:
      code 4 -> 'authentication failed' / 'unauthorized' -> auth
      code 5 -> 'rate limit' / 'service unavailable'      -> transient
      code 3 -> anything else                             -> unknown (conservative)."""
    sys.stderr.write(msg.rstrip("\n") + "\n")
    sys.exit(code)


def resolve_key(provider):
    """Resolve the API key. The env var holds a `pass` entry name by default; falls back
    to a literal value only when `pass` is unavailable or explicitly disabled. Never
    returns or logs the secret beyond the caller using it as a header."""
    envs = KEY_ENVS[provider]
    ref = None
    for name in envs:
        val = os.environ.get(name)
        if val:
            ref = val
            break
    if ref is None:
        fail(
            "authentication failed: no API key for %s "
            "(set %s to a `pass` entry name, or to the literal key if `pass` is not installed)"
            % (provider, " / ".join(envs)),
            4,
        )
    use_pass = (not _truthy(os.environ.get("EXTERNAL_AGENTS_NO_PASS", ""))) and bool(
        shutil.which("pass")
    )
    if not use_pass:
        return ref  # literal key (pass absent or EXTERNAL_AGENTS_NO_PASS=1)
    try:
        # `ref` is the entry NAME (not a secret); safe to pass as an argv element to `pass`.
        out = subprocess.run(
            ["pass", "show", ref],
            capture_output=True,
            text=True,
            timeout=30,
        )
    except Exception as e:  # pass missing mid-run, timeout, etc.
        fail("authentication failed: `pass show` for %s errored (%s)" % (provider, e), 4)
    if out.returncode != 0:
        fail(
            "authentication failed: `pass show %s` failed for %s "
            "(entry missing or the password store is locked)" % (ref, provider),
            4,
        )
    for line in out.stdout.splitlines():
        if line.strip():
            return line  # first non-empty line is the secret, by `pass` convention
    fail("authentication failed: `pass show %s` returned no secret for %s" % (ref, provider), 4)


def http_post(url, headers, body, timeout):
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = e.read().decode("utf-8", "replace")[:600]
        except Exception:
            pass
        code = e.code
        if code in (401, 403):
            fail("authentication failed (HTTP %d): %s" % (code, detail), 4)
        if code == 429 or code >= 500:
            fail("service unavailable / rate limit (HTTP %d): %s" % (code, detail), 5)
        fail("HTTP %d error: %s" % (code, detail), 3)
    except urllib.error.URLError as e:
        fail("network error: %s" % (e.reason,), 5)
    except Exception as e:
        fail("request error: %s" % (e,), 3)


def run_anthropic(model, effort, prompt, max_tokens, timeout):
    key = resolve_key("anthropic")
    body = {
        "model": model,
        "max_tokens": max_tokens,
        "messages": [{"role": "user", "content": prompt}],
    }
    if effort:
        # output_config.effort controls reasoning depth on Opus 4.5+/Sonnet 4.6; deepen
        # the reasoning tiers with adaptive thinking (off by default on Opus 4.7+).
        body["output_config"] = {"effort": effort}
        if effort in ("high", "xhigh", "max"):
            body["thinking"] = {"type": "adaptive"}
    out = http_post(
        "https://api.anthropic.com/v1/messages",
        {
            "content-type": "application/json",
            "x-api-key": key,
            "anthropic-version": "2023-06-01",
        },
        body,
        timeout,
    )
    if out.get("stop_reason") == "refusal":
        det = out.get("stop_details") or {}
        return "[model refused: %s]" % (det.get("category") or "safety")
    parts = [b.get("text", "") for b in out.get("content", []) if b.get("type") == "text"]
    return "".join(parts)


def _openai_chat(url, key, model, effort, prompt, max_tokens, timeout, extra_headers=None):
    headers = {"content-type": "application/json", "authorization": "Bearer " + key}
    if extra_headers:
        headers.update(extra_headers)
    body = {"model": model, "messages": [{"role": "user", "content": prompt}]}
    if effort:
        # gpt-5.x reasoning effort, passed through verbatim — codex exposes low|medium|high|xhigh for
        # gpt-5.5 (model_reasoning_effort), so xhigh is a real value here, not clamped.
        body["reasoning_effort"] = effort
    if max_tokens:
        body["max_completion_tokens"] = max_tokens
    out = http_post(url, headers, body, timeout)
    choices = out.get("choices") or []
    if not choices:
        return ""
    msg = choices[0].get("message") or {}
    return msg.get("content") or ""


def run_openai(model, effort, prompt, max_tokens, timeout):
    key = resolve_key("openai")
    return _openai_chat(
        "https://api.openai.com/v1/chat/completions", key, model, effort, prompt, max_tokens, timeout
    )


def run_openrouter(model, effort, prompt, max_tokens, timeout):
    key = resolve_key("openrouter")
    return _openai_chat(
        "https://openrouter.ai/api/v1/chat/completions",
        key,
        model,
        effort,
        prompt,
        max_tokens,
        timeout,
        extra_headers={"x-title": "external-agents"},
    )


def run_gemini(model, effort, prompt, max_tokens, timeout):
    # Gemini has no portable "effort" knob — effort is accepted but ignored here.
    key = resolve_key("gemini")
    body = {"contents": [{"parts": [{"text": prompt}]}]}
    if max_tokens:
        body["generationConfig"] = {"maxOutputTokens": max_tokens}
    out = http_post(
        "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent" % model,
        {"content-type": "application/json", "x-goog-api-key": key},
        body,
        timeout,
    )
    cands = out.get("candidates") or []
    if not cands:
        fb = out.get("promptFeedback") or {}
        return "[blocked: %s]" % (fb.get("blockReason") or "no candidates")
    content = cands[0].get("content") or {}
    parts = content.get("parts") or []
    return "".join(p.get("text", "") for p in parts)


PROVIDERS = {
    "anthropic": run_anthropic,
    "openai": run_openai,
    "gemini": run_gemini,
    "openrouter": run_openrouter,
}


def main(argv=None):
    ap = argparse.ArgumentParser(description="Drive a cloud API model as a read-only advisor.")
    ap.add_argument("--provider", required=True, choices=sorted(PROVIDERS))
    ap.add_argument("--model", default="")
    ap.add_argument("--effort", default="")
    ap.add_argument("--prompt", default=None)
    ap.add_argument("--prompt-file", default=None, help="read the prompt from a file, or - for stdin")
    ap.add_argument("--max-tokens", type=int, default=8192)
    ap.add_argument("--timeout", type=float, default=600.0)
    args = ap.parse_args(argv)

    prompt = args.prompt
    if args.prompt_file is not None:
        prompt = sys.stdin.read() if args.prompt_file == "-" else open(args.prompt_file).read()
    if not prompt:
        fail("empty prompt (pass --prompt or --prompt-file)", 2)
    if not args.model:
        fail("no model for provider %s (set the tier's model in agents.json)" % args.provider, 2)

    text = PROVIDERS[args.provider](args.model, args.effort, prompt, args.max_tokens, args.timeout)
    if not text:
        fail("contract: %s returned an empty response" % args.provider, 3)
    sys.stdout.write(text if text.endswith("\n") else text + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
