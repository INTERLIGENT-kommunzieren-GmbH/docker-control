use crate::ui;
use anyhow::{Result, anyhow};
use std::fs;
use std::path::Path;

pub fn execute(project_dir: &Path, name: &str) -> Result<()> {
    let control_scripts_dir = if project_dir
        .join("htdocs/.docker-control/control-scripts")
        .exists()
    {
        project_dir.join("htdocs/.docker-control/control-scripts")
    } else {
        project_dir.join("control-scripts")
    };

    if !control_scripts_dir.exists() {
        fs::create_dir_all(&control_scripts_dir)?;
    }

    let script_path = control_scripts_dir.join(format!("{}.sh", name));

    if script_path.exists() {
        return Err(anyhow!(
            "Command '{}' already exists in {:?}",
            name,
            control_scripts_dir
        ));
    }

    let content = format!(
        r#"#!/bin/bash
set -e

if [[ "\$1" == "_desc_" ]]; then
    # output command description
    echo "{name} - EMPTY DESCRIPTION"

    exit 0
fi

echo "{name} - WAITING FOR IMPLEMENTATION"

exit 0
"#
    );

    fs::write(&script_path, content)?;

    #[cfg(unix)]
    {
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = fs::metadata(&script_path)?.permissions();
            perms.set_mode(0o755);
            fs::set_permissions(&script_path, perms)?;
        }
    }

    ui::success(format!(
        "Command '{}' created under {:?}",
        name, control_scripts_dir
    ));
    Ok(())
}
