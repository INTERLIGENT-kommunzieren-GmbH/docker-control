use crate::ui;
use crate::utils::platform::PlatformInfo;
use anyhow::{Result, anyhow};
use std::net::TcpStream;
use std::process::{Command, Stdio};
use std::time::Duration;

pub fn ensure_forwarding(info: &PlatformInfo) -> Result<()> {
    // Check if socat is available
    if Command::new("socat")
        .arg("-V")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_err()
    {
        return Err(anyhow!(
            "'socat' not found in PATH. It is required for port forwarding. Please install it (e.g., 'brew install socat' or 'choco install socat')."
        ));
    }

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
            start_socat(2222, &info.bind_ip, &ssh_auth_sock)?;

            // If we started a new forwarding, we might need to restart PHP containers
            restart_php_containers()?;
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
        let docker_sock = get_docker_socket()?;
        ui::debug(format!("Using Docker socket: {}", docker_sock));
        ui::info(format!(
            "Starting docker forwarding socket on {}:2375",
            info.bind_ip
        ));
        start_socat(2375, &info.bind_ip, &docker_sock)?;
    } else {
        ui::debug("Port 2375 is already open");
    }

    Ok(())
}

fn is_port_open(ip: &str, port: u16) -> bool {
    TcpStream::connect_timeout(
        &format!("{}:{}", ip, port).parse().unwrap(),
        Duration::from_millis(100),
    )
    .is_ok()
}

fn start_socat(port: u16, bind_ip: &str, unix_sock: &str) -> Result<()> {
    // socat TCP-LISTEN:2222,bind="$BIND_IP",reuseaddr,fork UNIX-CONNECT:"$SSH_AUTH_SOCK"
    let listen_arg = format!("TCP-LISTEN:{},bind={},reuseaddr,fork", port, bind_ip);

    let connect_arg = if std::env::consts::OS == "windows" && unix_sock.starts_with(r"\\.\pipe\") {
        // For Windows named pipes, we might need a different approach if socat doesn't support them directly
        // However, some builds of socat for windows DO support them or expect them as GOPEN
        format!("GOPEN:{}", unix_sock)
    } else {
        format!("UNIX-CONNECT:{}", unix_sock)
    };

    Command::new("socat")
        .arg(listen_arg)
        .arg(connect_arg)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;

    // Give it a moment to start
    std::thread::sleep(Duration::from_millis(500));

    Ok(())
}

fn get_docker_socket() -> Result<String> {
    let output = Command::new("docker")
        .args([
            "context",
            "inspect",
            "--format",
            "{{(index .Endpoints.docker.Host)}}",
        ])
        .output()?;

    if !output.status.success() {
        return Err(anyhow!(
            "Failed to get docker socket via docker context inspect"
        ));
    }

    let s = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if std::env::consts::OS == "windows" {
        Ok(s.replace("npipe://", "").replace("/", "\\"))
    } else {
        Ok(s.replace("unix://", ""))
    }
}

fn restart_php_containers() -> Result<()> {
    // Find PHP containers and extract their project directories
    // docker ps -q --filter "label=com.interligent.dockerplugin.service=php"
    let output = Command::new("docker")
        .args([
            "ps",
            "-q",
            "--filter",
            "label=com.interligent.dockerplugin.service=php",
        ])
        .output()?;

    if !output.status.success() {
        return Ok(()); // Probably no containers
    }

    let ids = String::from_utf8_lossy(&output.stdout);
    let mut projects = Vec::new();

    for id in ids.lines() {
        if id.is_empty() {
            continue;
        }
        let inspect = Command::new("docker")
            .args([
                "inspect",
                "--format",
                "{{index .Config.Labels \"com.interligent.dockerplugin.dir\"}}",
                id,
            ])
            .output()?;

        if inspect.status.success() {
            let dir = String::from_utf8_lossy(&inspect.stdout).trim().to_string();
            if !dir.is_empty() && !projects.contains(&dir) {
                projects.push(dir);
            }
        }
    }

    if !projects.is_empty() {
        ui::info("restarting projects with PHP containers to connect to new ssh agent port");
        for project in projects {
            ui::info(format!("✓ {}", project));
            // docker compose --project-directory "$project_dir" down --quiet
            // docker compose --project-directory "$project_dir" up -d --quiet
            let _ = Command::new("docker")
                .args(["compose", "--project-directory", &project, "down"])
                .status();
            let _ = Command::new("docker")
                .args(["compose", "--project-directory", &project, "up", "-d"])
                .status();
        }
    }

    Ok(())
}
