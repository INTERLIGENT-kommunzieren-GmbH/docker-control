#!/usr/bin/env bash
# Stop hook: don't let a turn end with USER-MANUAL.md edited but USER-MANUAL.pdf
# not rebuilt. Terminates because build-pdf.sh always leaves the PDF newer than
# the markdown -- including when the rebuild is a content no-op.
set -uo pipefail

payload="$(cat)"
# Never block twice in a row; that is how a Stop hook turns into a loop.
grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true' <<<"$payload" && exit 0

ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null)}"
[ -n "$ROOT" ] || exit 0
MD="$ROOT/USER-MANUAL.md"
PDF="$ROOT/USER-MANUAL.pdf"
[ -f "$MD" ] || exit 0
[ -f "$PDF" ] && [ ! "$MD" -nt "$PDF" ] && exit 0

cat <<'JSON'
{
  "decision": "block",
  "reason": "USER-MANUAL.pdf is older than USER-MANUAL.md. Use the user-manual-pdf skill: run .claude/skills/user-manual-pdf/build-pdf.sh, review the text diff it prints, then finish."
}
JSON
