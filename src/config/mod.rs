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
            .ok_or_else(|| anyhow!("No deployment configuration found (.deployment-config.json)"))?;

        let content = fs::read_to_string(&config_file)
            .context(format!("Failed to read config file {:?}", config_file))?;

        let config: DeployConfig =
            serde_json::from_str(&content).context(format!("Failed to parse {}", config_file.to_str().unwrap_or("deployment config file")))?;

        // Basic validation
        if config.version != "1.0" {
            return Err(anyhow!(
                "Unsupported configuration version: {} (expected 1.0)",
                config.version
            ));
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
    let preferred = project_dir.join("htdocs/.docker-control/deployment-config.json");
    if preferred.exists() {
        return Some(preferred);
    }

    // Fallback: .deploy.json in project root
    let fallback = project_dir.join(".deployment-config.json");
    if fallback.exists() {
        return Some(fallback);
    }

    None
}
