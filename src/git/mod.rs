use anyhow::{Context, Result, anyhow};
use git2::{BranchType, Cred, FetchOptions, PushOptions, RemoteCallbacks, Repository};
use std::path::Path;

pub struct GitService {
    repo: Repository,
}

impl GitService {
    pub fn auth_callbacks() -> RemoteCallbacks<'static> {
        let mut callbacks = RemoteCallbacks::new();
        callbacks.credentials(|_url, username_from_url, _allowed_types| {
            let user: &str = username_from_url.unwrap_or("git");
            Cred::ssh_key_from_agent(user)
        });
        callbacks
    }
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

    pub fn fetch_all(&self) -> anyhow::Result<()> {
        let mut remote = self.repo.find_remote("origin")?;

        let callbacks = Self::auth_callbacks();

        let mut fetch_options = FetchOptions::new();
        fetch_options.remote_callbacks(callbacks);

        remote.fetch(
            &["+refs/heads/*:refs/remotes/origin/*"],
            Some(&mut fetch_options),
            None,
        )?;

        Ok(())
    }

    pub fn fetch_tags(&self) -> Result<()> {
        let mut remote = self.repo.find_remote("origin")?;
        let callbacks = Self::auth_callbacks();
        let mut fetch_options = FetchOptions::new();
        fetch_options.remote_callbacks(callbacks);
        remote.fetch(&["refs/tags/*:refs/tags/*"], Some(&mut fetch_options), None)?;
        Ok(())
    }

    pub fn add_file(&self, path: &Path) -> Result<()> {
        let mut index = self.repo.index()?;
        index.add_path(path)?;
        index.write()?;
        Ok(())
    }

    pub fn commit(&self, message: &str) -> Result<()> {
        let mut index = self.repo.index()?;
        let tree_id = index.write_tree()?;
        let tree = self.repo.find_tree(tree_id)?;
        let sig = self.repo.signature()?;
        let parent = self.repo.head()?.peel_to_commit()?;
        self.repo
            .commit(Some("HEAD"), &sig, &sig, message, &tree, &[&parent])?;
        Ok(())
    }

    pub fn create_tag_on_head(&self, name: &str, message: &str) -> Result<()> {
        let head = self.repo.head()?.peel_to_commit()?;
        let sig = self.repo.signature()?;
        self.repo
            .tag(name, head.as_object(), &sig, message, false)?;
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
        let obj = match self.repo.revparse_single(release) {
            Ok(o) => o,
            Err(_) => return format!("No changelog available for release {}", release),
        };
        let commit = match obj.peel_to_commit() {
            Ok(c) => c,
            Err(_) => return format!("No changelog available for release {}", release),
        };
        let tree = match commit.tree() {
            Ok(t) => t,
            Err(_) => return format!("No changelog available for release {}", release),
        };

        for filename in &["CHANGELOG.md", "changelog.md", "CHANGELOG"] {
            if let Ok(entry) = tree.get_path(Path::new(filename)) {
                if let Ok(blob) = self.repo.find_blob(entry.id()) {
                    let content = String::from_utf8_lossy(blob.content());
                    return content.lines().take(20).collect::<Vec<_>>().join("\n");
                }
            }
        }

        format!("No changelog available for release {}", release)
    }

    pub fn create_worktree(&self, _name: &str, path: &Path, branch: Option<&str>) -> Result<()> {
        let opts = git2::WorktreeAddOptions::new();
        let _wt = self.repo.worktree(_name, path, Some(&opts))?;

        if let Some(b) = branch {
            let wt_repo = Repository::open(path)?;

            // Check if branch exists locally
            if let Ok(local_branch) = wt_repo.find_branch(b, BranchType::Local) {
                let commit = local_branch.get().peel_to_commit()?;
                wt_repo.set_head(local_branch.get().name().unwrap())?;
                wt_repo.checkout_tree(commit.as_object(), None)?;
            } else if let Ok(remote_branch) =
                wt_repo.find_branch(&format!("origin/{}", b), BranchType::Remote)
            {
                let commit = remote_branch.get().peel_to_commit()?;
                let new_branch = wt_repo.branch(b, &commit, false)?;
                wt_repo.set_head(new_branch.get().name().unwrap())?;
                wt_repo.checkout_tree(commit.as_object(), None)?;
            }
        }
        Ok(())
    }

    pub fn push_branch(&self, branch_name: &str) -> Result<()> {
        let mut remote = self.repo.find_remote("origin")?;
        let refspec = format!("refs/heads/{}:refs/heads/{}", branch_name, branch_name);
        let callbacks = Self::auth_callbacks();
        let mut push_options = PushOptions::new();
        push_options.remote_callbacks(callbacks);
        remote.push(&[&refspec], Some(&mut push_options))?;
        Ok(())
    }

    pub fn push_tag(&self, tag_name: &str) -> Result<()> {
        let mut remote = self.repo.find_remote("origin")?;
        let refspec = format!("refs/tags/{}:refs/tags/{}", tag_name, tag_name);
        let callbacks = Self::auth_callbacks();
        let mut push_options = PushOptions::new();
        push_options.remote_callbacks(callbacks);
        remote.push(&[&refspec], Some(&mut push_options))?;
        Ok(())
    }

    pub fn pull(&self, branch_name: &str) -> Result<()> {
        let mut remote = self.repo.find_remote("origin")?;
        let callbacks = Self::auth_callbacks();
        let mut fetch_options = FetchOptions::new();
        fetch_options.remote_callbacks(callbacks);
        remote.fetch(&[branch_name], Some(&mut fetch_options), None)?;

        let fetch_head = self.repo.find_reference("FETCH_HEAD")?;
        let fetch_commit = fetch_head.peel_to_commit()?;

        let mut checkout_builder = git2::build::CheckoutBuilder::new();
        checkout_builder.force();

        self.repo
            .checkout_tree(fetch_commit.as_object(), Some(&mut checkout_builder))?;
        self.repo.set_head(&format!("refs/heads/{}", branch_name))?;

        Ok(())
    }

    pub fn has_branch(&self, name: &str) -> Result<bool> {
        Ok(self.repo.find_branch(name, BranchType::Local).is_ok())
    }

    pub fn delete_branch(&self, name: &str) -> Result<()> {
        let mut branch = self.repo.find_branch(name, BranchType::Local)?;
        branch.delete()?;
        Ok(())
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
