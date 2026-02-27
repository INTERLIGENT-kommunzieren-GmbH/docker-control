use anyhow::Result;
use std::path::Path;

pub mod forwarding;
pub mod platform;

pub fn is_managed(project_dir: &Path) -> bool {
    project_dir
        .join(".managed-by-docker-control-plugin")
        .exists()
}

pub fn update() -> Result<()> {
    let status = self_update::backends::github::Update::configure()
        .repo_owner("INTERLIGENT-kommunzieren-GmbH")
        .repo_name("docker-plugin")
        .bin_name("docker-control")
        .show_download_progress(true)
        .current_version(env!("CARGO_PKG_VERSION"))
        .build()?
        .update()?;

    if status.updated() {
        println!("Updated to version: {}", status.version());
    } else {
        println!("Already up to date!");
    }

    Ok(())
}
