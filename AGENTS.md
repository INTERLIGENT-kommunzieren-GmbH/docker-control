# Repository Guidelines

## Project Structure & Module Organization
This CLI tool is organized into functional modules under `src/`, following a clean separation of concerns:

- **CLI Entry Point**: `src/main.rs` uses `clap` for command parsing and routing.
- **Command Implementation**: `src/commands/` contains individual modules for each CLI subcommand (e.g., `deploy.rs`, `merge.rs`, `init.rs`).
- **Core Wrappers**:
  - `src/docker/`: Handles container management via `bollard`.
  - `src/git/`: Manages repository operations using `git2`.
  - `src/ssh/`: Handles SSH agent forwarding and connectivity.
- **Support Modules**:
  - `src/config/`: Manages deployment configuration (primarily `.deploy.json`).
  - `src/ui/`: Provides interactive prompts and terminal output styling.
  - `src/utils/`: Contains platform-specific logic and dependency checks.
  - `src/assets/`: Manages embedded resources like the project template in `dist/template/`.

## Build, Test, and Development Commands
The project uses standard Cargo commands for development:

- **Build**: `cargo build`
- **Release Build**: `cargo build --release`
- **Run**: `cargo run -- [args]` (e.g., `cargo run -- init`)
- **Test**: `cargo nextest run`
- **Single Test**: `cargo nextest run <test_substring>`
- **Lint**: `cargo clippy`
- **Format**: `cargo fmt`
- **Fix Lints**: `cargo fix --allow-dirty`

## Coding Style & Naming Conventions
- **Rust Edition**: 2024.
- **Formatting**: Enforced by `rustfmt`. Use `cargo fmt` before committing.
- **Linter**: `clippy` is used for code quality. Some specific lints like `clippy::collapsible_if` are allowed in certain contexts.
- **Error Handling**: Uses `anyhow` for flexible error propagation.

## Testing Guidelines
- **Framework**: `cargo-nextest` (Standard Rust tests executed via `cargo nextest run`).
- **Utilities**: Uses `tempfile` for file system isolation during tests.
- **Test Locations**: Includes both unit tests within modules and integration tests in `tests/`.

## Commit & Pull Request Guidelines
Commit history follows a pattern of clear, descriptive messages:
- **Releases**: Tagged with semantic versioning (e.g., `2.1.9`).
- **Features/Fixes**: Summarize the change (e.g., `enhanced deploy hooks`, `bugfixes for migration`).
- **Merge Logic**: The `merge` command automates a selective cherry-pick workflow, excluding "release:" prefixed commits.
