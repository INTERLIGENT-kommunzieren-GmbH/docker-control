use crate::git::GitService;
use crate::ui;
use anyhow::{Result, anyhow};
use inquire::{Confirm, Select};
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

struct WorktreeCleanup<'a> {
    git_path: &'a Path,
    worktree_path: PathBuf,
    active: bool,
}

impl<'a> WorktreeCleanup<'a> {
    fn new(git_path: &'a Path, worktree_path: PathBuf) -> Self {
        Self {
            git_path,
            worktree_path,
            active: true,
        }
    }

    #[allow(dead_code)]
    fn cancel(&mut self) {
        self.active = false;
    }
}

impl<'a> Drop for WorktreeCleanup<'a> {
    fn drop(&mut self) {
        if self.active && self.worktree_path.exists() {
            let _ = Command::new("git")
                .arg("-C")
                .arg(self.git_path)
                .arg("worktree")
                .arg("remove")
                .arg("--force")
                .arg(&self.worktree_path)
                .status();
        }
    }
}

pub fn execute(project_dir: &Path, module: Option<String>) -> Result<()> {
    let mut selected_module = module;

    // Module selection logic
    if selected_module.is_none() {
        let vendor_modules = GitService::list_vendor_modules(project_dir)?;
        if !vendor_modules.is_empty() {
            let mut options = vec!["Main Project".to_string()];
            options.extend(vendor_modules);

            let selection =
                Select::new("Select project or vendor module for release", options).prompt()?;
            if selection != "Main Project" {
                selected_module = Some(selection);
            }
        }
    }

    let git_path = if let Some(m) = &selected_module {
        project_dir.join("htdocs/vendor").join(m)
    } else {
        project_dir.join("htdocs")
    };

    if !git_path.exists() {
        return Err(anyhow!("Git directory not found: {:?}", git_path));
    }

    if !git_path.join(".git").exists() {
        return Err(anyhow!("{:?} is not a git repository", git_path));
    }

    let git = GitService::open(&git_path)?;
    ui::info(format!("Starting release creation for: {:?}", git_path));

    // Pre-flight checks
    ui::info("Performing pre-flight checks...");
    git.fetch_all()?;
    let primary_branch = git.get_primary_branch()?;
    git.update_branch(&primary_branch)?;

    let branches = git.list_release_branches()?;

    let (release, release_type) = if branches.is_empty() {
        ui::info("No existing release branches found. Creating initial release 1.0.x...");
        ("1.0.x".to_string(), "INITIAL")
    } else {
        let is_breaking = Confirm::new("Is this a Breaking Change?")
            .with_default(false)
            .prompt()?;

        if is_breaking {
            (get_next_major(&branches)?, "MAJOR")
        } else {
            let is_feature = Confirm::new("Is this a new Feature?")
                .with_default(false)
                .prompt()?;

            if is_feature {
                (get_next_minor(&branches)?, "MINOR")
            } else {
                let selected_branch =
                    Select::new("Select branch for patch release", branches).prompt()?;
                (get_next_patch(&git, &selected_branch)?, "PATCH")
            }
        }
    };

    ui::info(format!("Selected release: {}", release));

    if release_type == "PATCH" {
        // For patch, we create a tag on an existing branch
        let mut parts = release.split('.');
        let major = parts.next().unwrap();
        let minor = parts.next().unwrap();
        let branch = format!("{}.{}.x", major, minor);
        create_patch_tag(
            project_dir,
            &git_path,
            &git,
            &branch,
            &release,
            selected_module.as_deref(),
        )?;
    } else {
        // For initial, major, minor, we create a new branch
        create_release_branch(
            project_dir,
            &git_path,
            &git,
            &release,
            &primary_branch,
            selected_module.as_deref(),
        )?;
    }

    ui::success("=== Release Creation Complete ===".to_string());
    ui::success(format!(
        "✓ Release '{}' has been successfully created",
        release
    ));

    Ok(())
}

fn create_release_branch(
    project_dir: &Path,
    git_path: &Path,
    git: &GitService,
    version: &str,
    primary_branch: &str,
    module: Option<&str>,
) -> Result<()> {
    let worktree_base = if let Some(m) = module {
        project_dir.join("releases/vendor").join(m)
    } else {
        project_dir.join("releases")
    };
    let worktree_dir = worktree_base.join(version);
    fs::create_dir_all(&worktree_base)?;

    ui::info(format!(
        "Creating release branch {} in worktree...",
        version
    ));

    // Create worktree natively if possible, or use Command if GitService doesn't support it yet
    // GitService doesn't have worktree support yet, but we can add it or keep Command for now.
    // Given the requirement to replace external dependencies where possible, I should check if git2 supports worktrees.
    // git2 does support worktrees.
    git.create_worktree(version, &worktree_dir, Some(primary_branch))?;

    let _cleanup = WorktreeCleanup::new(git_path, worktree_dir.clone());

    // Update composer.json version
    update_composer_version(&worktree_dir, version)?;

    // Commit composer.json update
    let worktree_git = GitService::open(&worktree_dir)?;
    if let Err(e) = worktree_git.add_file(Path::new("composer.json")) {
        ui::warning(format!("Failed to add composer.json: {}", e));
    } else if let Err(e) = worktree_git.commit(&format!(
        "release: Updated version in composer.json for {}",
        version
    )) {
        ui::warning(format!("Failed to commit composer.json: {}", e));
    }

    // Create composer.lock via Docker
    execute_composer_install(project_dir, &worktree_dir)?;

    // Commit composer.lock
    if let Err(e) = worktree_git.add_file(Path::new("composer.lock")) {
        ui::warning(format!("Failed to add composer.lock: {}", e));
    } else if let Err(e) =
        worktree_git.commit(&format!("release: Add composer.lock for {}", version))
    {
        ui::warning(format!("Failed to commit composer.lock: {}", e));
    }

    // Generate changelog
    generate_changelog(git, &worktree_dir, version, primary_branch, true)?;

    // Push branch
    ui::info(format!("Pushing release branch {} to origin...", version));
    worktree_git.push_branch(version)?;

    Ok(())
}

fn create_patch_tag(
    project_dir: &Path,
    git_path: &Path,
    git: &GitService,
    branch: &str,
    tag: &str,
    module: Option<&str>,
) -> Result<()> {
    let worktree_base = if let Some(m) = module {
        project_dir.join("releases/vendor").join(m)
    } else {
        project_dir.join("releases")
    };
    let worktree_dir = worktree_base.join(branch);
    fs::create_dir_all(&worktree_base)?;

    ui::info(format!(
        "Creating worktree for branch {} to create tag {}...",
        branch, tag
    ));

    // Check if worktree already exists, if not create it
    if !worktree_dir.exists() {
        git.create_worktree(branch, &worktree_dir, Some(branch))?;
    }
    let _cleanup = WorktreeCleanup::new(git_path, worktree_dir.clone());

    let worktree_git = GitService::open(&worktree_dir)?;

    // Sync with origin
    ui::info(format!("Pulling latest changes for branch {}...", branch));
    worktree_git.pull(branch)?;

    // Update composer.json version
    update_composer_version(&worktree_dir, tag)?;

    // Commit composer.json update
    if let Err(e) = worktree_git.add_file(Path::new("composer.json")) {
        ui::warning(format!("Failed to add composer.json: {}", e));
    } else if let Err(e) = worktree_git.commit(&format!(
        "release: Updated version in composer.json for {}",
        tag
    )) {
        ui::warning(format!("Failed to commit composer.json: {}", e));
    }

    // Generate changelog
    generate_changelog(git, &worktree_dir, tag, branch, false)?;

    // Create tag
    ui::info(format!("Creating tag {}...", tag));
    if let Err(e) = worktree_git.create_tag_on_head(tag, &format!("Release {}", tag)) {
        return Err(anyhow!("Failed to create tag {}: {}", tag, e));
    }

    // Push tag
    ui::info(format!("Pushing tag {} to origin...", tag));
    worktree_git.push_tag(tag)?;

    Ok(())
}

fn update_composer_version(worktree_dir: &Path, version: &str) -> Result<()> {
    let composer_path = worktree_dir.join("composer.json");
    if !composer_path.exists() {
        return Ok(());
    }

    let composer_version = if version.ends_with(".x") && !version.ends_with("-dev") {
        format!("{}-dev", version)
    } else {
        version.to_string()
    };

    ui::info(format!(
        "Updating version in composer.json to {}...",
        composer_version
    ));
    let content = fs::read_to_string(&composer_path)?;
    let mut json: Value = serde_json::from_str(&content)?;

    if let Some(obj) = json.as_object_mut() {
        obj.insert("version".to_string(), Value::String(composer_version));
    }

    let updated_content = serde_json::to_string_pretty(&json)?;
    fs::write(composer_path, updated_content)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn test_update_composer_version() -> Result<()> {
        let root = std::env::temp_dir().join("docker-control-test-composer");
        if root.exists() {
            fs::remove_dir_all(&root)?;
        }
        fs::create_dir_all(&root)?;

        let composer_path = root.join("composer.json");

        // Test with .x version
        let initial_json = r#"{"name": "test/project", "version": "1.0.0"}"#;
        fs::write(&composer_path, initial_json)?;

        update_composer_version(&root, "9.0.x")?;

        let updated_content = fs::read_to_string(&composer_path)?;
        let updated_json: Value = serde_json::from_str(&updated_content)?;
        assert_eq!(updated_json["version"], "9.0.x-dev");

        // Test with tag version (no .x)
        update_composer_version(&root, "9.0.1")?;
        let updated_content = fs::read_to_string(&composer_path)?;
        let updated_json: Value = serde_json::from_str(&updated_content)?;
        assert_eq!(updated_json["version"], "9.0.1");

        // Test with already -dev version
        update_composer_version(&root, "9.0.x-dev")?;
        let updated_content = fs::read_to_string(&composer_path)?;
        let updated_json: Value = serde_json::from_str(&updated_content)?;
        assert_eq!(updated_json["version"], "9.0.x-dev");

        // Cleanup
        let _ = fs::remove_dir_all(&root);

        Ok(())
    }
}

fn execute_composer_install(project_dir: &Path, worktree_dir: &Path) -> Result<()> {
    if !worktree_dir.join("composer.json").exists() {
        return Ok(());
    }

    ui::info("Generating composer.lock via Docker...");

    // Load PHP_VERSION from .env
    let env_content = fs::read_to_string(project_dir.join(".env")).unwrap_or_default();
    let php_version = env_content
        .lines()
        .find(|l| l.starts_with("PHP_VERSION="))
        .map(|l| l.split('=').nth(1).unwrap_or("8.2"))
        .unwrap_or("8.2");

    let ssh_auth_port = std::env::var("SSH_AUTH_PORT")
        .unwrap_or_else(|_| "host.docker.internal:2222".to_string());

    let status = Command::new("docker")
        .arg("run")
        .arg("--rm")
        .arg("-u")
        .arg(format!("{}:{}", unsafe { libc::getuid() }, unsafe {
            libc::getgid()
        }))
        .arg("-e")
        .arg(format!("SSH_AUTH_PORT={}", ssh_auth_port))
        .arg("-e")
        .arg("SSH_AUTH_SOCK=/tmp/ssh-agent.sock")
        .arg("--add-host")
        .arg("host.docker.internal:host-gateway")
        .arg("-v")
        .arg(format!("{}:/var/www/html", worktree_dir.to_string_lossy()))
        .arg(format!("fduarte42/docker-php:{}", php_version))
        .arg("bash")
        .arg("-c")
        .arg("/docker-php-init; composer i -o")
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()?;

    if !status.success() {
        return Err(anyhow!("Composer install failed"));
    }

    // Cleanup vendor
    let _ = fs::remove_dir_all(worktree_dir.join("vendor"));

    Ok(())
}

fn generate_changelog(
    git: &GitService,
    worktree_dir: &Path,
    version: &str,
    base: &str,
    is_new_branch: bool,
) -> Result<()> {
    ui::info("Generating changelog...");
    let changelog_path = worktree_dir.join("CHANGELOG.md");

    let commits = if is_new_branch {
        // Find highest existing release branch
        let branches = git.list_release_branches()?;
        let other_branches: Vec<_> = branches.iter().filter(|b| *b != version).collect();

        if let Some(highest) = other_branches.last() {
            let merge_base = git.get_merge_base(highest, base)?;
            git.get_commits_between_range(&format!("{}..{}", merge_base, base))?
        } else {
            git.get_commits_between_range(base)?
        }
    } else {
        // For patch, between last tag and current branch
        let tags = git.list_tags()?;
        let prefix = version.split('.').take(2).collect::<Vec<_>>().join(".");
        let matching_tags: Vec<_> = tags.iter().filter(|t| t.starts_with(&prefix)).collect();

        if let Some(last_tag) = matching_tags.last() {
            git.get_commits_between_range(&format!("{}..{}", last_tag, base))?
        } else {
            git.get_commits_between_range(base)?
        }
    };

    let mut changelog_content = String::new();
    for (hash, summary) in commits {
        changelog_content.push_str(&format!("* {} - {}\n", &hash[..8], summary));
    }

    if changelog_content.is_empty() {
        changelog_content = "* No significant changes recorded\n".to_string();
    }

    let mut full_changelog = if changelog_path.exists() {
        fs::read_to_string(&changelog_path)?
    } else {
        "# Changelog\n\nAll notable changes to this project will be documented in this file.\n\nThe format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),\nand this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).\n\n".to_string()
    };

    let new_section = if is_new_branch {
        format!(
            "## [Unreleased] - Release branch {}\n\n### Changes planned for this release:\n\n{}\n",
            version, changelog_content
        )
    } else {
        let date = chrono::Local::now().format("%Y-%m-%d").to_string();
        format!("## [{}] - {}\n\n{}\n", version, date, changelog_content)
    };

    // Insert new section after header
    if let Some(pos) = full_changelog.find("## [") {
        full_changelog.insert_str(pos, &format!("{}\n", new_section));
    } else {
        full_changelog.push_str(&new_section);
    }

    fs::write(&changelog_path, &full_changelog)?;

    // Open for editing
    let editor = std::env::var("EDITOR").unwrap_or_else(|_| "nano".to_string());
    let _ = Command::new(editor)
        .arg(&changelog_path)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status();

    // Commit changelog
    let worktree_git = GitService::open(worktree_dir)?;
    if let Err(e) = worktree_git.add_file(Path::new("CHANGELOG.md")) {
        ui::warning(format!("Failed to add CHANGELOG.md: {}", e));
    } else if let Err(e) = worktree_git.commit("release: update changelog") {
        ui::warning(format!("Failed to commit changelog: {}", e));
    }

    Ok(())
}

fn get_next_major(branches: &[String]) -> Result<String> {
    let latest = branches
        .last()
        .ok_or_else(|| anyhow!("No branches found"))?;
    let parts: Vec<&str> = latest.split('.').collect();
    let major: u32 = parts[0].parse()?;
    Ok(format!("{}.0.x", major + 1))
}

fn get_next_minor(branches: &[String]) -> Result<String> {
    let latest = branches
        .last()
        .ok_or_else(|| anyhow!("No branches found"))?;
    let parts: Vec<&str> = latest.split('.').collect();
    let major: u32 = parts[0].parse()?;
    let minor: u32 = parts[1].parse()?;
    Ok(format!("{}.{}.x", major, minor + 1))
}

fn get_next_patch(git: &GitService, branch: &str) -> Result<String> {
    let tags = git.list_tags()?;
    let prefix = branch
        .strip_suffix("x")
        .ok_or_else(|| anyhow!("Invalid branch name: {}", branch))?;

    let mut patches: Vec<u32> = tags
        .iter()
        .filter(|t| t.starts_with(prefix))
        .filter_map(|t| t.strip_prefix(prefix).and_then(|p| p.parse::<u32>().ok()))
        .collect();

    patches.sort();
    let next_patch = patches.last().map(|p| p + 1).unwrap_or(0);
    Ok(format!("{}{}", prefix, next_patch))
}
