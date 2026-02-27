use crate::ui;
use anyhow::{Context, Result};
use directories::ProjectDirs;
use include_dir::{Dir, include_dir};
use std::fs;
use std::path::{Path, PathBuf};

static TEMPLATE_DIR: Dir = include_dir!("$CARGO_MANIFEST_DIR/template");
static INGRESS_DIR: Dir = include_dir!("$CARGO_MANIFEST_DIR/ingress");

pub struct AssetManager {
    config_dir: PathBuf,
}

impl AssetManager {
    pub fn new() -> Result<Self> {
        let proj_dirs = ProjectDirs::from("com", "interligent", "docker-control")
            .context("Could not find config directory")?;

        // On macOS this is ~/Library/Application Support/com.interligent.docker-control
        // On Linux this is ~/.config/docker-control
        let config_dir = proj_dirs.config_dir().to_path_buf();

        Ok(Self { config_dir })
    }

    pub fn get_template_dir(&self) -> PathBuf {
        self.config_dir.join("template")
    }

    pub fn get_ingress_dir(&self) -> PathBuf {
        self.config_dir.join("ingress")
    }

    pub fn ensure_assets(&self) -> Result<()> {
        let version_file = self.config_dir.join(".version");
        let current_version = env!("CARGO_PKG_VERSION");

        let needs_extraction = if !version_file.exists() {
            true
        } else {
            let installed_version = fs::read_to_string(&version_file)?;
            installed_version.trim() != current_version
        };

        if needs_extraction {
            ui::info(format!("Extracting assets to {:?}", self.config_dir));

            if self.config_dir.exists() {
                // To be safe, we might want to clear old assets, but let's just overwrite for now
            } else {
                fs::create_dir_all(&self.config_dir)?;
            }

            self.extract_dir(&TEMPLATE_DIR, &self.get_template_dir())?;
            self.extract_dir(&INGRESS_DIR, &self.get_ingress_dir())?;

            fs::write(version_file, current_version)?;
        }

        Ok(())
    }

    fn extract_dir(&self, dir: &Dir, target: &Path) -> Result<()> {
        if !target.exists() {
            fs::create_dir_all(target)?;
        }

        for entry in dir.entries() {
            let path = target.join(entry.path());
            match entry {
                include_dir::DirEntry::Dir(d) => {
                    self.extract_dir(d, target)?;
                }
                include_dir::DirEntry::File(f) => {
                    if let Some(parent) = path.parent() {
                        fs::create_dir_all(parent)?;
                    }
                    fs::write(&path, f.contents())?;
                }
            }
        }
        Ok(())
    }
}
