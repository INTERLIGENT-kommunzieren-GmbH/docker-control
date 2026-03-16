use crate::ui;
use crate::utils::platform::PlatformInfo;
use anyhow::{Result, anyhow};
use bollard::Docker;
use bollard::container::ListContainersOptions;
use std::collections::HashMap;
use std::net::TcpStream as StdTcpStream;
use std::time::Duration;
use tokio::io::copy;
use tokio::net::{TcpListener, UnixStream};

pub async fn ensure_forwarding(info: &PlatformInfo) -> Result<()> {
    // 1. SSH Agent Forwarding (Port 2222)
    ui::debug(format!("Checking if port {}:2222 is open", info.bind_ip));
    if !is_port_open(&info.bind_ip, 2222) {
        ui::debug("Port 2222 is closed, attempting to start SSH agent forwarding");
        if let Ok(ssh_auth_sock) = std::env::var("SSH_AUTH_SOCK") {
            ui::debug(format!("Using SSH_AUTH_SOCK: {}", ssh_auth_sock));
            ui::info(format!(
                "Starting SSH agent forwarding socket on {}:2222",
                info.bind_ip
            ));
            start_forwarding(2222, &info.bind_ip, &ssh_auth_sock)?;

            // If we started a new forwarding, we might need to restart PHP containers
            if let Err(e) = restart_php_containers().await {
                ui::warning(format!("Failed to restart PHP containers: {}", e));
            }
        } else {
            ui::warning("SSH agent seems to not be running ($SSH_AUTH_SOCK is empty).");
        }
    } else {
        ui::debug("Port 2222 is already open");
    }

    // 2. Docker Socket Forwarding (Port 2375)
    ui::debug(format!("Checking if port {}:2375 is open", info.bind_ip));
    if !is_port_open(&info.bind_ip, 2375) {
        ui::debug("Port 2375 is closed, attempting to start Docker socket forwarding");
        let docker_sock = get_docker_socket().await?;
        ui::debug(format!("Using Docker socket: {}", docker_sock));
        ui::info(format!(
            "Starting docker forwarding socket on {}:2375",
            info.bind_ip
        ));
        start_forwarding(2375, &info.bind_ip, &docker_sock)?;
    } else {
        ui::debug("Port 2375 is already open");
    }

    Ok(())
}

fn is_port_open(ip: &str, port: u16) -> bool {
    StdTcpStream::connect_timeout(
        &format!("{}:{}", ip, port).parse().unwrap(),
        Duration::from_millis(100),
    )
    .is_ok()
}

fn start_forwarding(port: u16, bind_ip: &str, unix_sock: &str) -> Result<()> {
    let bind_addr = format!("{}:{}", bind_ip, port);
    let target = unix_sock.to_string();

    tokio::spawn(async move {
        let listener = match TcpListener::bind(&bind_addr).await {
            Ok(l) => l,
            Err(e) => {
                ui::critical(format!("Failed to bind to {}: {}", bind_addr, e));
                return;
            }
        };

        loop {
            match listener.accept().await {
                Ok((mut client_stream, _)) => {
                    let target = target.clone();
                    tokio::spawn(async move {
                        if std::env::consts::OS == "windows" && target.starts_with(r"\\.\pipe\") {
                            #[cfg(windows)]
                            {
                                use tokio::net::windows::named_pipe::ClientOptions;
                                match ClientOptions::new().open(&target) {
                                    Ok(mut server_stream) => {
                                        let (mut cr, mut cw) = client_stream.split();
                                        let (mut sr, mut sw) = tokio::io::split(server_stream);
                                        let _ = tokio::join!(
                                            copy(&mut cr, &mut sw),
                                            copy(&mut sr, &mut cw)
                                        );
                                    }
                                    Err(e) => ui::critical(format!(
                                        "Failed to connect to named pipe {}: {}",
                                        target, e
                                    )),
                                }
                            }
                            #[cfg(not(windows))]
                            {
                                ui::critical("Named pipes are only supported on Windows");
                            }
                        } else {
                            match UnixStream::connect(&target).await {
                                Ok(mut server_stream) => {
                                    let (mut cr, mut cw) = client_stream.split();
                                    let (mut sr, mut sw) = server_stream.split();
                                    let _ = tokio::join!(
                                        copy(&mut cr, &mut sw),
                                        copy(&mut sr, &mut cw)
                                    );
                                }
                                Err(e) => ui::critical(format!(
                                    "Failed to connect to unix socket {}: {}",
                                    target, e
                                )),
                            }
                        }
                    });
                }
                Err(e) => {
                    ui::critical(format!("Accept error: {}", e));
                }
            }
        }
    });

    // Give it a moment to start
    std::thread::sleep(Duration::from_millis(100));

    Ok(())
}

async fn get_docker_socket() -> Result<String> {
    // Bollard connects to the default local socket by default.
    // If we want the actual socket path, we might need context inspect but bollard doesn't expose context.
    // However, most systems have it in /var/run/docker.sock or npipe:////./pipe/docker_engine.
    // Let's try to get it from context if possible or just use common defaults if not specified.

    // Actually, calling `docker context inspect` is the most reliable way to get what the user currently has selected.
    // But since the user wants to replace external dependencies, I'll try to find another way.
    // If there is no other way, I might keep this specific one or just use common defaults.

    // For now, I'll use common defaults since `bollard` itself knows how to find them.
    if std::env::consts::OS == "windows" {
        Ok(r"\\.\pipe\docker_engine".to_string())
    } else {
        Ok("/var/run/docker.sock".to_string())
    }
}

async fn restart_php_containers() -> Result<()> {
    let docker = Docker::connect_with_local_defaults()
        .map_err(|e| anyhow!("Failed to connect to Docker: {}", e))?;

    let mut filters = HashMap::new();
    filters.insert(
        "label".to_string(),
        vec!["com.interligent.dockerplugin.service=php".to_string()],
    );

    let containers = docker
        .list_containers(Some(ListContainersOptions {
            all: false,
            filters,
            ..Default::default()
        }))
        .await
        .map_err(|e| anyhow!("Failed to list containers: {}", e))?;

    let mut projects = Vec::new();

    for container in containers {
        if let Some(id) = container.id {
            let inspect = docker.inspect_container(&id, None).await?;
            if let Some(config) = inspect.config {
                if let Some(labels) = config.labels {
                    let dir = labels
                        .get("com.interligent.dockerplugin.dir")
                        .or_else(|| labels.get("com.docker.compose.project.working_dir"));

                    if let Some(dir) = dir {
                        if !dir.is_empty() && !projects.contains(dir) {
                            // Check if directory exists and has a compose file
                            let path = std::path::Path::new(dir);
                            if path.exists()
                                && (path.join("compose.yml").exists()
                                    || path.join("docker-compose.yml").exists())
                            {
                                projects.push(dir.clone());
                            }
                        }
                    }
                }
            }
        }
    }

    if !projects.is_empty() {
        ui::info("restarting projects with PHP containers to connect to new ssh agent port");
        for project in projects {
            ui::info(format!("✓ {}", project));
            // Keep docker compose calls as requested
            let _ = std::process::Command::new("docker")
                .args(["compose", "--project-directory", &project, "down"])
                .current_dir(&project)
                .status();
            let _ = std::process::Command::new("docker")
                .args(["compose", "--project-directory", &project, "up", "-d"])
                .current_dir(&project)
                .status();
        }
    }

    Ok(())
}
