use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use anyhow::Result;

pub struct TestRepo {
    pub root: PathBuf,
}

impl TestRepo {
    pub fn new(name: &str) -> Result<Self> {
        let temp = std::env::temp_dir().join(format!("docker-control-test-{}", name));
        if temp.exists() {
            fs::remove_dir_all(&temp)?;
        }
        fs::create_dir_all(&temp)?;
        
        let root = temp.join("project");
        let origin = temp.join("origin.git");
        
        fs::create_dir_all(&root)?;
        fs::create_dir_all(&origin)?;
        
        // Init bare origin
        Self::git_run(&origin, &["init", "--bare", "--initial-branch=main"])?;
        
        // Init root htdocs
        let htdocs = root.join("htdocs");
        fs::create_dir_all(&htdocs)?;
        Self::git_run(&htdocs, &["init", "--initial-branch=main"])?;
        Self::git_run(&htdocs, &["config", "user.email", "test@example.com"])?;
        Self::git_run(&htdocs, &["config", "user.name", "Test User"])?;
        Self::git_run(&htdocs, &["remote", "add", "origin", &origin.to_string_lossy()])?;
        
        Ok(Self { root })
    }

    pub fn git_run(path: &Path, args: &[&str]) -> Result<()> {
        let status = Command::new("git")
            .args(args)
            .current_dir(path)
            .status()?;
        if !status.success() {
            return Err(anyhow::anyhow!("Git command failed: git {:?} in {:?}", args, path));
        }
        Ok(())
    }

    pub fn write_file(&self, path: &str, content: &str) -> Result<()> {
        let full_path = self.root.join(path);
        if let Some(parent) = full_path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(full_path, content)?;
        Ok(())
    }

    pub fn setup_basic_project(&self) -> Result<()> {
        let htdocs = self.root.join("htdocs");
        self.write_file("htdocs/composer.json", r#"{"name": "test/project", "version": "1.0.0"}"#)?;
        self.write_file(".env", "PHP_VERSION=8.2")?;
        
        self.commit_all("Initial commit")?;
        Self::git_run(&htdocs, &["push", "origin", "main"])?;
        
        Ok(())
    }

    pub fn commit_all(&self, message: &str) -> Result<()> {
        let htdocs = self.root.join("htdocs");
        Self::git_run(&htdocs, &["add", "."])?;
        Self::git_run(&htdocs, &["commit", "-m", message])?;
        Ok(())
    }
}

impl Drop for TestRepo {
    fn drop(&mut self) {
        if let Some(parent) = self.root.parent() {
            let _ = fs::remove_dir_all(parent);
        }
    }
}
