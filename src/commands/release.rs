use crate::git::GitService;
use crate::ui;
use anyhow::{anyhow, Result};
use inquire::{Confirm, Select};
use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

pub trait PromptProvider {
    fn confirm_breaking_change(&self) -> Result<bool>;
    fn confirm_new_feature(&self) -> Result<bool>;
    fn select_patch_branch(&self, branches: Vec<String>) -> Result<String>;
    fn select_module(&self, modules: Vec<String>) -> Result<String>;
}

pub struct InteractivePromptProvider;

impl PromptProvider for InteractivePromptProvider {
    fn confirm_breaking_change(&self) -> Result<bool> {
        Ok(Confirm::new("Is this a Breaking Change?")
            .with_default(false)
            .prompt()?)
    }

    fn confirm_new_feature(&self) -> Result<bool> {
        Ok(Confirm::new("Is this a new Feature?")
            .with_default(false)
            .prompt()?)
    }

    fn select_patch_branch(&self, branches: Vec<String>) -> Result<String> {
        Ok(Select::new("Select branch for patch release", branches).prompt()?)
    }

    fn select_module(&self, modules: Vec<String>) -> Result<String> {
        Ok(Select::new("Select project or vendor module for release", modules).prompt()?)
    }
}

pub struct ReleaseOptions {
    pub prompt_provider: Box<dyn PromptProvider>,
    pub skip_composer: bool,
    pub keep_worktree: bool,
}

impl Default for ReleaseOptions {
    fn default() -> Self {
        Self {
            prompt_provider: Box::new(InteractivePromptProvider),
            skip_composer: false,
            keep_worktree: false,
        }
    }
}

struct WorktreeCleanup<'a> {
    git_path: &'a Path,
    worktree_path: PathBuf,
    active: bool,
}

impl<'a> WorktreeCleanup<'a> {
    fn new(git_path: &'a Path, worktree_path: PathBuf, active: bool) -> Self {
        Self {
            git_path,
            worktree_path,
            active,
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

pub fn execute(
    project_dir: &Path,
    module: Option<String>,
    options: ReleaseOptions,
) -> Result<()> {
    let mut selected_module = module;

    // Module selection logic
    if selected_module.is_none() {
        let vendor_modules = GitService::list_vendor_modules(project_dir)?;
        if !vendor_modules.is_empty() {
            let mut opts = vec!["Main Project".to_string()];
            opts.extend(vendor_modules);

            let selection = options.prompt_provider.select_module(opts)?;
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
        let is_breaking = options.prompt_provider.confirm_breaking_change()?;

        if is_breaking {
            (get_next_major(&branches)?, "MAJOR")
        } else {
            let is_feature = options.prompt_provider.confirm_new_feature()?;

            if is_feature {
                (get_next_minor(&branches)?, "MINOR")
            } else {
                let selected_branch = options.prompt_provider.select_patch_branch(branches)?;
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
            &options,
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
            &options,
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
    options: &ReleaseOptions,
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

    git.create_worktree(version, &worktree_dir, Some(primary_branch))?;

    let _cleanup = WorktreeCleanup::new(git_path, worktree_dir.clone(), !options.keep_worktree);

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
    execute_composer_install(project_dir, &worktree_dir, options)?;

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
    options: &ReleaseOptions,
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
    let _cleanup = WorktreeCleanup::new(git_path, worktree_dir.clone(), !options.keep_worktree);

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

pub fn update_composer_version(worktree_dir: &Path, version: &str) -> Result<()> {
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

fn execute_composer_install(
    project_dir: &Path,
    worktree_dir: &Path,
    options: &ReleaseOptions,
) -> Result<()> {
    if options.skip_composer {
        ui::info("Skipping composer install (mocked/test mode)");
        return Ok(());
    }

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
            // Fallback to latest tag if no release branches found
            let tags = git.list_tags()?;
            if let Some(last_tag) = tags.last() {
                git.get_commits_between_range(&format!("{}..{}", last_tag, base))?
            } else {
                git.get_all_commits_from(base)?
            }
        }
    } else {
        // For patch, between last tag and current branch
        let tags = git.list_tags()?;
        let prefix = version.split('.').take(2).collect::<Vec<_>>().join(".");
        let matching_tags: Vec<_> = tags.iter().filter(|t| t.starts_with(&prefix)).collect();

        if let Some(last_tag) = matching_tags.last() {
            git.get_commits_between_range(&format!("{}..{}", last_tag, base))?
        } else {
            git.get_all_commits_from(base)?
        }
    };

    let mut changelog_content = String::new();
    for (hash, summary) in commits {
        changelog_content.push_str(&format!("* {} ({})\n", summary, hash));
    }

    if changelog_path.exists() {
        let existing = fs::read_to_string(&changelog_path)?;
        changelog_content.push('\n');
        changelog_content.push_str(&existing);
    }

    fs::write(
        changelog_path,
        format!("## Release {}\n\n{}", version, changelog_content),
    )?;
    Ok(())
}

fn get_next_major(branches: &[String]) -> Result<String> {
    let mut majors: Vec<u32> = branches
        .iter()
        .filter_map(|b| b.split('.').next()?.parse().ok())
        .collect();
    majors.sort();
    let next_major = majors.last().unwrap_or(&0) + 1;
    Ok(format!("{}.0.x", next_major))
}

fn get_next_minor(branches: &[String]) -> Result<String> {
    // Find highest major
    let mut majors: Vec<u32> = branches
        .iter()
        .filter_map(|b| b.split('.').next()?.parse().ok())
        .collect();
    majors.sort();
    let highest_major = majors.last().ok_or_else(|| anyhow!("No branches found"))?;

    let mut minors: Vec<u32> = branches
        .iter()
        .filter(|b| b.starts_with(&format!("{}.", highest_major)))
        .filter_map(|b| b.split('.').nth(1)?.parse().ok())
        .collect();
    minors.sort();
    let next_minor = minors.last().unwrap_or(&0) + 1;
    Ok(format!("{}.{}.x", highest_major, next_minor))
}

fn get_next_patch(git: &GitService, branch: &str) -> Result<String> {
    let tags = git.list_tags()?;
    let prefix = branch.trim_end_matches(".x");
    let mut patches: Vec<u32> = tags
        .iter()
        .filter(|t| t.starts_with(prefix))
        .filter_map(|t| t.split('.').nth(2)?.parse().ok())
        .collect();
    patches.sort();
    let next_patch = patches.last().map(|p| p + 1).unwrap_or(0);
    Ok(format!("{}.{}", prefix, next_patch))
}
