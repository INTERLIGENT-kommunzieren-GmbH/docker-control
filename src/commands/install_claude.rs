use crate::ui;
use crate::utils::hash_bytes;
use anyhow::{Result, bail, Context};
use std::process::Command;

/// Official Claude Code installer (native binary). See https://docs.claude.com.
const CLAUDE_INSTALL_SCRIPT_URL: &str = "https://claude.ai/install.sh";

/// SHA-256 checksum of the Claude Code installer script, pinned to a known-good
/// version. This must be updated when intentionally upgrading to a newer installer.
///
/// To update this checksum:
/// 1. Download and manually review the installer: curl -fsSL https://claude.ai/install.sh
/// 2. Verify it performs only expected operations
/// 3. Compute the checksum: curl -fsSL https://claude.ai/install.sh | sha256sum
/// 4. Update this constant with the hex-encoded SHA-256 hash
const CLAUDE_INSTALL_SCRIPT_SHA256: &str = 
    "0000000000000000000000000000000000000000000000000000000000000000";

/// Companion codebase-memory-mcp installer, run right after Claude Code so the
/// MCP server is available for use with the freshly installed CLI.
const MEMORY_MCP_INSTALL_SCRIPT_URL: &str =
    "https://raw.githubusercontent.com/DeusData/codebase-memory-mcp/main/install.sh";

/// SHA-256 checksum of the codebase-memory-mcp installer script, pinned to a
/// known-good version. This must be updated when intentionally upgrading.
///
/// To update this checksum:
/// 1. Download and manually review the installer from the URL above
/// 2. Verify it performs only expected operations
/// 3. Compute the checksum: curl -fsSL <url> | sha256sum
/// 4. Update this constant with the hex-encoded SHA-256 hash
const MEMORY_MCP_INSTALL_SCRIPT_SHA256: &str =
    "0000000000000000000000000000000000000000000000000000000000000000";

/// Installs Claude Code using Anthropic's official install script, then installs
/// codebase-memory-mcp using its install script. Both scripts are downloaded,
/// verified against pinned SHA-256 checksums, and only then executed. This prevents
/// arbitrary code execution from a compromised or malicious upstream response.
pub fn execute() -> Result<()> {
    run_verified_installer(
        "Claude Code",
        CLAUDE_INSTALL_SCRIPT_URL,
        CLAUDE_INSTALL_SCRIPT_SHA256,
    )?;
    run_verified_installer(
        "codebase-memory-mcp",
        MEMORY_MCP_INSTALL_SCRIPT_URL,
        MEMORY_MCP_INSTALL_SCRIPT_SHA256,
    )?;
    enable_memory_mcp_auto_index()?;
    Ok(())
}

/// Enables automatic indexing of new projects in codebase-memory-mcp, run once
/// right after its install so the MCP server is ready to auto-index out of the box.
fn enable_memory_mcp_auto_index() -> Result<()> {
    ui::info("Enabling codebase-memory-mcp auto-indexing of new projects...");

    let status = Command::new("codebase-memory-mcp")
        .args(["config", "set", "auto_index", "true"])
        .status()?;

    if !status.success() {
        bail!(
            "Failed to enable codebase-memory-mcp auto-indexing (status {})",
            status
        );
    }

    ui::success("codebase-memory-mcp auto-indexing enabled.");
    Ok(())
}

/// Downloads an installer script, verifies its SHA-256 checksum against a pinned
/// value, and only then executes it. This prevents arbitrary code execution from
/// a compromised or malicious upstream response.
///
/// The checksum verification ensures that:
/// 1. The script content matches a known-good version reviewed by maintainers
/// 2. No man-in-the-middle attack can inject malicious code
/// 3. Upstream changes (malicious or accidental) are caught before execution
///
/// When the checksum doesn't match, the error message includes the actual hash
/// so maintainers can update the pinned constant after reviewing the new script.
fn run_verified_installer(name: &str, url: &str, expected_sha256: &str) -> Result<()> {
    ui::info(format!("Downloading {name} installer from {url}..."));

    // Download the script content instead of piping directly to bash
    let script_content = download_script(url)
        .context(format!("Failed to download {name} installer from {url}"))?;

    // Verify the checksum before executing anything
    let actual_sha256 = hash_bytes(script_content.as_bytes());
    
    if actual_sha256 != expected_sha256 {
        bail!(
            "{name} installer verification failed: checksum mismatch.\n\
             Expected: {expected_sha256}\n\
             Actual:   {actual_sha256}\n\n\
             This indicates the installer script has changed since this version of docker-control \
             was released. This could be due to:\n\
             1. A legitimate update to the installer\n\
             2. A compromised or malicious upstream source\n\
             3. A man-in-the-middle attack\n\n\
             To proceed safely:\n\
             1. Manually review the installer at {url}\n\
             2. If the changes are legitimate, update the checksum constant in \
                src/commands/install_claude.rs\n\
             3. Never bypass this check without reviewing the script content"
        );
    }

    ui::info(format!("Checksum verified. Installing {name}..."));

    // Execute the verified script through bash
    let status = Command::new("bash")
        .arg("-c")
        .arg(&script_content)
        .status()
        .context(format!("Failed to execute {name} installer"))?;

    if !status.success() {
        bail!("{name} installation failed with status {}", status);
    }

    ui::success(format!("{name} installed successfully."));
    Ok(())
}

/// Downloads a script from the given URL using reqwest. Returns the script content
/// as a String, or an error if the download fails.
fn download_script(url: &str) -> Result<String> {
    // Use a blocking reqwest client since this command is not async
    let client = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .context("Failed to create HTTP client")?;

    let response = client
        .get(url)
        .send()
        .context("Failed to send HTTP request")?;

    if !response.status().is_success() {
        bail!(
            "HTTP request failed with status {}: {}",
            response.status(),
            response.status().canonical_reason().unwrap_or("Unknown")
        );
    }

    response
        .text()
        .context("Failed to read response body as text")
}
