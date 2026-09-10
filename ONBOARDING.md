# ONBOARDING.md

For developers who will maintain and extend `docker-control` itself.

This is the "how do I work on this thing" document: environment, dev loop, where code
lives, the recipes for the changes you are most likely to make, and the traps that have
already cost someone a day.

Two neighbouring documents, so you know when to leave this one:

- **[AGENTS.md](AGENTS.md)** — the architecture reference and the *why* behind the
  load-bearing decisions (template state, ingress fingerprinting, Composer/ACL behaviour,
  argv parsing). It is written for coding agents but is the best prose on the design.
  Read it once end to end before your first non-trivial change.
- **[USER-MANUAL.md](USER-MANUAL.md)** — what the tool does from the outside. When you
  change behaviour, this is one of the files you must update.

---

## 1. What you are maintaining

`docker-control` is a Rust 2024 CLI that manages Docker-based PHP/LAMP projects end to
end: scaffolds a project from an embedded template, runs its compose stack locally, wires
a shared reverse proxy (*ingress*) and SSH agent forwarding, cuts releases via git
worktrees, and deploys tagged releases to remote servers over SSH.

It is a **single binary** (`docker-control`, aliased `dc2` in the Homebrew distribution)
that mostly orchestrates other programs: `docker compose`, `git`, `composer` (inside a
container), `ssh`/`scp`, `7z`, `setfacl`. Very little happens in-process — which shapes
everything about how it is written and tested.

It also still implements the Docker CLI plugin protocol — the hidden
`docker-cli-plugin-metadata` subcommand — so a copy placed in `~/.docker/cli-plugins/`
answers to `docker control <cmd>`. Nothing in the repo installs it there, and the user
manual now documents only the standalone and `dc2` forms, while `README.md` and
`template/CLAUDE.md` still describe the plugin form. Worth knowing before you "clean up"
either the metadata subcommand or those docs.

Three consequences worth internalising on day one:

1. **Shelling out is the norm.** `docker/mod.rs` wraps `docker compose` with
   `std::process::Command`; `bollard` (the Docker API crate) is used only for read-only
   container introspection. If you find yourself reaching for a Docker API call to *do*
   something, check whether the compose path already exists.
2. **The tool must be safe to run on someone's live project.** Almost every destructive
   step is behind a confirmation, a `--yes`, a `--dry-run`, a backup folder, or a
   rollback. Keep that property; it is why `update`, `module`, and `deploy` are as long as
   they are.
3. **The state lives on disk, in the user's project** — sentinel files, `state.json`,
   Composer `repositories` entries, an ingress stamp. There is no database and no server.
   Most bugs in this codebase are "we read state that meant something else".

---

## 2. Prerequisites

| Need | Notes |
|---|---|
| Rust stable, edition 2024 | Known-good: `rustc`/`cargo` 1.97. No `rust-toolchain.toml`, CI uses `stable`. |
| `cargo-nextest` | **Required** for the test suite: `cargo install cargo-nextest`. See §6 for why `cargo test` is not equivalent. |
| Docker + Docker Compose ≥ 2.4 | A running daemon. Some integration tests really do run containers. |
| `git`, `ssh`, `scp`, `bash` | Hard dependencies of the tool at runtime. |
| `7z` (`p7zip`), `rsync`, `setfacl`/`getfacl` (`acl`, Linux), `certutil` (`nss`) | Optional at runtime, needed for deploy / migrate / ACL / `trust-ca` work. |
| Homebrew | Only if you touch `upgrade`, `install-deps`, or the distribution path. |
| `pandoc` + poppler (`pdftotext`) | Only to rebuild `USER-MANUAL.pdf`; WeasyPrint comes from a cached venv the build script creates. |

The runtime dependency table with minimum versions and the "which Homebrew formula
provides this" reasoning is in `src/utils/dependencies.rs` — that file is the source of
truth, and the reason each `brew_formula` is `Some`/`None` is commented there. Don't
change one without reading the comment above it.

```bash
git clone git@github.com:INTERLIGENT-kommunzieren-GmbH/docker-control.git
cd docker-control
cargo build
cargo nextest run
```

---

## 3. The dev loop

```bash
cargo build                        # debug build → target/debug/docker-control
cargo build --release              # release build
cargo run -- <args>                # e.g. cargo run -- --dir /tmp/scratch status
cargo nextest run                  # whole suite (not cargo test)
cargo nextest run <substring>      # one test by name substring
cargo clippy                       # must be clean; CI runs it with -D warnings
cargo fmt                          # must be applied; CI runs cargo fmt --check
cargo fix --allow-dirty            # auto-fix what clippy can
./build.sh                         # host-target release build + assets into dist/
```

CI (`.github/workflows/tests.yml`, on push/PR to `main`) is exactly: `cargo fmt --check`,
`cargo clippy -- -D warnings`, `cargo nextest run --all-features --profile default`. Run
those three before pushing and you will not be surprised.

### Running your build against a real project

The tool acts on the **current directory** unless given `--dir`. Since your cwd is the
repo, always pass `--dir` when experimenting — otherwise you scaffold a PHP project on
top of the source tree. (The repo root already carries a few stray empty, untracked
`build/`, `config/`, `control-scripts/`, `secrets/` directories that look like the
residue of exactly that; they are harmless and safe to delete.)

```bash
mkdir -p /tmp/scratch
cargo run -- --dir /tmp/scratch init      # interactive: project name, PHP version, optional htdocs clone
cargo run -- --dir /tmp/scratch start
cargo run -- --dir /tmp/scratch status
```

`init` asks for confirmation in a non-empty directory, and is a no-op in one that is
already managed.

### Environment variables that make development bearable

| Variable | Why you want it |
|---|---|
| `DOCKER_CONTROL_SKIP_SSH_AGENT=1` | Stops the run from spawning/daemonising the SSH agent on port 2222 — and with it the `docker info` in `detect_platform()`. |
| `DOCKER_CONTROL_SKIP_DEPENDENCY_CHECK=1` | Skips the external-tool probe at startup (`docker --version`, `git`, `ssh`, …). |
| `DOCKER_CONTROL_SKIP_IMAGE_CHECK=1` | No "your images are outdated" registry round-trip on `start`/`restart`. |
| `DOCKER_CONTROL_SKIP_SELF_UPDATE_CHECK=1` | No weekly `brew` self-update probe. |
| `DOCKER_CONTROL_TEMPLATE_DIR=$PWD/template` | Use the working-copy template instead of the extracted one — see §5.2. |
| `DOCKER_CONTROL_INGRESS_DIR=$PWD/ingress` | Same for the ingress stack. |
| `--debug` | Global flag; enables `ui::debug` output on stderr. |

The full user-facing list (including `HOMEBREW_PREFIX`, `SSH_AUTH_PORT`, `PHP_VERSION`)
is in §13 of the user manual.

A convenient shell function while iterating:

```bash
dcdev() { DOCKER_CONTROL_SKIP_SSH_AGENT=1 DOCKER_CONTROL_SKIP_IMAGE_CHECK=1 \
          DOCKER_CONTROL_SKIP_SELF_UPDATE_CHECK=1 \
          DOCKER_CONTROL_TEMPLATE_DIR="$PWD/template" \
          cargo run -q -- --dir /tmp/scratch "$@"; }
```

---

## 4. Repo map

```
src/
  main.rs              clap `Cli`/`Commands`, pre-clap argv handling, dispatch, the
                       "notice" helpers (template drift, stale ingress, self-upgrade,
                       image pull)
  lib.rs               module list + SSH_AGENT_PORT; everything is behind this lib so
                       tests/ can call it
  commands/            one file per subcommand, each exposing `execute(...)`
  docker/mod.rs        `docker compose` wrapper, `console`/`console_exec`,
                       `exec_as_user`/`exec_as_root`, image freshness, ingress compose
  docker/ingress_state.rs  content fingerprint + stamp of what the running proxy started from
  git/mod.rs           `GitService` over git2: branches, tags, worktrees, cherry-pick, push
  git/known_hosts.rs   trust-on-first-use host-key verification for git2
  config/mod.rs        `.deploy.json` load/save; search order htdocs/.docker-control → root
  assets/mod.rs        `template/` + `ingress/` + the manual PDF embedded via include_dir,
                       extracted to the OS config dir
  template/mod.rs      template sync state (`.docker-control/state.json`), three-way diff
  ui/mod.rs            info/warning/critical/success/debug — all user output goes here
  utils/               platform detection, SSH forwarding, dependency checks, ACL,
                       sudo, throttle cache, `is_managed()`, PhpStorm .idea helpers
template/              the project skeleton shipped inside the binary (compose.yml,
                       config/, secrets/, .env-dist, its own CLAUDE.md for generated projects)
ingress/               the shared nginx-proxy compose stack, also shipped in the binary
tests/                 integration tests; tests/common/mod.rs has the TestRepo fixture
docs/                  design plans, frozen once implemented — history, not spec
examples/              sample .deploy.json files, Rhai deploy hooks, a module workflow demo
.claude/               committed: the user-manual-pdf skill + the two hooks that enforce it
```

Not part of the source you maintain: `old_template/` (untracked local reference copy of
the pre-Rust bash tool), `dist/`, `target/`, `.zencoder/`.

`CODE_REVIEW_FINDINGS.md` is a 2026-07 full-project review; 5 of 7 findings are fixed and
marked as such. **Finding #1 (path traversal via a `--release` value into the remote
deploy path) is still open** — worth knowing before you touch `deploy.rs`.

---

## 5. The mental model — six things to know before changing code

AGENTS.md has the full rationale for each. This is the orientation.

### 5.1 Managed projects and the project layout

Most commands require a `.managed-by-docker-control` (or
`.managed-by-docker-control-plugin`) sentinel in the project directory; `utils::is_managed()`
checks it and `check_managed()` in `main.rs` exits with a message.

The expected layout, which a lot of code assumes:

```
<project>/                     ← the wrapper repo; compose.yml, .env, secrets/, volumes/
  .docker-control/state.json   ← docker-control's own state for THIS project
  htdocs/                      ← the PHP app: a SEPARATE git repo, mounted at /var/www/html
    .docker-control/           ← app-level config: .deploy.json, control-scripts/,
                                 deployment-scripts/
    vendor/<vendor>/<name>/    ← Composer installs (source installs are real git clones)
    modules/<vendor>/<name>/   ← development checkouts made by `module link`/`create`
```

The two same-named `.docker-control` directories are a genuine trip hazard: one is the
tool's state for the wrapper project, the other is app-level config inside the app repo.

`./htdocs:/var/www/html` is the **only** application mount, which is why development
module checkouts have to live under `htdocs/` — anywhere else is invisible to the
in-container Composer.

### 5.2 Assets are compiled into the binary

`template/` and `ingress/` (and `USER-MANUAL.pdf`) are embedded with `include_dir!` and
extracted to the OS config dir (`~/.config/docker-control` on Linux,
`~/Library/Application Support/com.interligent.docker-control` on macOS) on first run.

**The extraction is gated on the version string**, not on content:
`AssetManager::ensure_assets` compares `CARGO_PKG_VERSION` against a `.version` file and
does nothing if they match. So if you edit `template/` and rebuild without bumping the
version, your dev build keeps using the *previously extracted* copy. Either export
`DOCKER_CONTROL_TEMPLATE_DIR=$PWD/template` (what `template::resolve_dir()` checks first)
or delete `~/.config/docker-control/.version`.

Resolution order differs by concern, and one command is inconsistent:

- `template::resolve_dir()` — env override → `AssetManager` → relative to the binary →
  `./template` from a source checkout. Used by `init`, `update`, `status`, and the drift
  notice.
- `docker::find_ingress_dir()` — `DOCKER_CONTROL_INGRESS_DIR` → `AssetManager` →
  relative to the binary.
- `commands/migrate.rs` calls `AssetManager::get_template_dir()` **directly**, so it
  ignores `DOCKER_CONTROL_TEMPLATE_DIR`. Keep it in mind if you are testing `migrate`
  against an edited template; unifying it would be a reasonable small cleanup.

An installed layout (`…/bin/docker-control` with `…/share/docker-control/`) skips
extraction entirely and reads `share/` in place.

### 5.3 Template sync is a three-way merge, not a version check

`init`/`update`/`migrate` record the *template's* file hashes in
`<project>/.docker-control/state.json` — deliberately **not** git-ignored, so the merge
base travels with the project to other clones. That recorded manifest is the merge
**base**, so
`base` vs `theirs` (template now) vs `mine` (project now) classifies each file exactly:
unchanged upstream → silent no matter what the user edited; changed upstream only → apply
silently; changed on both sides → prompt (keep mine / take theirs / diff / write
`*.dist`).

Version numbers are deliberately *not* the trigger — the template moves in roughly one
release in five, so a version bump says nothing. `template_fingerprint` over the whole
manifest is the fast path that keeps the check cheap enough to run on every `start`.

Special cases you will break if you don't know them: `.env-dist`/`.gitignore-dist` are
excluded from hashing (their project copy gets renamed, so "missing" is ambiguous) and
compared by content against `.env`/`.gitignore` instead; `secrets/*.txt` and
`config/htpasswd` are seeded once and never compared.

### 5.4 The ingress is fingerprinted, not versioned

The shared proxy is a separate compose stack. Its containers bind-mount
`$HOMEBREW_PREFIX/etc/docker-control/ingress/volumes/...` — never the keg — so a
`brew upgrade` leaves a running proxy serving the *old* config. `ingress_state` therefore
stamps a **content** fingerprint at every `up`, and `start`/`restart`/`status`/
`status-ingress` offer to cycle a proxy whose stamp no longer matches. A missing or
unparseable stamp means "unknown", never "stale" — otherwise it would nag forever.

Read the ingress section of AGENTS.md before changing any of this: it documents why none
of it can live in the Homebrew formula, why `upgrade` starts the proxy by spawning the
*newly installed* binary, and why `ensure_ingress_volumes` creates its target directory
even with nothing to copy (Docker would otherwise auto-create the bind-mount source as
root and lock every later run out).

### 5.5 argv parsing has rules that predate clap

Several startup steps scan raw `args` before clap runs (SSH-agent flags, `--dir`,
`--debug`, the metadata probe, the dependency-check skip list). They must scan
`commands::custom::args_before_separator(&args)`, **never** the full argv: everything
after a standalone `--` belongs to the command that `console -- <cmd>` runs in the
container, or to a custom script. A whole-argv scan silently steals those tokens —
`console -- php --version` used to print docker-control's version.

`--version`/`-V` is narrower still: it counts only as the *leading* token (via
`split_leading_subcommand`, like `is_help`), because anywhere later it is a subcommand's
own argument (`module link <m> --version <v>`).

Custom commands are shell scripts in `control-scripts/` or
`htdocs/.docker-control/control-scripts/`, dispatched via clap's `external_subcommand`.
A script whose name clashes with a built-in is resolved *before* clap validates the
built-in's argument schema, so a strict built-in can't block the clash prompt. Scripts
opt into always winning with an `_override_` block, describe themselves with `_desc_`,
and provide their own help with `_help_`.

### 5.6 Composer, containers, and `COMPOSER_HOME`

`/var/www/.bashrc` sets `COMPOSER_HOME`, and `.bashrc` is only read by *interactive*
shells. So it applies to `console` but **not** to a non-interactive
`docker compose exec`, where the fallback is image-tag dependent — and only
`/var/www/.composer` has the private repositories mounted in. Every `exec`-based Composer
call must pass `-e COMPOSER_HOME=/var/www/.composer`; see `docker::exec_as_user`, and
`console_exec_flags` in `docker/mod.rs` for the same reason applied to
`console -- <cmd>`.

Related hard rule: **editing a project's `composer.json` is done with `composer config`,
never `serde_json`** — serialising it back would reflow the whole file and produce a
monstrous diff in the user's app repo. The single exception is a `composer.json` we
generated ourselves seconds earlier (`module create`'s own module manifest).

`console` (interactive `bash`) and `console_exec` (`console -- <cmd>`) are deliberately
separate: the one-shot path re-states as flags what the interactive shell gets from the
image (`-u www-data`, `-w /var/www/html`, `COMPOSER_HOME`) and returns **the container
command's exit code** for `main` to `process::exit` with, rather than an `anyhow::Result`
that would print an `Error:` line over a failure the inner command already reported. It
is the one intentional exception to the "commands return `anyhow::Result<()>`" rule.

---

## 6. Testing

Unit tests live beside the code (`#[cfg(test)] mod tests`), integration tests in `tests/`.
Both run under **`cargo-nextest`**, which is not optional: nextest runs each test in its
own process, and some tests mutate process-global state (e.g.
`utils::acl::current_username_prefers_user_env` calls `std::env::set_var`). Under
`cargo test`'s shared-process, multi-threaded harness those are racy.

`.config/nextest.toml` sets `retries = 2` and a 60s slow-timeout — the retries exist
because the Docker-backed tests are genuinely flaky, not to paper over logic bugs.

There are three distinct test seams; pick the one that matches what you are changing.

**1. Trait-object prompt providers (preferred).** Interactive `inquire` calls are behind
traits — `PromptProvider` (release), `MergePromptProvider`, `ModulePromptProvider`,
`UpdatePromptProvider` + `ConflictPrompt`, `ClashPromptProvider`,
`UpgradePromptProvider` — each with an `Interactive…` impl used in production and a
canned mock in tests. The command's `execute()` takes an `Options` struct
(`ModuleOptions`, `MergeOptions`, `ReleaseOptions`, `UpdateOptions`) whose `Default`
wires the interactive provider. `ModuleOptions` also carries `skip_composer`, which lets
the module tests assert filesystem side effects without running Composer in a container.
New interactive command? Follow this shape.

**2. Subprocess + fake binaries on `PATH`.** `tests/deploy_integration_tests.rs` builds
executable `ssh`/`scp`/`7z`/`docker` shims that log their argv to a file, spawns the real
binary via `env!("CARGO_BIN_EXE_docker-control")` with `PATH` prepended and
`DOCKER_CONTROL_SKIP_SSH_AGENT`/`DOCKER_CONTROL_SKIP_DEPENDENCY_CHECK` set, and asserts on
the logged command lines. Use this when the thing under test *is* the exact command line
sent to a remote host.

**3. `#[cfg(test)] thread_local!` interception.** `deploy.rs` swaps its SSH calls for a
`MOCK_SSH_COMMANDS` vector in unit tests. It is `pub(crate)`, so it only works for tests
compiled *inside* the crate — integration tests must use seam 2.

**The fixture.** `tests/common/mod.rs::TestRepo` creates a tempdir with a bare origin, an
initialised `htdocs` git repo with a remote, and helpers (`write_file`, `commit_all`,
`git_run`, `setup_basic_project`, `setup_mezzio_project`). Note that
`setup_mezzio_project` runs a **real** `composer install` in a
`fduarte42/docker-php:8.2` container — so the deploy integration tests need a working
Docker daemon and network access. Everything else is pure filesystem/git and runs
anywhere.

Current size: 104 integration tests and 108 unit tests.
`tests/module_integration_tests.rs` (38 tests) is the best worked example of testing a
complex command.

---

## 7. Making a change

### 7.1 Add a subcommand

1. `src/commands/<name>.rs` exposing `pub fn execute(project_dir: &Path, …) -> Result<()>`
   (`async` only if you need it — most commands are sync).
2. Register it in `src/commands/mod.rs`.
3. Add a variant to `enum Commands` in `src/main.rs`, with doc comments — clap uses them
   as the help text, and the help screen is user-facing documentation.
4. Add the match arm in `async_main`.
5. If it needs a managed project: call `check_managed(&project_dir)` in the arm **and**
   add the clap name to `command_requires_managed_project()`. That list exists so a
   custom script winning a name clash is gated exactly as the built-in would be; a
   mismatch is a silent bug.
6. If it needs no Docker/SSH (like `user-manual`, `install-deps`, `upgrade`), add its
   name to the `no_ssh_needed` list in `main()` — otherwise `detect_platform()`'s
   `docker info` runs before the user sees anything — and/or to the
   `skip_dependency_check` list in `async_main`, which is what keeps `install-deps` from
   being blocked by the very dependencies it installs.
7. Route all output through `src/ui/` (`info`/`warning`/`critical`/`success`/`debug`),
   never `println!`.
8. Errors: `anyhow::Result` with `context()`/`anyhow!`. Don't invent a new error type.
9. Tests, following §6 seam 1.
10. Docs: README command list, `USER-MANUAL.md` §5, `CHANGELOG.md`, and **rebuild the PDF**
    (§8).

### 7.2 Add a flag to an existing command

Add the `#[arg(...)]` field to the `Commands` variant, thread it through the match arm
into `execute()`, and — if it is a mutually exclusive choice — use clap's
`conflicts_with_all` rather than hand-rolled validation (`cleanup-backups` is the
example). Interactive-by-default commands get a `-y/--yes` escape hatch; destructive ones
also get `--dry-run` where it makes sense.

### 7.3 Change the shipped template (`template/`)

The template is what every managed project is synced against, so a change here lands in
every project on the next `update`.

1. Edit `template/`.
2. Test with `DOCKER_CONTROL_TEMPLATE_DIR=$PWD/template` against a scratch project — a
   plain rebuild will *not* re-extract (§5.2).
3. Think about the three-way merge: a project that edited the same file gets a conflict
   prompt or a `*.dist` sidecar. If the change is a rename (e.g. the 2.7.0 `redis` →
   `cache` service), consider a compatibility shim so nothing has to be reconfigured, and
   check whether `down --remove-orphans` is needed to clean up the old container.
4. Renaming a host data directory (`volumes/...`) discards user data — the 2.7.0 notes
   explain why the service was renamed but its data directory deliberately was not.
5. `template/CLAUDE.md` ships *inside* generated projects and is overwritten by `update`.
   It is not guidance for this repo — that is `AGENTS.md`.
6. Add `tests/template_state_tests.rs` coverage if you touch classification behaviour.

### 7.4 Change the ingress (`ingress/`)

Same extraction caveat (`DOCKER_CONTROL_INGRESS_DIR`). Any change to these files changes
the fingerprint, so every existing installation with a running proxy will be offered a
restart on its next `start`/`restart` — that is intended, but it briefly drops HTTPS for
every project on the host, so the restart is never automatic. Re-read §5.4 first.

### 7.5 Add an external tool dependency

Add a `Dependency` entry in `src/utils/dependencies.rs` with `critical` set honestly and
`brew_formula` only where `brew install` genuinely puts that binary on `PATH` — the
existing `None`s each have a comment explaining why (keg-only `openssh`, `7z` vs `7zz`,
Docker Desktop). Prefer a per-command check —
`dependencies::require_dependency("7z")` or `require_acl_tools()`, both of which offer a
direct Homebrew install at the point of need — over marking something critical at
startup: a hard startup dependency is paid by every command.
Then document it in `USER-MANUAL.md` §14.

---

## 8. Documentation obligations

| File | What it is | Maintained |
|---|---|---|
| `README.md` | Install + orientation for this repo | by hand |
| `USER-MANUAL.md` | The full end-user manual (~50 KB, hand-written TOC) | by hand |
| `USER-MANUAL.pdf` | Generated from the manual, **committed**, embedded in the binary | generated |
| `CHANGELOG.md` | Release notes — and the de facto design record | by hand, per release |
| `AGENTS.md` | Agent/architecture guidance; `CLAUDE.md` is a pointer to it | by hand |
| `MIGRATION.md` | Upgrade notes from the pre-Rust bash tool | rarely |
| `docs/*.md` | Design plans, frozen once implemented | frozen |

**Standing rule: a change that touches `USER-MANUAL.md` must regenerate
`USER-MANUAL.pdf` in the same change.** Nothing in CI or `build.sh` builds it, and the
PDF is `include_bytes!`-embedded in the binary, so a stale PDF ships to users.

```bash
.claude/skills/user-manual-pdf/build-pdf.sh           # rebuild in place
.claude/skills/user-manual-pdf/build-pdf.sh --check   # exit 2 = committed PDF is stale
```

`.claude/skills/user-manual-pdf/SKILL.md` documents the toolchain (pandoc + WeasyPrint in
a venv cached *outside* the repo), the mandatory `+gfm_auto_identifiers` flag (the TOC is
hand-written with GitHub-style anchors and pandoc's default identifiers break every
link), and how to read the build's text diff. Two committed Claude Code hooks in
`.claude/settings.json` enforce the rule during a session; `--check` is the one that works
after a clone or a merge, because it compares extracted text rather than mtimes.

Note also that `CHANGELOG.md` here is unusually substantive — entries explain *why*, not
just *what*. When you need the history behind a decision, it is often faster than git
log. Please keep writing it that way.

---

## 9. Releasing

Two separate things called "release" live in this repo — don't confuse them:

- **`docker-control release`** is a *user-facing command* that cuts releases of a
  customer's PHP app (`src/commands/release.rs`, git worktrees under `releases/`).
- **Releasing this tool** is the process below.

### Releasing the tool

1. Land the feature commits on `main` (lower-case, short, descriptive messages, no
   conventional-commit prefixes: `enhanced deploy hooks`, `bugfixes for migration`).
2. Bump `version` in `Cargo.toml` (and `Cargo.lock`).
3. Add the `CHANGELOG.md` section for the new version.
4. Update `USER-MANUAL.md` if behaviour moved, and rebuild the PDF.
5. Commit with the version number as the subject line and the changelog prose as the body
   (see `git show 978566c`). **Prefix `release:` is reserved** and must not be used for
   anything else — `docker-control merge` cherry-picks from a release branch back to
   primary and deliberately skips every `release:` commit.
6. Push `main`, then tag that commit with the plain semver (`2.7.2`) and push the tag.

Pushing a tag triggers `.github/workflows/release.yml` — generated by `cargo-dist`
(`dist-workspace.toml`, pinned 0.31.0). It builds `aarch64-apple-darwin`,
`aarch64-unknown-linux-gnu`, `x86_64-unknown-linux-gnu`, attaches archives + hashes to a
GitHub Release, and publishes a Homebrew formula to
`INTERLIGENT-kommunzieren-GmbH/homebrew-tap`. `include` ships `template/`, `ingress/`, and
`USER-MANUAL.pdf` alongside the binary (which is how the installed `share/` layout gets
populated), and `bin-aliases` adds `dc2`.

**Never hand-edit `.github/workflows/release.yml`** — it is generated; regenerate it with
`dist init` after changing `dist-workspace.toml`.

---

## 10. Traps that have already cost someone a day

- **Scanning the whole argv for one of our flags.** Stop at the first standalone `--`
  (§5.5).
- **Writing a user's `composer.json` with `serde_json`.** Use `composer config` (§5.6).
- **Appending a Composer `path` repository.** It must be **prepended**, or a private
  `composer` repo in the same file outranks it and Composer re-clones upstream while
  exiting 0. `module link` asserts the resulting symlink instead of trusting the exit
  status — do the same for any new Composer manipulation.
- **Trusting a Composer exit code at all.** Composer reports success for several
  outcomes that are not the one you asked for. Verify on disk.
- **Calling Composer with a live `vendor/` symlink in place during `unlink`.** Composer
  follows it into a dirty worktree and aborts *after* rewriting `composer.lock`.
- **"Everything under /var/www must be writable" as an ACL check.** The container ACL is a
  POSIX *named-user* entry (`u:33:rwX`), and the kernel ignores it for the file's own
  owner. Files `www-data` owns at `0444` (git objects, the Composer cache) can never be
  fixed by re-running `setfacl`, so a naive predicate re-reports them forever.
  `find_inaccessible_paths` in `commands/doctor.rs` flags only what the ACL actually
  governs — read its doc comment before widening it.
- **Stamping a version where a content fingerprint is needed.** Both the template state
  and the ingress state made this choice deliberately; a version stamp turns into a
  prompt after every upgrade that changed nothing.
- **Doing anything meaningful in-process after `brew upgrade`.** The running process is
  still the old keg; `upgrade` spawns the newly installed binary on purpose.
- **Forgetting `command_requires_managed_project()`** when you add `check_managed` to a
  new arm (§7.1 step 5).
- **Forgetting the PDF** (§8). A `Stop` hook will catch you in-session; a clone will not.

---

## 11. Where to look next

- `AGENTS.md` — the design rationale, in depth. The single most valuable file here.
- `CHANGELOG.md` — why each behaviour is the way it is, release by release.
- `docs/*.md` — two worked design plans (`cleanup-backups`, `custom-command-override`)
  that show the expected level of analysis before a non-trivial feature.
- `src/commands/module.rs` — the most intricate command, with a module-level doc comment
  explaining the three empirically established constraints. Read it as the house style
  for "hard-won knowledge goes in a comment next to the code".
- `examples/` — `.deploy.json` shapes and Rhai deploy hooks (`pre_deploy`, `post_deploy`,
  `done_deploy`), useful when working on `deploy.rs`.
- `CODE_REVIEW_FINDINGS.md` — including the one still-open finding.
