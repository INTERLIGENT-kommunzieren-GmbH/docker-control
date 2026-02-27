use anyhow::{Context, Result, anyhow};
use git2::{BranchType, Repository};
use std::path::Path;

pub struct GitService {
    repo: Repository,
}

impl GitService {
    pub fn open(path: &Path) -> Result<Self> {
        let repo = Repository::open(path)
            .context(format!("Failed to open git repository at {:?}", path))?;
        Ok(Self { repo })
    }

    pub fn get_current_branch(&self) -> Result<String> {
        let head = self.repo.head().context("Failed to get HEAD")?;
        let branch = head
            .shorthand()
            .ok_or_else(|| anyhow!("HEAD is not a branch"))?;
        Ok(branch.to_string())
    }

    pub fn list_release_branches(&self) -> Result<Vec<String>> {
        let mut branches = Vec::new();
        let local_branches = self.repo.branches(Some(BranchType::Local))?;

        for branch in local_branches {
            let (branch, _) = branch?;
            if let Some(name) = branch.name()? {
                if is_release_branch_name(name) {
                    branches.push(name.to_string());
                }
            }
        }

        // Also check remote branches
        let remote_branches = self.repo.branches(Some(BranchType::Remote))?;
        for branch in remote_branches {
            let (branch, _) = branch?;
            if let Some(name) = branch.name()? {
                // Strip remote prefix (e.g., origin/)
                if let Some(short_name) = name.split('/').next_back() {
                    if is_release_branch_name(short_name)
                        && !branches.contains(&short_name.to_string())
                    {
                        branches.push(short_name.to_string());
                    }
                }
            }
        }

        branches.sort();
        Ok(branches)
    }

    #[allow(dead_code)]
    pub fn create_branch(&self, name: &str, target: &str) -> Result<()> {
        let obj = self.repo.revparse_single(target)?;
        let commit = obj
            .as_commit()
            .ok_or_else(|| anyhow!("Target is not a commit"))?;
        self.repo.branch(name, commit, false)?;
        Ok(())
    }

    #[allow(dead_code)]
    pub fn checkout_branch(&self, name: &str) -> Result<()> {
        let obj = self.repo.revparse_single(name)?;
        self.repo.checkout_tree(&obj, None)?;
        self.repo.set_head(&format!("refs/heads/{}", name))?;
        Ok(())
    }

    pub fn get_commits_between_range(&self, range: &str) -> Result<Vec<(String, String)>> {
        let mut revwalk = self.repo.revwalk()?;
        revwalk.push_range(range)?;
        revwalk.set_sorting(git2::Sort::REVERSE)?;

        let mut commits = Vec::new();
        for id in revwalk {
            let id = id?;
            let commit = self.repo.find_commit(id)?;
            let summary = commit.summary().unwrap_or("").to_string();

            // Filter out "release:" commits
            if !summary.starts_with("release:") {
                commits.push((id.to_string(), summary));
            }
        }
        Ok(commits)
    }

    pub fn list_tags(&self) -> Result<Vec<String>> {
        let mut tags = Vec::new();
        self.repo.tag_foreach(|_id, name| {
            if let Ok(name_str) = std::str::from_utf8(name) {
                // name is refs/tags/v1.0.0
                let short_name = name_str.strip_prefix("refs/tags/").unwrap_or(name_str);
                tags.push(short_name.to_string());
            }
            true
        })?;
        tags.sort();
        Ok(tags)
    }

    pub fn get_merge_base(&self, one: &str, two: &str) -> Result<String> {
        let obj1 = self.repo.revparse_single(one)?;
        let obj2 = self.repo.revparse_single(two)?;
        let base = self.repo.merge_base(obj1.id(), obj2.id())?;
        Ok(base.to_string())
    }

    pub fn get_commits_between(&self, from: &str, to: &str) -> Result<Vec<(String, String)>> {
        let mut revwalk = self.repo.revwalk()?;
        revwalk.push_range(&format!("{}..{}", from, to))?;
        revwalk.set_sorting(git2::Sort::REVERSE)?;

        let mut commits = Vec::new();
        for id in revwalk {
            let id = id?;
            let commit = self.repo.find_commit(id)?;
            let summary = commit.summary().unwrap_or("").to_string();

            // Filter out "release:" commits as per bash implementation
            if !summary.starts_with("release:") {
                commits.push((id.to_string(), summary));
            }
        }
        Ok(commits)
    }

    #[allow(dead_code)]
    pub fn cherry_pick(&self, commit_hash: &str) -> Result<()> {
        let obj = self.repo.revparse_single(commit_hash)?;
        let commit = obj.as_commit().ok_or_else(|| anyhow!("Not a commit"))?;

        // Using git2 cherry-pick is complex for handling index/workdir
        // For simplicity and matching bash behavior, we use system git if available,
        // or attempt git2 if we want to stay pure.
        // Given the requirement for interactive conflict resolution in merge.rs,
        // we'll likely use Command in merge.rs, but let's provide a basic git2 version here.
        self.repo.cherrypick(commit, None)?;

        let index = self.repo.index()?;
        if index.has_conflicts() {
            return Err(anyhow!(
                "Cherry-pick resulted in conflicts for commit {}",
                commit_hash
            ));
        }

        // If no conflicts, we need to commit the changes
        // This is simplified; real implementation would need more logic
        Ok(())
    }

    #[allow(dead_code)]
    pub fn create_tag(&self, name: &str, message: &str) -> Result<()> {
        let head = self.repo.head()?.peel_to_commit()?;
        let sig = self.repo.signature()?;
        self.repo
            .tag(name, head.as_object(), &sig, message, false)?;
        Ok(())
    }

    pub fn get_primary_branch(&self) -> Result<String> {
        if self.repo.find_branch("main", BranchType::Local).is_ok() {
            Ok("main".to_string())
        } else if self.repo.find_branch("master", BranchType::Local).is_ok() {
            Ok("master".to_string())
        } else {
            // Check remote
            if self
                .repo
                .find_branch("origin/main", BranchType::Remote)
                .is_ok()
            {
                Ok("main".to_string())
            } else if self
                .repo
                .find_branch("origin/master", BranchType::Remote)
                .is_ok()
            {
                Ok("master".to_string())
            } else {
                Err(anyhow!("Could not determine primary branch (main/master)"))
            }
        }
    }

    pub fn fetch_all(&self) -> Result<()> {
        let mut remote = self.repo.find_remote("origin")?;
        remote.fetch(&["+refs/heads/*:refs/remotes/origin/*"], None, None)?;
        Ok(())
    }

    pub fn update_branch(&self, branch_name: &str) -> Result<()> {
        // If branch doesn't exist locally, create it from origin
        if self
            .repo
            .find_branch(branch_name, BranchType::Local)
            .is_err()
        {
            if let Ok(remote_branch) = self
                .repo
                .find_branch(&format!("origin/{}", branch_name), BranchType::Remote)
            {
                let target_commit = remote_branch.get().peel_to_commit()?;
                self.repo.branch(branch_name, &target_commit, false)?;
            } else {
                return Err(anyhow!(
                    "Branch {} not found locally or on origin",
                    branch_name
                ));
            }
        }

        // Fast-forward local branch to match origin
        let mut local_branch = self.repo.find_branch(branch_name, BranchType::Local)?;
        let remote_branch = self
            .repo
            .find_branch(&format!("origin/{}", branch_name), BranchType::Remote)?;
        let remote_target = remote_branch.get().peel_to_commit()?;

        let ref_ = local_branch.get_mut();
        ref_.set_target(remote_target.id(), "Fast-forwarding to origin")?;

        Ok(())
    }

    pub fn list_vendor_modules(project_dir: &Path) -> Result<Vec<String>> {
        let vendor_dir = project_dir.join("htdocs/vendor");
        if !vendor_dir.exists() {
            return Ok(Vec::new());
        }

        let mut modules = Vec::new();
        // Vendor modules are usually in htdocs/vendor/vendor-name/module-name
        // We look for .git directories in subdirectories
        for entry in std::fs::read_dir(&vendor_dir)? {
            let entry = entry?;
            let path = entry.path();
            if path.is_dir() {
                for sub_entry in std::fs::read_dir(&path)? {
                    let sub_entry = sub_entry?;
                    let sub_path = sub_entry.path();
                    if sub_path.is_dir() && sub_path.join(".git").exists() {
                        if let (Some(vendor), Some(module)) =
                            (path.file_name(), sub_path.file_name())
                        {
                            modules.push(format!(
                                "{}/{}",
                                vendor.to_string_lossy(),
                                module.to_string_lossy()
                            ));
                        }
                    }
                }
            }
        }
        modules.sort();
        Ok(modules)
    }

    pub fn get_changelog(&self, release: &str) -> String {
        let path = self.repo.path().parent().unwrap_or(Path::new("."));
        let mut changelog = String::new();

        // Try different filenames
        for filename in &["CHANGELOG.md", "changelog.md", "CHANGELOG"] {
            if let Ok(output) = std::process::Command::new("git")
                .arg("-C")
                .arg(path)
                .arg("show")
                .arg(format!("{}:{}", release, filename))
                .output()
            {
                if output.status.success() {
                    changelog = String::from_utf8_lossy(&output.stdout)
                        .lines()
                        .take(20)
                        .collect::<Vec<_>>()
                        .join("\n");
                    break;
                }
            }
        }

        if changelog.is_empty() {
            format!("No changelog available for release {}", release)
        } else {
            changelog
        }
    }
}

fn is_release_branch_name(name: &str) -> bool {
    // Matches x.y.x pattern
    let parts: Vec<&str> = name.split('.').collect();
    if parts.len() != 3 {
        return false;
    }
    parts[0].chars().all(|c| c.is_ascii_digit())
        && parts[1].chars().all(|c| c.is_ascii_digit())
        && parts[2] == "x"
}
