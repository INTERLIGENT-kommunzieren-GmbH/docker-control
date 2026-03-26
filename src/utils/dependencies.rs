use crate::ui;
use anyhow::{Result, anyhow};
use std::process::Command;

pub struct Dependency {
    pub name: &'static str,
    pub command: &'static str,
    pub args: &'static [&'static str],
    pub critical: bool,
    pub description: &'static str,
}

const DEPENDENCIES: &[Dependency] = &[
    Dependency {
        name: "Docker",
        command: "docker",
        args: &["--version"],
        critical: true,
        description: "Required for all container operations",
    },
    Dependency {
        name: "Docker Compose",
        command: "docker",
        args: &["compose", "version"],
        critical: true,
        description: "Required for managing project services",
    },
    Dependency {
        name: "Git",
        command: "git",
        args: &["--version"],
        critical: true,
        description: "Required for release and merge workflows",
    },
    Dependency {
        name: "SSH",
        command: "ssh",
        args: &["-V"],
        critical: true,
        description: "Required for secure remote access",
    },
    Dependency {
        name: "SCP",
        command: "scp",
        args: &[], // scp -? or similar might fail, but just checking if it exists
        critical: true,
        description: "Required for file transfers during deployment",
    },
    Dependency {
        name: "Bash",
        command: "bash",
        args: &["--version"],
        critical: true,
        description: "Required for executing scripts",
    },
    Dependency {
        name: "Sudo",
        command: "sudo",
        args: &["--version"],
        critical: false,
        description: "Required for migration tasks requiring elevated privileges",
    },
    Dependency {
        name: "Rsync",
        command: "rsync",
        args: &["--version"],
        critical: false,
        description: "Required for migration tasks",
    },
    Dependency {
        name: "7-Zip",
        command: "7z",
        args: &[],
        critical: false,
        description: "Required for creating deployment packages",
    },
];

pub fn check_dependencies() -> Result<()> {
    // ui::debug("Checking external CLI dependencies...");
    let mut missing_critical = Vec::new();
    let mut missing_optional = Vec::new();

    for dep in DEPENDENCIES {
        let exists = if dep.command == "scp" || dep.command == "7z" {
            // These might return non-zero for just --version or no args
            Command::new("which")
                .arg(dep.command)
                .output()
                .map(|o| o.status.success())
                .unwrap_or(false)
        } else {
            Command::new(dep.command)
                .args(dep.args)
                .output() // Capture output to avoid it leaking to stdout/stderr
                .map(|o| o.status.success())
                .unwrap_or(false)
        };

        if !exists {
            if dep.critical {
                missing_critical.push(dep);
            } else {
                missing_optional.push(dep);
            }
        }
    }

    if !missing_optional.is_empty() {
        for dep in missing_optional {
            ui::warning(format!(
                "Optional dependency '{}' ({}) is missing. {}",
                dep.name, dep.command, dep.description
            ));
        }
    }

    if !missing_critical.is_empty() {
        for dep in &missing_critical {
            ui::critical(format!(
                "Critical dependency '{}' ({}) is missing! {}",
                dep.name, dep.command, dep.description
            ));
        }
        return Err(anyhow!(
            "Missing {} critical dependencies. Please install them and try again.",
            missing_critical.len()
        ));
    }

    // ui::debug("All critical dependencies are present.");
    Ok(())
}
