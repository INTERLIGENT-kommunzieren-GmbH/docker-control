use anyhow::Result;
use std::path::Path;

pub mod forwarding;
pub mod platform;

pub fn stop_ssh_agent() -> Result<()> {
    let pid_file = "/tmp/docker-control-ssh-agent.pid";
    let pid_str = std::fs::read_to_string(pid_file)
        .map_err(|_| anyhow::anyhow!("SSH agent daemon is not running (PID file not found)"))?;
    let pid: u32 = pid_str
        .trim()
        .parse()
        .map_err(|_| anyhow::anyhow!("Invalid PID in file"))?;
    let status = std::process::Command::new("kill")
        .arg("-TERM")
        .arg(pid.to_string())
        .status()
        .map_err(|e| anyhow::anyhow!("Failed to kill process {}: {}", pid, e))?;
    if !status.success() {
        // Process not found, but clean up anyway
        crate::ui::warning(format!(
            "Process {} not found (stale PID file), cleaning up.",
            pid
        ));
    }
    std::fs::remove_file(pid_file)
        .map_err(|e| anyhow::anyhow!("Failed to remove PID file {}: {}", pid_file, e))?;
    Ok(())
}

pub fn is_managed(project_dir: &Path) -> bool {
    project_dir
        .join(".managed-by-docker-control-plugin")
        .exists()
}
