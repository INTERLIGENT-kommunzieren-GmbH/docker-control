use anyhow::{Context, Result, anyhow};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Serialize, Deserialize)]
pub struct DeployConfig {
    pub version: String,
    pub environments: HashMap<String, Environment>,
    #[serde(rename = "environmentOrder")]
    pub environment_order: Option<Vec<String>>,
    pub defaults: Option<Defaults>,
    pub metadata: Option<Metadata>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Environment {
    pub user: String,
    pub domain: String,
    pub branch: Option<String>,
    #[serde(rename = "serviceRoot")]
    pub service_root: Option<String>,
    pub console_command: Option<String>,
    pub description: Option<String>,
    pub tags: Option<Vec<String>>,
    #[serde(rename = "teamsWebhookUrl")]
    pub teams_webhook_url: Option<String>,
    #[serde(rename = "copsIntegration")]
    pub cops_integration: Option<bool>,
    #[serde(rename = "sharedDirectories")]
    pub shared_directories: Option<Vec<String>>,
    #[serde(rename = "sharedFiles")]
    pub shared_files: Option<Vec<String>>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Defaults {
    #[serde(rename = "serviceRoot")]
    pub service_root: Option<String>,
    #[serde(rename = "domainSuffix")]
    pub domain_suffix: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct Metadata {
    #[serde(rename = "createdAt")]
    pub created_at: String,
    #[serde(rename = "lastModified")]
    pub last_modified: String,
    #[serde(rename = "createdBy")]
    pub created_by: String,
}

impl DeployConfig {
    pub fn load(project_dir: &Path) -> Result<Self> {
        let config_file = find_config_file(project_dir)
            .ok_or_else(|| anyhow!("No deployment configuration found (.deploy.json)"))?;

        let content = fs::read_to_string(&config_file)
            .context(format!("Failed to read config file {:?}", config_file))?;

        let config: DeployConfig = serde_json::from_str(&content).context(format!(
            "Failed to parse {}",
            config_file.to_str().unwrap_or("deployment config file")
        ))?;

        // Basic validation
        if config.version != "1.0" {
            return Err(anyhow!(
                "Unsupported configuration version: {} (expected 1.0)",
                config.version
            ));
        }

        // Validate all environments to prevent SSH option injection
        for (env_name, env) in &config.environments {
            validate_ssh_destination(&env.user, &env.domain, env_name)?;
        }

        Ok(config)
    }

    pub fn save(&self, project_dir: &Path) -> Result<()> {
        let config_file = find_config_file(project_dir).unwrap_or_else(|| {
            // If it doesn't exist, decide where to create it
            let preferred = project_dir.join("htdocs/.docker-control");
            if preferred.exists() {
                preferred.join(".deploy.json")
            } else {
                project_dir.join(".deploy.json")
            }
        });

        // Ensure parent directory exists if we're creating in .docker-control
        if let Some(parent) = config_file.parent()
            && !parent.exists()
        {
            fs::create_dir_all(parent)?;
        }

        let content = serde_json::to_string_pretty(self)?;
        fs::write(&config_file, content)?;
        Ok(())
    }

    pub fn new() -> Self {
        let now = chrono::Utc::now().to_rfc3339();
        Self {
            version: "1.0".to_string(),
            environments: HashMap::new(),
            environment_order: Some(Vec::new()),
            defaults: Some(Defaults {
                service_root: Some("/var/www/html".to_string()),
                domain_suffix: Some(".projects.interligent.com".to_string()),
            }),
            metadata: Some(Metadata {
                created_at: now.clone(),
                last_modified: now,
                created_by: "docker-control".to_string(),
            }),
        }
    }
}

fn find_config_file(project_dir: &Path) -> Option<PathBuf> {
    // Preferred: htdocs/.docker-control/.deploy.json
    let preferred = project_dir.join("htdocs/.docker-control/.deploy.json");
    if preferred.exists() {
        return Some(preferred);
    }

    // Fallback: .deploy.json in project root
    let fallback = project_dir.join(".deploy.json");
    if fallback.exists() {
        return Some(fallback);
    }

    None
}

/// Validates SSH destination components to prevent option injection attacks.
/// 
/// SSH and SCP interpret arguments beginning with `-` as options. When `user` or `domain`
/// are placed before `--` in the command line (as `user@domain`), a malicious value like
/// `-oProxyCommand=<cmd>` would be parsed as an SSH option, enabling local command execution.
/// 
/// This function enforces that both `user` and `domain`:
/// - Do not begin with `-` (preventing option injection)
/// - Contain only characters valid in usernames and domain names
/// - Are not empty
pub fn validate_ssh_destination(user: &str, domain: &str, env_name: &str) -> Result<()> {
    // Validate user
    if user.is_empty() {
        return Err(anyhow!(
            "Environment '{}': user cannot be empty",
            env_name
        ));
    }
    
    if user.starts_with('-') {
        return Err(anyhow!(
            "Environment '{}': user '{}' cannot start with '-' (potential SSH option injection)",
            env_name,
            user
        ));
    }

    // Valid username characters: alphanumeric, underscore, hyphen (but not at start), dot
    // This is intentionally strict to prevent any potential injection vectors
    if !user.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-' || c == '.') {
        return Err(anyhow!(
            "Environment '{}': user '{}' contains invalid characters (only alphanumeric, underscore, hyphen, and dot allowed)",
            env_name,
            user
        ));
    }

    // Validate domain
    if domain.is_empty() {
        return Err(anyhow!(
            "Environment '{}': domain cannot be empty",
            env_name
        ));
    }

    if domain.starts_with('-') {
        return Err(anyhow!(
            "Environment '{}': domain '{}' cannot start with '-' (potential SSH option injection)",
            env_name,
            domain
        ));
    }

    // Valid domain characters: alphanumeric, hyphen (but not at start), dot
    // This covers standard domain names and IP addresses
    if !domain.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '.' || c == ':') {
        return Err(anyhow!(
            "Environment '{}': domain '{}' contains invalid characters (only alphanumeric, hyphen, dot, and colon allowed)",
            env_name,
            domain
        ));
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_ssh_destination_accepts_valid_inputs() {
        assert!(validate_ssh_destination("deploy", "example.com", "test").is_ok());
        assert!(validate_ssh_destination("user_name", "sub.example.com", "test").is_ok());
        assert!(validate_ssh_destination("user.name", "192.168.1.1", "test").is_ok());
        assert!(validate_ssh_destination("user-name", "example.com:22", "test").is_ok());
    }

    #[test]
    fn validate_ssh_destination_rejects_user_starting_with_dash() {
        let result = validate_ssh_destination("-oProxyCommand=evil", "example.com", "test");
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("cannot start with '-'"));
    }

    #[test]
    fn validate_ssh_destination_rejects_domain_starting_with_dash() {
        let result = validate_ssh_destination("deploy", "-oProxyCommand=evil", "test");
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("cannot start with '-'"));
    }

    #[test]
    fn validate_ssh_destination_rejects_empty_user() {
        let result = validate_ssh_destination("", "example.com", "test");
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("cannot be empty"));
    }

    #[test]
    fn validate_ssh_destination_rejects_empty_domain() {
        let result = validate_ssh_destination("deploy", "", "test");
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("cannot be empty"));
    }

    #[test]
    fn validate_ssh_destination_rejects_invalid_user_characters() {
        let result = validate_ssh_destination("user@evil", "example.com", "test");
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("invalid characters"));
    }

    #[test]
    fn validate_ssh_destination_rejects_invalid_domain_characters() {
        let result = validate_ssh_destination("deploy", "example.com/evil", "test");
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("invalid characters"));
    }
}

