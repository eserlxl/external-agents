# Security Policy

## Supported versions

external-agents is a small, single-maintainer Claude Code plugin released from `main` under
semantic versioning. Only the **latest released version** (see
[`.claude-plugin/plugin.json`](.claude-plugin/plugin.json)) receives security fixes; older tags are
not maintained. Upgrade to the latest version before reporting.

## Reporting a vulnerability

Please report security issues **privately** — do not open a public issue for an unfixed
vulnerability:

- Preferred: open a
  [GitHub private security advisory](https://github.com/eserlxl/external-agents/security/advisories/new).
- Or email the maintainer at **eserlxl@gmail.com** with `external-agents security` in the subject.

Include the affected version, a description, and (where possible) a minimal reproduction. Please
allow a fix to ship before public disclosure.

## Scope and posture

The plugin runs external coding-agent CLIs as sub-agents and can edit a target tree and ship it to
third-party providers. See [docs/threat-model.md](docs/threat-model.md) for the trust boundaries,
protected assets, and the driver's mitigating controls. Note in particular that **agy read-only is
best-effort** and that **transcript redaction is best-effort, not a guarantee** of total secret
removal.

## Review cadence

The threat model and the per-CLI enforcement matrix are re-reviewed on each feature release and at
least every six months, whichever comes first, so the posture above cannot silently go stale. Between
reviews the **enforcement-matrix doc-drift guard** in `tests/run.sh` fails the offline suite if the
published matrix in [docs/threat-model.md](docs/threat-model.md) diverges from the driver's actual
read-only argv, keeping the mechanical claims honest.

- **Last reviewed:** 2026-06-21 (v0.9.0)
- **Next review due:** by 2026-12-21, or at the next feature release — whichever comes first.
