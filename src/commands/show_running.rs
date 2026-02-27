use crate::ui;
use anyhow::Result;
use std::process::Command;

pub fn execute() -> Result<()> {
    ui::info("PROJECT DIRECTORY");

    let output = Command::new("docker")
        .arg("ps")
        .arg("-a")
        .arg("--filter")
        .arg("label=com.interligent.dockerplugin.project")
        .arg("--filter")
        .arg("label=com.interligent.dockerplugin.dir")
        .arg("--format")
        .arg("{{index .Labels \"com.interligent.dockerplugin.project\"}} {{index .Labels \"com.interligent.dockerplugin.dir\"}}")
        .output()?;

    if output.status.success() {
        let content = String::from_utf8_lossy(&output.stdout);
        let mut lines: Vec<&str> = content.lines().collect();
        lines.sort();
        lines.dedup();
        for line in lines {
            println!("{}", line);
        }
    }

    Ok(())
}
