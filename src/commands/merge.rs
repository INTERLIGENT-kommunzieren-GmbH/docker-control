use crate::git::GitService;
use crate::ui;
use anyhow::{Result, anyhow};
use inquire::{Confirm, Select};
use std::path::{Path, PathBuf};
use std::process::Command;

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
                Select::new("Select project or vendor module to merge", options).prompt()?;
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
    ui::info(format!("Starting merge workflow for: {:?}", git_path));

    // Phase 1: Pre-flight checks
    ui::info("Performing pre-flight checks...");
    git.fetch_all()?;
    let primary_branch = git.get_primary_branch()?;
    let branches = git.list_release_branches()?;

    if branches.is_empty() {
        return Err(anyhow!("No release branches found to merge."));
    }

    let release_branch = Select::new("Select release branch to merge", branches).prompt()?;

    // Update branches
    ui::info(format!(
        "Updating branches {} and {}...",
        release_branch, primary_branch
    ));
    git.update_branch(&release_branch)?;
    git.update_branch(&primary_branch)?;

    let merge_branch = format!("{}-merge", release_branch);
    ui::info(format!("Merge branch: {}", merge_branch));

    // Check if merge branch already exists
    let output = Command::new("git")
        .arg("-C")
        .arg(&git_path)
        .arg("rev-parse")
        .arg("--verify")
        .arg(&merge_branch)
        .output()?;

    if output.status.success() {
        return Err(anyhow!(
            "Merge branch '{}' already exists! Please resolve this before proceeding.",
            merge_branch
        ));
    }

    // Set up worktree paths
    let worktree_base = if let Some(m) = &selected_module {
        project_dir.join("releases/vendor").join(m)
    } else {
        project_dir.join("releases")
    };

    let release_wt_path = worktree_base.join(&release_branch);
    let merge_wt_path = worktree_base.join(&merge_branch);

    std::fs::create_dir_all(&worktree_base)?;

    ui::info("Creating separate worktrees for source and merge branches...");

    // Release worktree
    let status = Command::new("git")
        .arg("-C")
        .arg(&git_path)
        .arg("worktree")
        .arg("add")
        .arg(&release_wt_path)
        .arg(&release_branch)
        .status()?;

    if !status.success() {
        return Err(anyhow!("Failed to create release worktree"));
    }
    let _release_cleanup = WorktreeCleanup::new(&git_path, release_wt_path.clone());

    // Merge worktree (created from primary branch)
    let status = Command::new("git")
        .arg("-C")
        .arg(&git_path)
        .arg("worktree")
        .arg("add")
        .arg("-b")
        .arg(&merge_branch)
        .arg(&merge_wt_path)
        .arg(format!("origin/{}", primary_branch))
        .status()?;

    if !status.success() {
        return Err(anyhow!("Failed to create merge worktree"));
    }
    let mut merge_cleanup = WorktreeCleanup::new(&git_path, merge_wt_path.clone());

    // Get commits to cherry-pick
    let commits = git.get_commits_between(&primary_branch, &release_branch)?;

    if commits.is_empty() {
        ui::info("No new commits found to merge.");
        return Ok(());
    }

    ui::info(format!(
        "Found {} commits to cherry-pick into {}:",
        commits.len(),
        merge_branch
    ));
    for (hash, summary) in &commits {
        ui::info(format!("  • {} - {}", &hash[..8], summary));
    }

    if !Confirm::new("Proceed with cherry-picking these commits?")
        .with_default(true)
        .prompt()?
    {
        ui::info("Merge cancelled.");
        return Ok(());
    }

    for (hash, summary) in commits {
        ui::info(format!("Cherry-picking {} - {}...", &hash[..8], summary));

        let status = Command::new("git")
            .arg("-C")
            .arg(&merge_wt_path)
            .arg("cherry-pick")
            .arg(&hash)
            .status()?;

        if !status.success() {
            ui::critical(format!(
                "Cherry-pick failed for commit {}. Conflict detected.",
                &hash[..8]
            ));

            loop {
                let choice = Select::new(
                    "Conflict resolution",
                    vec!["Start merge tool", "I have resolved it", "Abort"],
                )
                .prompt()?;

                match choice {
                    "Start merge tool" => {
                        let _ = Command::new("git")
                            .arg("-C")
                            .arg(&merge_wt_path)
                            .arg("mergetool")
                            .status();
                    }
                    "I have resolved it" => {
                        // Check if conflicts still exist
                        let output = Command::new("git")
                            .arg("-C")
                            .arg(&merge_wt_path)
                            .arg("status")
                            .arg("--porcelain")
                            .output()?;
                        let stdout = String::from_utf8_lossy(&output.stdout);
                        if stdout.contains("UU") || stdout.contains("AA") || stdout.contains("DD") {
                            ui::warning("Conflicts still exist in the following files:");
                            for line in stdout.lines() {
                                if line.starts_with("UU")
                                    || line.starts_with("AA")
                                    || line.starts_with("DD")
                                {
                                    ui::info(format!("  • {}", &line[3..]));
                                }
                            }
                            continue;
                        }

                        // Commit the resolution
                        let _ = Command::new("git")
                            .arg("-C")
                            .arg(&merge_wt_path)
                            .arg("cherry-pick")
                            .arg("--continue")
                            .env("GIT_EDITOR", "true") // avoid opening editor if possible
                            .status();
                        break;
                    }
                    _ => {
                        let _ = Command::new("git")
                            .arg("-C")
                            .arg(&merge_wt_path)
                            .arg("cherry-pick")
                            .arg("--abort")
                            .status();
                        return Err(anyhow!("Merge aborted by user due to conflicts."));
                    }
                }
            }
        }
    }

    ui::success(format!(
        "Successfully prepared merge branch: {}",
        merge_branch
    ));

    if Confirm::new(&format!("Push merge branch {} to remote?", merge_branch))
        .with_default(true)
        .prompt()?
    {
        ui::info(format!(
            "Pushing merge branch {} to remote repository...",
            merge_branch
        ));
        let status = Command::new("git")
            .arg("-C")
            .arg(&merge_wt_path)
            .arg("push")
            .arg("-u")
            .arg("origin")
            .arg(&merge_branch)
            .status()?;

        if status.success() {
            ui::success(format!(
                "Successfully pushed merge branch {} to remote repository",
                merge_branch
            ));
            ui::info("=== Merge Request Information ===");
            ui::info(format!(
                "Merge branch '{}' has been created and pushed to remote repository",
                merge_branch
            ));
            ui::info(format!("Source branch: {}", merge_branch));
            ui::info(format!("Target branch: {}", primary_branch));
            ui::info("\nNext steps:");
            ui::info("1. Go to your Git hosting service web interface");
            ui::info(format!(
                "2. Create a merge/pull request from '{}' to '{}'",
                merge_branch, primary_branch
            ));
            ui::info("3. Review the changes and merge when ready");

            // Cleanup on success: worktrees and local merge branch
            // _release_cleanup and merge_cleanup will remove worktrees on drop
            // We also need to remove the local branch from the main repo
            let _ = Command::new("git")
                .arg("-C")
                .arg(&git_path)
                .arg("branch")
                .arg("-D")
                .arg(&merge_branch)
                .status();
        } else {
            ui::critical("Failed to push merge branch to remote repository");
            ui::info("The local merge branch has been preserved for manual investigation:");
            ui::info(format!("  - Merge branch: {}", merge_branch));
            ui::info(format!("  - Worktree location: {:?}", merge_wt_path));

            // Cancel cleanup for merge worktree so user can investigate
            merge_cleanup.cancel();
            return Err(anyhow!("Failed to push merge branch to remote."));
        }
    } else {
        ui::info("Push cancelled. Local merge branch preserved:");
        ui::info(format!("  - Merge branch: {}", merge_branch));
        ui::info(format!("  - Worktree location: {:?}", merge_wt_path));
        merge_cleanup.cancel();
    }

    Ok(())
}
