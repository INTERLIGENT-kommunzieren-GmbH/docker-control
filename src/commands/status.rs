use crate::config::DeployConfig;
use crate::git::GitService;
use crate::ui;
use crate::utils;
use anyhow::Result;
use std::path::Path;
use std::process::Command;

pub fn execute(project_dir: &Path) -> Result<()> {
    ui::info("Project Status");
    println!("  Project Directory: {}", project_dir.display());

    // 1. Plugin Management
    if utils::is_managed(project_dir) {
        ui::success("  Plugin Management: ✓ Managed by Docker Control Plugin");
    } else {
        ui::warning("  Plugin Management: ✗ Not managed by Docker Control Plugin");
        println!("    Run 'docker control init' to initialize this directory");
    }

    // 2. Git Status
    show_git_status(project_dir);

    // 3. Deployment Status
    show_deployment_status(project_dir);

    // 4. Docker Status
    show_docker_status(project_dir);

    Ok(())
}

pub fn get_summary(project_dir: &Path) -> String {
    let mut summary = Vec::new();

    // 1. Plugin Management
    if utils::is_managed(project_dir) {
        summary.push("✓ Managed".to_string());
    } else {
        summary.push("✗ Unmanaged".to_string());
    }

    // 2. Git Summary
    let git_path = project_dir.join("htdocs");
    if let Ok(git) = GitService::open(&git_path) {
        if let Ok(branch) = git.get_current_branch() {
            let mut git_info = format!("Git: {}", branch);
            if let Ok(repo) = git2::Repository::open(&git_path) {
                if let Ok(statuses) = repo.statuses(None) {
                    if !statuses.is_empty() {
                        git_info.push_str("*");
                    }
                }
            }
            summary.push(git_info);
        } else {
            summary.push("Git: Unknown".to_string());
        }
    } else {
        summary.push("Git: None".to_string());
    }

    // 3. Docker Summary
    let filter = format!(
        "label=com.interligent.dockerplugin.dir={}",
        project_dir.display()
    );
    let output = Command::new("docker")
        .args([
            "ps",
            "-a",
            "--filter",
            &filter,
            "--format",
            "{{.Status}}",
        ])
        .output();

    match output {
        Ok(out) if out.status.success() => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            let containers: Vec<&str> = stdout.lines().collect();
            let container_count = containers.len();
            let running_count = containers.iter().filter(|c| c.contains("Up")).count();

            if container_count > 0 {
                summary.push(format!("Docker: {}/{} up", running_count, container_count));
            } else {
                summary.push("Docker: down".to_string());
            }
        }
        _ => summary.push("Docker: error".to_string()),
    }

    summary.join(" | ")
}

fn show_git_status(project_dir: &Path) {
    let git_path = project_dir.join("htdocs");
    if let Ok(git) = GitService::open(&git_path) {
        match git.get_current_branch() {
            Ok(branch) => {
                let mut status_msg = format!("on branch {}", branch);

                // Check for dirty state
                if let Ok(repo) = git2::Repository::open(&git_path) {
                    if let Ok(statuses) = repo.statuses(None) {
                        if !statuses.is_empty() {
                            status_msg.push_str(" (uncommitted changes)");
                        }
                    }
                }

                ui::success(format!("  Git Repository: ✓ Initialized ({})", status_msg));
            }
            Err(_) => {
                ui::warning("  Git Repository: ✓ Initialized (detached HEAD or unknown state)")
            }
        }
    } else {
        ui::warning("  Git Repository: ✗ Not a git repository");
        println!("    Initialize with 'git init' in the htdocs directory");
    }
}

fn show_deployment_status(project_dir: &Path) {
    match DeployConfig::load(project_dir) {
        Ok(config) => {
            ui::success("  Deployment Config: ✓ Configured (JSON)");
            let envs: Vec<String> = config.environments.keys().cloned().collect();
            if !envs.is_empty() {
                println!("    Environments: {}", envs.join(", "));
            } else {
                println!("    No environments configured");
            }
        }
        Err(_) => {
            ui::warning("  Deployment Config: ✗ Not configured");
            println!("    Run 'docker control add-deploy-config' to add deployment environments");
        }
    }
}

fn show_docker_status(project_dir: &Path) {
    // Check if docker is available
    let filter = format!(
        "label=com.interligent.dockerplugin.dir={}",
        project_dir.display()
    );
    ui::debug(format!("Querying docker containers with filter: {}", filter));

    let output = Command::new("docker")
        .args([
            "ps",
            "-a",
            "--filter",
            &filter,
            "--format",
            "{{.Names}}\t{{.Status}}",
        ])
        .output();

    match output {
        Ok(out) if out.status.success() => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            let containers: Vec<&str> = stdout.lines().collect();
            let container_count = containers.len();
            let running_count = containers.iter().filter(|c| c.contains("Up")).count();

            if container_count > 0 {
                if running_count > 0 {
                    ui::success(format!(
                        "  Docker Status: ✓ {}/{} containers running",
                        running_count, container_count
                    ));
                } else {
                    ui::warning(format!(
                        "  Docker Status: ○ {} containers stopped",
                        container_count
                    ));
                    println!("    Run 'docker control start' to start containers");
                }
            } else {
                ui::warning("  Docker Status: ○ No project containers found");
                println!("    Run 'docker control start' to create and start containers");
            }
        }
        _ => ui::warning("  Docker Status: ✗ Unable to query container status"),
    }
}
