use crate::assets::AssetManager;
use crate::ui;
use anyhow::{Context, Result};
use std::fs;
use std::path::Path;
use std::process::Command;
use std::time::SystemTime;

pub fn execute(project_dir: &Path) -> Result<()> {
    ui::info("Updating project with latest template...");

    let asset_manager = AssetManager::new()?;
    asset_manager.ensure_assets()?;
    let template_dir = asset_manager.get_template_dir();

    // Create backup
    let now = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)?
        .as_secs();
    let backup_name = format!("backup_{}", now);
    let backup_dir = project_dir.join(&backup_name);

    ui::info(format!("Creating backup {}...", backup_name));
    fs::create_dir_all(&backup_dir)?;

    // Backup current files (excluding what bash excludes)
    let status = Command::new("rsync")
        .arg("-a")
        .arg("--quiet")
        .arg("--exclude")
        .arg("backup_*")
        .arg("--exclude")
        .arg(".git")
        .arg("--exclude")
        .arg("htdocs")
        .arg("--exclude")
        .arg("logs")
        .arg("--exclude")
        .arg("volumes")
        .arg(format!("{}/", project_dir.display()))
        .arg(format!("{}/", backup_dir.display()))
        .status()
        .context("Failed to run rsync for backup")?;

    if !status.success() {
        ui::critical("Backup failed!");
    }

    ui::info("Applying template changes...");
    // Sync from template to project
    let status = Command::new("rsync")
        .arg("-a")
        .arg("--quiet")
        .arg("--exclude")
        .arg("logs")
        .arg("--exclude")
        .arg("volumes")
        .arg(format!("{}/", template_dir.display()))
        .arg(format!("{}/", project_dir.display()))
        .status()
        .context("Failed to run rsync for template sync")?;

    if !status.success() {
        ui::critical("Template sync failed!");
    }

    // Merge .gitignore
    let gitignore_dist = project_dir.join(".gitignore-dist");
    let gitignore = project_dir.join(".gitignore");

    if gitignore_dist.exists() {
        let mut content = fs::read_to_string(&gitignore).unwrap_or_default();
        let dist_content = fs::read_to_string(&gitignore_dist)?;
        content.push('\n');
        content.push_str(&dist_content);

        let mut lines: Vec<String> = content
            .lines()
            .map(|s| s.to_string())
            .filter(|s| !s.is_empty())
            .collect();
        lines.sort();
        lines.dedup();

        fs::write(&gitignore, lines.join("\n"))?;
        fs::remove_file(gitignore_dist)?;
    }

    ui::success("Project updated successfully.");

    Ok(())
}
