use anyhow::{Result, anyhow};
use std::process::Command;

/// Execute an SSH command on a remote host with strict host key checking.
///
/// If `expected_host_key` is provided, it should be an SSH fingerprint in the format
/// `SHA256:...` or `MD5:...`. The function will verify the server's host key matches
/// this fingerprint before connecting.
///
/// If `expected_host_key` is `None`, the connection relies on the user's `~/.ssh/known_hosts`
/// file. The host must already be present in known_hosts; unknown hosts are rejected to
/// prevent trust-on-first-use attacks during deployment.
pub fn exec_ssh(user: &str, domain: &str, command: &str, expected_host_key: Option<&str>) -> Result<()> {
    // If a host key fingerprint is provided, verify it before connecting
    if let Some(fingerprint) = expected_host_key {
        verify_host_key(domain, fingerprint)?;
    }

    let mut cmd = Command::new("ssh");
    cmd.arg("-o")
        .arg("LogLevel=QUIET")
        .arg("-o")
        .arg("StrictHostKeyChecking=yes")
        .arg("-tA")
        .arg(format!("{}@{}", user, domain))
        .arg("--")
        .arg(command);

    let status = cmd.status().map_err(|e| {
        anyhow!("Failed to execute SSH command: {}. Ensure the host key for '{}' is in ~/.ssh/known_hosts or configure 'sshHostKey' in .deploy.json", e, domain)
    })?;

    if !status.success() {
        return Err(anyhow!(
            "SSH command failed with status {}. If this is a host key verification failure, \
             ensure '{}' is in ~/.ssh/known_hosts or configure 'sshHostKey' in .deploy.json with \
             the server's SSH fingerprint (obtain via: ssh-keyscan -t ed25519,rsa {} | ssh-keygen -lf -)",
            status, domain, domain
        ));
    }

    Ok(())
}

/// Copy a file to a remote host via SCP with strict host key checking.
///
/// If `expected_host_key` is provided, it should be an SSH fingerprint in the format
/// `SHA256:...` or `MD5:...`. The function will verify the server's host key matches
/// this fingerprint before connecting.
///
/// If `expected_host_key` is `None`, the connection relies on the user's `~/.ssh/known_hosts`
/// file. The host must already be present in known_hosts; unknown hosts are rejected to
/// prevent trust-on-first-use attacks during deployment.
pub fn copy_ssh(user: &str, domain: &str, src: &std::path::Path, dest: &str, expected_host_key: Option<&str>) -> Result<()> {
    // If a host key fingerprint is provided, verify it before connecting
    if let Some(fingerprint) = expected_host_key {
        verify_host_key(domain, fingerprint)?;
    }

    let mut cmd = Command::new("scp");
    cmd.arg("-o")
        .arg("StrictHostKeyChecking=yes")
        .arg("-A")
        .arg(src)
        .arg(format!("{}@{}:{}", user, domain, dest));

    let status = cmd.status().map_err(|e| {
        anyhow!("Failed to execute SCP command: {}. Ensure the host key for '{}' is in ~/.ssh/known_hosts or configure 'sshHostKey' in .deploy.json", e, domain)
    })?;

    if !status.success() {
        return Err(anyhow!(
            "SCP copy failed with status {}. If this is a host key verification failure, \
             ensure '{}' is in ~/.ssh/known_hosts or configure 'sshHostKey' in .deploy.json with \
             the server's SSH fingerprint (obtain via: ssh-keyscan -t ed25519,rsa {} | ssh-keygen -lf -)",
            status, domain, domain
        ));
    }

    Ok(())
}

/// Verify that a host's SSH key matches the expected fingerprint.
///
/// This function uses `ssh-keyscan` to retrieve the host's public key and `ssh-keygen`
/// to compute its fingerprint, then compares it against the expected value.
fn verify_host_key(domain: &str, expected_fingerprint: &str) -> Result<()> {
    // Use ssh-keyscan to get the host key
    let keyscan_output = Command::new("ssh-keyscan")
        .arg("-t")
        .arg("ed25519,rsa,ecdsa")
        .arg(domain)
        .output()
        .map_err(|e| anyhow!("Failed to run ssh-keyscan: {}. Ensure ssh-keyscan is installed.", e))?;

    if !keyscan_output.status.success() {
        return Err(anyhow!(
            "ssh-keyscan failed for '{}': {}",
            domain,
            String::from_utf8_lossy(&keyscan_output.stderr)
        ));
    }

    let scanned_keys = String::from_utf8_lossy(&keyscan_output.stdout);
    if scanned_keys.trim().is_empty() {
        return Err(anyhow!(
            "No SSH host keys found for '{}'. Ensure the host is reachable.",
            domain
        ));
    }

    // Use ssh-keygen to compute fingerprints of the scanned keys
    let keygen_output = Command::new("ssh-keygen")
        .arg("-lf")
        .arg("-")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .and_then(|mut child| {
            use std::io::Write;
            if let Some(mut stdin) = child.stdin.take() {
                stdin.write_all(scanned_keys.as_bytes())?;
            }
            child.wait_with_output()
        })
        .map_err(|e| anyhow!("Failed to run ssh-keygen: {}. Ensure ssh-keygen is installed.", e))?;

    if !keygen_output.status.success() {
        return Err(anyhow!(
            "ssh-keygen failed: {}",
            String::from_utf8_lossy(&keygen_output.stderr)
        ));
    }

    let fingerprints = String::from_utf8_lossy(&keygen_output.stdout);
    
    // Check if any of the fingerprints match the expected one
    let expected_normalized = expected_fingerprint.trim();
    for line in fingerprints.lines() {
        // ssh-keygen output format: "2048 SHA256:... hostname (RSA)"
        if let Some(fp_start) = line.find("SHA256:").or_else(|| line.find("MD5:")) {
            if let Some(fp_end) = line[fp_start..].find(' ') {
                let fingerprint = &line[fp_start..fp_start + fp_end];
                if fingerprint == expected_normalized {
                    return Ok(());
                }
            }
        }
    }

    Err(anyhow!(
        "Host key verification failed for '{}': The server's SSH fingerprint does not match the configured 'sshHostKey'.\n\
         Expected: {}\n\
         Received fingerprints:\n{}\n\
         If the server's key has changed legitimately, update 'sshHostKey' in .deploy.json.\n\
         To obtain the current fingerprint, run: ssh-keyscan -t ed25519,rsa {} | ssh-keygen -lf -",
        domain, expected_normalized, fingerprints.trim(), domain
    ))
}
