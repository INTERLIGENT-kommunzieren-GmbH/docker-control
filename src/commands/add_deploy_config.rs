use crate::config::{DeployConfig, Environment};
use crate::ui;
use anyhow::Result;
use inquire::{Confirm, Text};
use std::path::Path;

pub fn execute(project_dir: &Path) -> Result<()> {
    ui::info("Adding deployment configuration...");

    let mut config = DeployConfig::load(project_dir).unwrap_or_else(|_| {
        ui::info("No configuration found. Creating a new one.");
        DeployConfig::new()
    });

    let env_name = Text::new("Environment name:")
        .with_placeholder("production")
        .prompt()?;

    let user = Text::new("User:").with_placeholder("deploy").prompt()?;

    let default_domain = format!("{}.projects.interligent.com", user);
    let domain = Text::new("Domain:")
        .with_default(&default_domain)
        .prompt()?;

    let service_root = Text::new("Server root:")
        .with_default("/var/www/html")
        .prompt()?;

    let console_command = Text::new("Console command:")
        .with_default("bin/console")
        .prompt()?;

    let description = Text::new("Description:")
        .with_default(&format!("Deployment environment: {}", env_name))
        .prompt()?;

    let configure_teams = Confirm::new(&format!(
        "Do you want to configure Teams deployment notifications for '{}'?",
        env_name
    ))
    .with_default(false)
    .prompt()?;

    let teams_webhook_url = if configure_teams {
        let url = Text::new("Teams webhook URL:").prompt()?;
        Some(url)
    } else {
        None
    };

    let cops_integration = Confirm::new(&format!(
        "Do you want to enable COPS integration for '{}'?",
        env_name
    ))
    .with_default(false)
    .prompt()?;

    // Prompt for shared paths
    let shared_directories =
        prompt_list("Enter shared directory path (relative to server root, leave empty to stop):")?;
    let shared_files =
        prompt_list("Enter shared file path (relative to server root, leave empty to stop):")?;

    let env = Environment {
        user,
        domain,
        branch: None, // Will be selected during deploy
        service_root: Some(service_root),
        console_command: Some(console_command),
        description: Some(description),
        tags: None,
        teams_webhook_url,
        cops_integration: Some(cops_integration),
        shared_directories: if shared_directories.is_empty() {
            None
        } else {
            Some(shared_directories)
        },
        shared_files: if shared_files.is_empty() {
            None
        } else {
            Some(shared_files)
        },
    };

    config.environments.insert(env_name.clone(), env);

    // Maintain environment_order
    let mut order = config.environment_order.unwrap_or_default();
    if !order.contains(&env_name) {
        order.push(env_name);
    }
    config.environment_order = Some(order);

    // Update lastModified
    if let Some(mut meta) = config.metadata {
        meta.last_modified = chrono::Utc::now().to_rfc3339();
        config.metadata = Some(meta);
    }

    config.save(project_dir)?;
    ui::success("Configuration saved successfully.");

    Ok(())
}

fn prompt_list(prompt: &str) -> Result<Vec<String>> {
    let mut list = Vec::new();
    loop {
        let item = Text::new(prompt).prompt()?;
        if item.trim().is_empty() {
            break;
        }
        list.push(item.trim().to_string());
    }
    Ok(list)
}
