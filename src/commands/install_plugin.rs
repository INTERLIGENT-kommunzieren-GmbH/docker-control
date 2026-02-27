use crate::ui;
use anyhow::Result;
use std::fs;
use std::path::PathBuf;

pub fn execute() -> Result<()> {
    ui::info("Installing plugin...");

    let home = std::env::var("HOME")?;
    let plugin_dir = PathBuf::from(home).join(".docker/cli-plugins");

    if !plugin_dir.exists() {
        fs::create_dir_all(&plugin_dir)?;
    }

    let exe_path = std::env::current_exe()?;
    let target_path = plugin_dir.join("docker-control");

    ui::info(format!("Copying binary to {:?}", target_path));
    fs::copy(&exe_path, &target_path)?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = fs::metadata(&target_path)?.permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&target_path, perms)?;
    }

    ui::success(
        "Installation successful. You can start using the plugin with: docker control help",
    );
    Ok(())
}
