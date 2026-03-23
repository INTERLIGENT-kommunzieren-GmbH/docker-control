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
    share_dir: Option<PathBuf>,
}

impl AssetManager {
    pub fn new() -> Result<Self> {
        let proj_dirs = ProjectDirs::from("com", "interligent", "docker-control")
            .context("Could not find config directory")?;

        // On macOS this is ~/Library/Application Support/com.interligent.docker-control
        // On Linux this is ~/.config/docker-control
        let config_dir = proj_dirs.config_dir().to_path_buf();

        // Try to find share directory relative to executable
        let mut share_dir = None;
        if let Ok(exe_path) = std::env::current_exe() {
            // Follow symlinks to get the real path (important for Homebrew)
            if let Ok(real_exe_path) = exe_path.canonicalize() {
                if let Some(exe_dir) = real_exe_path.parent() {
                    // Binary is in 'bin/', share is in '../share/docker-control/'
                    let potential_share = exe_dir.parent().map(|p| p.join("share").join("docker-control"));
                    if let Some(path) = potential_share {
                        if path.exists() {
                            ui::debug(format!("Found installed assets at {:?}", path));
                            share_dir = Some(path);
                        }
                    }
                }
            }
        }

        Ok(Self {
            config_dir,
            share_dir,
        })
    }

    pub fn get_template_dir(&self) -> PathBuf {
        if let Some(ref share) = self.share_dir {
            let path = share.join("template");
            if path.exists() {
                return path;
            }
        }
        self.config_dir.join("template")
    }

    pub fn get_ingress_dir(&self) -> PathBuf {
        if let Some(ref share) = self.share_dir {
            let path = share.join("ingress");
            if path.exists() {
                return path;
            }
        }
        self.config_dir.join("ingress")
    }

    pub fn ensure_assets(&self) -> Result<()> {
        // If we are using share_dir, we don't need to extract assets to config_dir
        if self.share_dir.is_some() {
            return Ok(());
        }

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
