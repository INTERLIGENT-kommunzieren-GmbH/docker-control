use crate::ui;
use std::process::Command;

#[derive(Debug, Clone, PartialEq)]
pub enum Platform {
    Macos,
    Wsl,
    DockerDesktop,
    NativeLinux(Option<String>),
    Windows,
    Unknown,
}

pub struct PlatformInfo {
    pub platform: Platform,
    pub bind_ip: String,
}

pub fn detect_platform() -> PlatformInfo {
    let os = std::env::consts::OS;
    ui::debug(format!("OS detected: {}", os));

    if os == "macos" {
        ui::debug("Detected macOS platform");
        return PlatformInfo {
            platform: Platform::Macos,
            bind_ip: "localhost".to_string(),
        };
    }

    if os == "linux" {
        // Check for WSL
        if let Ok(version) = std::fs::read_to_string("/proc/version") {
            if version.to_lowercase().contains("microsoft")
                || version.to_lowercase().contains("wsl")
            {
                ui::debug("Detected WSL platform");
                return PlatformInfo {
                    platform: Platform::Wsl,
                    bind_ip: "localhost".to_string(),
                };
            }
        }

        // Check for Docker Desktop
        if let Ok(output) = Command::new("docker").arg("info").output() {
            let info = String::from_utf8_lossy(&output.stdout).to_lowercase();
            if info.contains("docker desktop")
                || info.contains("desktop-linux")
                || info.contains("com.docker.desktop")
            {
                ui::debug("Detected Docker Desktop platform");
                return PlatformInfo {
                    platform: Platform::DockerDesktop,
                    bind_ip: "localhost".to_string(),
                };
            }
        }

        // Native Linux - try to get docker0 IP
        let docker0_ip = get_docker0_ip();
        let bind_ip = docker0_ip
            .clone()
            .unwrap_or_else(|| "localhost".to_string());

        ui::debug(format!(
            "Detected Native Linux platform, bind_ip: {}",
            bind_ip
        ));
        return PlatformInfo {
            platform: Platform::NativeLinux(docker0_ip),
            bind_ip,
        };
    }

    if os == "windows" {
        // On Windows, check for Docker Desktop
        if let Ok(output) = Command::new("docker").arg("info").output() {
            let info = String::from_utf8_lossy(&output.stdout).to_lowercase();
            if info.contains("docker desktop")
                || info.contains("windows-linux")
                || info.contains("com.docker.desktop")
            {
                return PlatformInfo {
                    platform: Platform::DockerDesktop,
                    bind_ip: "localhost".to_string(),
                };
            }
        }

        return PlatformInfo {
            platform: Platform::Windows,
            bind_ip: "localhost".to_string(),
        };
    }

    PlatformInfo {
        platform: Platform::Unknown,
        bind_ip: "localhost".to_string(),
    }
}

fn get_docker0_ip() -> Option<String> {
    // Try 'ip addr show docker0'
    if let Ok(output) = Command::new("ip")
        .args(["addr", "show", "docker0"])
        .output()
    {
        let stdout = String::from_utf8_lossy(&output.stdout);
        for line in stdout.lines() {
            if line.trim().starts_with("inet ") {
                let parts: Vec<&str> = line.split_whitespace().collect();
                if parts.len() > 1 {
                    // parts[1] is like 172.17.0.1/16
                    if let Some(ip) = parts[1].split('/').next() {
                        if ip != "127.0.0.1" {
                            return Some(ip.to_string());
                        }
                    }
                }
            }
        }
    }

    // Try 'ifconfig docker0' as fallback
    if let Ok(output) = Command::new("ifconfig").arg("docker0").output() {
        let stdout = String::from_utf8_lossy(&output.stdout);
        for line in stdout.lines() {
            if line.contains("inet ") {
                let parts: Vec<&str> = line.split_whitespace().collect();
                // ifconfig output varies, but usually 'inet' is followed by the IP
                for (i, part) in parts.iter().enumerate() {
                    if *part == "inet" && i + 1 < parts.len() {
                        let ip = parts[i + 1];
                        if ip != "127.0.0.1" {
                            return Some(ip.to_string());
                        }
                    }
                }
            }
        }
    }

    None
}
