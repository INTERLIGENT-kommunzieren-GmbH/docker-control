#!/usr/bin/env bash
# Rebuild USER-MANUAL.pdf from USER-MANUAL.md.
#
#   build-pdf.sh            rebuild in place (default)
#   build-pdf.sh --check    report whether the committed PDF is stale; write nothing
#                           exit 0 = up to date, 2 = stale, 1 = build error
#
# See SKILL.md in this directory for why each flag is what it is.
set -euo pipefail

MODE="${1:-build}"
case "$MODE" in
  build|--build) MODE=build ;;
  --check) MODE=check ;;
  *) echo "usage: $0 [--check]" >&2; exit 64 ;;
esac

ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
MD="$ROOT/USER-MANUAL.md"
PDF="$ROOT/USER-MANUAL.pdf"
[ -f "$MD" ] || { echo "error: $MD not found" >&2; exit 1; }

# The venv lives outside the repo on purpose: it must never show up in `git status`.
# It is cached between sessions, so the ~1 min install happens only once per machine.
VENV="${XDG_CACHE_HOME:-$HOME/.cache}/docker-control/pdf-venv"
if [ ! -x "$VENV/bin/weasyprint" ]; then
  echo "==> creating PDF toolchain venv at $VENV (one-off, ~1 min)"
  python3 -m venv "$VENV"
  # pypandoc_binary bundles a pandoc for hosts that don't have one; harmless if unused.
  "$VENV/bin/pip" install --quiet --upgrade pip
  "$VENV/bin/pip" install --quiet weasyprint pypandoc_binary
fi
export PATH="$VENV/bin:$PATH"   # pandoc must be able to find weasyprint

# Prefer a real pandoc on PATH; otherwise use the one pypandoc_binary vendored,
# which is NOT placed on the venv's bin/ and has to be invoked by full path.
PANDOC="$(command -v pandoc || true)"
if [ -z "$PANDOC" ]; then
  PANDOC="$(echo "$VENV"/lib/python3*/site-packages/pypandoc/files/pandoc)"
fi
[ -x "$PANDOC" ] || { echo "error: no pandoc available (looked for $PANDOC)" >&2; exit 1; }

TMPDIR_BUILD="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BUILD"' EXIT
OUT="$TMPDIR_BUILD/USER-MANUAL.pdf"
LOG="$TMPDIR_BUILD/pandoc.log"

echo "==> $("$PANDOC" --version | head -1) + $(weasyprint --version 2>&1 | head -1)"
"$PANDOC" "$MD" -o "$OUT" \
  --pdf-engine=weasyprint \
  -s \
  -f markdown+gfm_auto_identifiers 2> >(tee "$LOG" >&2)

# `No anchor` means the TOC links broke — that is a hard failure, not a warning.
if grep -q "No anchor" "$LOG"; then
  echo "error: pandoc reported broken TOC anchors (see above)" >&2
  exit 1
fi

# Content diff, not mtime: the PDF embeds a build timestamp, so bytes always differ.
STALE=0
if [ -f "$PDF" ]; then
  pdftotext -layout "$PDF" "$TMPDIR_BUILD/old.txt"
  pdftotext -layout "$OUT" "$TMPDIR_BUILD/new.txt"
  if ! diff -q "$TMPDIR_BUILD/old.txt" "$TMPDIR_BUILD/new.txt" >/dev/null; then
    STALE=1
  fi
else
  STALE=1
fi

if [ "$MODE" = check ]; then
  if [ "$STALE" -eq 1 ]; then
    echo "STALE: USER-MANUAL.pdf does not match USER-MANUAL.md"
    diff "$TMPDIR_BUILD/old.txt" "$TMPDIR_BUILD/new.txt" | head -60 || true
    exit 2
  fi
  echo "OK: USER-MANUAL.pdf is up to date"
  exit 0
fi

if [ "$STALE" -eq 0 ]; then
  # Touch so the PDF is never older than the markdown: the hooks use that mtime
  # ordering as their cheap "needs a rebuild" signal, and a no-op build that left
  # the PDF older would make them fire forever.
  touch "$PDF"
  echo "OK: USER-MANUAL.pdf already matches USER-MANUAL.md — nothing written"
  exit 0
fi

# Show what changed so a dropped section can't slip through as "repagination".
if [ -f "$TMPDIR_BUILD/old.txt" ]; then
  echo "==> text diff (old -> new):"
  diff "$TMPDIR_BUILD/old.txt" "$TMPDIR_BUILD/new.txt" | head -80 || true
fi
mv "$OUT" "$PDF"
echo "==> wrote $PDF"
