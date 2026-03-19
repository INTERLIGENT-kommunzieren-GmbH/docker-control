use crate::ui;
use anyhow::{Context, Result, anyhow};
use std::path::{Path, PathBuf};
use std::process::Command;

pub fn execute_compose(project_dir: &Path, args: &[&str]) -> Result<()> {
    let mut cmd = Command::new("docker");
    cmd.arg("compose")
        .arg("--project-directory")
        .arg(project_dir)
        .args(args)
        .current_dir(project_dir);

    let status = cmd.status().context("Failed to execute docker compose")?;

    if !status.success() {
        return Err(anyhow!("docker compose failed with status {}", status));
    }

    Ok(())
}

pub fn execute_ingress_compose(args: &[&str]) -> Result<()> {
    let ingress_dir = find_ingress_dir()?;
    let compose_file = ingress_dir.join("compose.yml");

    if !compose_file.exists() {
        return Err(anyhow!(
            "Ingress compose file not found at {:?}",
            compose_file
        ));
    }

    let mut cmd = Command::new("docker");
    cmd.arg("compose")
        .arg("--project-directory")
        .arg(&ingress_dir)
        .arg("-f")
        .arg(&compose_file)
        .args(args);

    let status = cmd
        .status()
        .context("Failed to execute docker compose for ingress")?;

    if !status.success() {
        return Err(anyhow!(
            "docker compose ingress failed with status {}",
            status
        ));
    }

    Ok(())
}

pub fn console(project_dir: &Path, container: Option<String>) -> Result<()> {
    let service = container.unwrap_or_else(|| "php".to_string());

    if service == "help" {
        ui::info("Available containers:");
        let output = Command::new("docker")
            .arg("compose")
            .arg("--project-directory")
            .arg(project_dir)
            .arg("ps")
            .arg("--services")
            .current_dir(project_dir)
            .output()?;

        if output.status.success() {
            let services = String::from_utf8_lossy(&output.stdout);
            for s in services.lines() {
                ui::info(format!("  - {}", s));
            }
        }
        return Ok(());
    }

    let mut cmd = Command::new("docker");
    cmd.arg("compose")
        .arg("--project-directory")
        .arg(project_dir)
        .arg("exec")
        .current_dir(project_dir);

    if service == "php" {
        cmd.arg("-itu").arg("www-data");
    }

    cmd.arg(&service).arg("bash");

    let status = cmd
        .status()
        .context("Failed to execute docker compose exec")?;

    if !status.success() {
        // Fallback or retry? Original bash doesn't seem to have much fallback
        // but it might fail if bash is not available.
    }

    Ok(())
}

fn find_ingress_dir() -> Result<PathBuf> {
    // 1. Check environment variable
    if let Ok(env_path) = std::env::var("DOCKER_CONTROL_INGRESS_DIR") {
        let path = PathBuf::from(env_path);
        if path.exists() {
            return Ok(path);
        }
    }

    // 2. Check user config directory (AssetManager)
    if let Ok(asset_manager) = crate::assets::AssetManager::new() {
        let path = asset_manager.get_ingress_dir();
        if path.exists() {
            return Ok(path);
        }
    }

    // 3. Check relative to binary
    if let Ok(exe_path) = std::env::current_exe()
        && let Some(exe_dir) = exe_path.parent()
    {
        let path = exe_dir.join("ingress");
        if path.exists() {
            return Ok(path);
        }
        // Check one level up (if binary is in a bin/ folder)
        if let Some(parent) = exe_dir.parent() {
            let path = parent.join("ingress");
            if path.exists() {
                return Ok(path);
            }
        }
    }

    // 3. Check current directory (for development)
    let path = PathBuf::from("ingress");
    if path.exists() {
        return Ok(path);
    }

    Err(anyhow!("Could not find ingress directory"))
}
