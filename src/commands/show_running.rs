use crate::ui;
use anyhow::Result;
use bollard::Docker;
use bollard::container::ListContainersOptions;
use std::collections::HashMap;

pub async fn execute() -> Result<()> {
    ui::info("PROJECT DIRECTORY");

    let docker = match Docker::connect_with_local_defaults() {
        Ok(d) => d,
        Err(_) => return Err(anyhow::anyhow!("Unable to connect to Docker")),
    };

    let mut filters = HashMap::new();
    filters.insert(
        "label".to_string(),
        vec!["com.interligent.dockerplugin.project".to_string()],
    );

    match docker
        .list_containers(Some(ListContainersOptions {
            all: true,
            filters,
            ..Default::default()
        }))
        .await
    {
        Ok(containers) => {
            let mut results = Vec::new();
            for container in containers {
                if let Some(labels) = container.labels {
                    let project = labels
                        .get("com.interligent.dockerplugin.project")
                        .cloned()
                        .unwrap_or_default();
                    let dir = labels
                        .get("com.interligent.dockerplugin.dir")
                        .or_else(|| labels.get("com.docker.compose.project.working_dir"))
                        .cloned()
                        .unwrap_or_default();
                    results.push(format!("{} {}", project, dir));
                }
            }
            results.sort();
            results.dedup();
            for res in results {
                println!("{}", res);
            }
        }
        Err(e) => return Err(anyhow::anyhow!("Unable to query containers: {}", e)),
    }

    Ok(())
}
