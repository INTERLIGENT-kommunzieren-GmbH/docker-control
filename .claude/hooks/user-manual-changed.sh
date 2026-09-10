#!/usr/bin/env bash
# PostToolUse hook: nudge Claude to rebuild USER-MANUAL.pdf right after the manual
# is edited. Silent (exit 0, no output) in every other case.
set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[ -n "$ROOT" ] || exit 0

payload="$(cat)"
# Cheap and dependency-free: did this tool call touch the manual at all?
grep -q 'USER-MANUAL\.md' <<<"$payload" || exit 0

MD="$ROOT/USER-MANUAL.md"
PDF="$ROOT/USER-MANUAL.pdf"
[ -f "$MD" ] || exit 0
# Already rebuilt (or untouched)? Nothing to say.
[ -f "$PDF" ] && [ ! "$MD" -nt "$PDF" ] && exit 0

cat <<'JSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "USER-MANUAL.md changed. Per the user-manual-pdf skill, USER-MANUAL.pdf must be regenerated in this same change: run .claude/skills/user-manual-pdf/build-pdf.sh and review the printed text diff before finishing."
  }
}
JSON
