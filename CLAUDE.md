# Docker Control Plugin Development

## Build and Run
- **Build**: `cargo build`
- **Run**: `cargo run -- [args]` (e.g., `cargo run -- init`)
- **Release Build**: `cargo build --release`

## Testing
- **Run all tests**: `cargo test`

## Linting and Formatting
- **Lint**: `cargo clippy`
- **Format**: `cargo fmt`
- **Fix lints**: `cargo fix --allow-dirty`

## Installation
To install the native binary locally:
```bash
cargo build --release
cp target/release/docker-control ~/.docker/cli-plugins/docker-control
chmod +x ~/.docker/cli-plugins/docker-control
```
