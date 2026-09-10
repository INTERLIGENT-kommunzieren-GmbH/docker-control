---
name: user-manual-pdf
description: Rebuild USER-MANUAL.pdf from USER-MANUAL.md for this repo. Use whenever USER-MANUAL.md or CHANGELOG.md is edited, when asked to regenerate/refresh the user manual PDF, or to check whether the committed PDF is stale. Also covers the pandoc + WeasyPrint toolchain, the required flags, and how to verify no content was dropped.
allowed-tools: Bash, Read, Edit
---

# Rebuild the user manual PDF

`USER-MANUAL.pdf` is committed to the repo and is generated from `USER-MANUAL.md`.
It is **not** built by CI or by `build.sh` — it only stays current because it is
rebuilt as part of the change that touches the manual.

## Standing rule

**Any change that touches `USER-MANUAL.md` must rebuild `USER-MANUAL.pdf` in the same
change.** Don't wait to be asked and don't leave it for the user.

A `CHANGELOG.md` edit is a *signal*, not a trigger: the changelog is not part of the PDF,
but if the changelog moved, user-facing behaviour moved — read the manual, update it if it
is now wrong, and then rebuild.

## How to run it

```bash
.claude/skills/user-manual-pdf/build-pdf.sh           # rebuild in place
.claude/skills/user-manual-pdf/build-pdf.sh --check   # is the committed PDF stale? writes nothing
```

`--check` exits `0` when the PDF is current, `2` when it is stale (and prints the text
diff), `1` on a build error.

The plain build is safe to run at any time: it compares the freshly built PDF against the
committed one by extracted text and only overwrites when the content actually differs.

After a rebuild, **read the printed text diff**. Every `<` line that has no matching `>`
line must be explained by repagination (the same text reappears elsewhere in the diff) —
if a line genuinely disappeared, the markdown edit dropped content.

## What the script does, and why

- **Command:** `pandoc USER-MANUAL.md -o USER-MANUAL.pdf --pdf-engine=weasyprint -s -f markdown+gfm_auto_identifiers`
- **`+gfm_auto_identifiers` is required.** The "Table of contents" is hand-written in the
  markdown with GitHub-style anchors (`#1-installation`). Pandoc's default identifier
  algorithm strips the leading numbers and breaks every TOC link. Any `No anchor` line in
  pandoc's output means exactly that; the script treats it as a hard failure.
- **Do not add `--toc`.** The TOC lives in the markdown.
- **Toolchain:** a Python venv cached at `${XDG_CACHE_HOME:-$HOME/.cache}/docker-control/pdf-venv`,
  created on first run (~1 min) and reused afterwards. It must live outside the repo so it
  never shows up in `git status`. It holds `weasyprint`, plus `pypandoc_binary` as a
  fallback pandoc for hosts without one — note that bundled pandoc is **not** on the venv's
  `bin/` and has to be invoked at
  `pdf-venv/lib/python3.*/site-packages/pypandoc/files/pandoc`. The venv's `bin` is
  prepended to `PATH` so pandoc can find `weasyprint`.
- **Native deps:** WeasyPrint's wheel needs pango/cairo/gobject, already present on the
  Fedora dev host. `pdftotext`/`pdfinfo` (poppler) are used for the content diff and are
  installed system-wide.
- **Version drift is fine.** The committed PDF was produced with pandoc 3.9 / WeasyPrint
  69.0 and reproduces byte-for-byte in extracted text under pandoc 3.11 / WeasyPrint 70.0.
  Because the comparison is on extracted text, a cosmetic renderer change will not cause a
  spurious rewrite.

## Expected output

A clean build prints only these harmless CSS warnings from pandoc's default HTML template,
plus possibly a HarfBuzz emoji-font note:

```
text-rendering, @media (max-width: 600px), overflow-x, user-select
```

Anything else — especially `No anchor` — needs investigating before committing.

## Automation

Two hooks in `.claude/settings.json` back this up so it can't be forgotten:

- `PostToolUse` (`.claude/hooks/user-manual-changed.sh`) — after an edit to
  `USER-MANUAL.md`, injects a reminder to run this skill.
- `Stop` (`.claude/hooks/user-manual-pdf-guard.sh`) — refuses to end the turn while
  `USER-MANUAL.md` is newer than `USER-MANUAL.pdf`.

Both use mtime ordering as the cheap "needs rebuilding" signal, which is why the build
script `touch`es the PDF even when the rebuild turns out to be a no-op. mtime is only
trustworthy *within a working session* — to judge whether the **committed** PDF is stale
(e.g. after a fresh clone or a merge), use `--check`, which compares content.
