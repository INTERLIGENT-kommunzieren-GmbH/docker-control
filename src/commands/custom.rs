use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Debug)]
pub struct CustomCommand {
    pub name: String,
    pub description: String,
}

pub fn get_custom_commands(project_dir: &Path) -> Vec<CustomCommand> {
    let mut commands = Vec::new();
    let mut search_paths = Vec::new();

    // Check both possible locations for control scripts
    let htdocs_path = project_dir.join("htdocs/.docker-control/control-scripts");
    if htdocs_path.exists() {
        search_paths.push(htdocs_path);
    }

    let root_path = project_dir.join("control-scripts");
    if root_path.exists() {
        search_paths.push(root_path);
    }

    for path in search_paths {
        if let Ok(entries) = fs::read_dir(path) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.extension().and_then(|s| s.to_str()) == Some("sh")
                    && let Some(name) = path.file_stem().and_then(|s| s.to_str())
                {
                    let description = get_description(&path);
                    commands.push(CustomCommand {
                        name: name.to_string(),
                        description,
                    });
                }
            }
        }
    }

    // Sort by name for consistent output
    commands.sort_by(|a, b| a.name.cmp(&b.name));
    commands
}

fn get_description(path: &PathBuf) -> String {
    let output = Command::new("bash").arg(path).arg("_desc_").output();

    match output {
        Ok(out) if out.status.success() => String::from_utf8_lossy(&out.stdout).trim().to_string(),
        _ => "No description available".to_string(),
    }
}
