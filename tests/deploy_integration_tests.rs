mod common;

use anyhow::Result;
use common::TestRepo;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};

fn create_fake_bin(dir: &PathBuf, name: &str, log_file: &PathBuf) -> Result<()> {
    let bin_path = dir.join(name);
    // Use full path to bash to avoid PATH issues in the script itself
    // Added logic to fail if FAIL_SSH or FAIL_SCP is set
    let content = format!(
        r#"#!/bin/bash
echo "{} $@ (FAIL_SSH=$FAIL_SSH)" >> "{}"
if [ "{}" = "ssh" ] && [ -n "$FAIL_SSH" ]; then
  exit 1
fi
if [ "{}" = "scp" ] && [ -n "$FAIL_SCP" ]; then
  exit 1
fi
exit 0
"#,
        name,
        log_file.to_string_lossy(),
        name,
        name
    );
    fs::write(&bin_path, content)?;
    let mut perms = fs::metadata(&bin_path)
        .map_err(|e| {
            eprintln!("Failed to get metadata for {:?}: {}", bin_path, e);
            e
        })?
        .permissions();
    perms.set_mode(0o755);
    fs::set_permissions(&bin_path, perms)?;
    Ok(())
}

#[tokio::test]
async fn test_successful_deploy() -> Result<()> {
    let repo = TestRepo::new("deploy-success")?;
    repo.setup_mezzio_project()?;

    // Create a release tag
    TestRepo::git_run(&repo.root.join("htdocs"), &["tag", "v1.0.0"])?;
    TestRepo::git_run(&repo.root.join("htdocs"), &["push", "origin", "v1.0.0"])?;

    // Setup deploy config
    repo.write_file(
        ".deploy.json",
        r#"{
        "version": "1.0",
        "environments": {
            "prod": {
                "user": "deploy-user",
                "domain": "example.com",
                "serviceRoot": "/var/www/my-app"
            }
        }
    }"#,
    )?;

    // Create fake bin directory
    let bin_dir = repo.root.join("bin");
    fs::create_dir_all(&bin_dir)?;
    let log_file = repo.root.join("ssh_commands.log");
    create_fake_bin(&bin_dir, "ssh", &log_file)?;
    create_fake_bin(&bin_dir, "scp", &log_file)?;
    create_fake_bin(&bin_dir, "7z", &log_file)?;
    create_fake_bin(&bin_dir, "docker", &log_file)?;

    // Run the binary directly to ensure environment variables are passed to the plugin process
    let bin_path = PathBuf::from(env!("CARGO_BIN_EXE_docker-control"));

    println!("Spawning {:?} with --release and --yes", bin_path);
    let child = Command::new(&bin_path)
        .arg("deploy")
        .arg("prod")
        .arg("--release")
        .arg("v1.0.0")
        .arg("--yes")
        .current_dir(&repo.root)
        .env(
            "PATH",
            format!(
                "{}:{}",
                bin_dir.to_string_lossy(),
                std::env::var("PATH").unwrap_or_default()
            ),
        )
        .env("DOCKER_CONTROL_SKIP_SSH_AGENT", "1")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| {
            eprintln!(
                "Failed to spawn {:?}: {}. PATH={}",
                bin_path,
                e,
                std::env::var("PATH").unwrap_or_default()
            );
            e
        })?;

    println!("Waiting for cargo to finish...");
    let output = child.wait_with_output().map_err(|e| {
        eprintln!("Failed to wait for output: {}", e);
        e
    })?;

    println!("Stdout: {}", String::from_utf8_lossy(&output.stdout));
    println!("Stderr: {}", String::from_utf8_lossy(&output.stderr));

    assert!(
        output.status.success(),
        "Deploy command failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );

    // Verify SSH commands were called
    println!("Checking log file: {:?}", log_file);
    let log_content = fs::read_to_string(&log_file).map_err(|e| {
        eprintln!("Failed to read log file {:?}: {}", log_file, e);
        e
    })?;
    println!("Log content: \n{}", log_content);

    assert!(log_content.contains("ssh -o LogLevel=QUIET -o StrictHostKeyChecking=accept-new -tA deploy-user@example.com -- mkdir -p /var/www/my-app/releases"));
    assert!(log_content.contains("scp -o StrictHostKeyChecking=no -A"));
    assert!(log_content.contains("v1.0.0.7z deploy-user@example.com:/var/www/my-app/releases/"));
    assert!(log_content.contains("ssh -o LogLevel=QUIET -o StrictHostKeyChecking=accept-new -tA deploy-user@example.com -- mkdir -p /var/www/my-app/releases/"));
    assert!(log_content.contains("7z x -o/var/www/my-app/releases/"));
    assert!(log_content.contains("rm -f /var/www/my-app/releases/"));
    assert!(log_content.contains("shared:maintenance hard"));
    assert!(log_content.contains("migrations:migrate --no-interaction"));

    Ok(())
}

#[tokio::test]
async fn test_failed_deploy_ssh_error() -> Result<()> {
    let repo = TestRepo::new("deploy-fail")?;
    repo.setup_mezzio_project()?;

    // Create a release tag
    TestRepo::git_run(&repo.root.join("htdocs"), &["tag", "v1.0.0"])?;
    TestRepo::git_run(&repo.root.join("htdocs"), &["push", "origin", "v1.0.0"])?;

    // Setup deploy config
    repo.write_file(
        ".deploy.json",
        r#"{
        "version": "1.0",
        "environments": {
            "prod": {
                "user": "deploy-user",
                "domain": "example.com",
                "serviceRoot": "/var/www/my-app"
            }
        }
    }"#,
    )?;

    // Create fake bin directory
    let bin_dir = repo.root.join("bin");
    fs::create_dir_all(&bin_dir)?;
    let log_file = repo.root.join("ssh_commands.log");
    create_fake_bin(&bin_dir, "ssh", &log_file)?;
    create_fake_bin(&bin_dir, "scp", &log_file)?;
    create_fake_bin(&bin_dir, "7z", &log_file)?;
    create_fake_bin(&bin_dir, "docker", &log_file)?;

    // Run the binary directly to ensure environment variables are passed to the plugin process
    let bin_path = PathBuf::from(env!("CARGO_BIN_EXE_docker-control"));

    println!(
        "Spawning {:?} (expecting failure) with --release and --yes",
        bin_path
    );
    let child = Command::new(&bin_path)
        .arg("deploy")
        .arg("prod")
        .arg("--release")
        .arg("v1.0.0")
        .arg("--yes")
        .current_dir(&repo.root)
        .env(
            "PATH",
            format!(
                "{}:{}",
                bin_dir.to_string_lossy(),
                std::env::var("PATH").unwrap_or_default()
            ),
        )
        .env("DOCKER_CONTROL_SKIP_SSH_AGENT", "1")
        .env("FAIL_SSH", "1") // Trigger SSH failure
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;

    let output = child.wait_with_output()?;

    // Verify SSH commands were called
    let log_content = fs::read_to_string(&log_file).unwrap_or_default();
    println!("Log content (failure test): \n{}", log_content);

    // Deploy command should fail
    assert!(
        !output.status.success(),
        "Deploy command should have failed"
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("Error: SSH command failed")
            || stderr.contains("Error: Failed to ensure releases dir exists")
    );

    Ok(())
}

#[tokio::test]
async fn test_failed_deploy_cops_error_non_interactive() -> Result<()> {
    let repo = TestRepo::new("deploy-fail-cops")?;
    repo.setup_mezzio_project()?;

    // Create a release tag
    TestRepo::git_run(&repo.root.join("htdocs"), &["tag", "v1.0.0"])?;
    TestRepo::git_run(&repo.root.join("htdocs"), &["push", "origin", "v1.0.0"])?;

    // Setup deploy config with COPS enabled
    repo.write_file(
        ".deploy.json",
        r#"{
        "version": "1.0",
        "environments": {
            "prod": {
                "user": "deploy-user",
                "domain": "example.com",
                "serviceRoot": "/var/www/my-app",
                "cops_integration": true
            }
        }
    }"#,
    )?;

    // Create fake bin directory
    let bin_dir = repo.root.join("bin");
    fs::create_dir_all(&bin_dir)?;
    let log_file = repo.root.join("ssh_commands.log");
    create_fake_bin(&bin_dir, "ssh", &log_file)?;
    create_fake_bin(&bin_dir, "scp", &log_file)?;
    create_fake_bin(&bin_dir, "7z", &log_file)?;
    create_fake_bin(&bin_dir, "docker", &log_file)?;

    // Run the binary directly
    let bin_path = PathBuf::from(env!("CARGO_BIN_EXE_docker-control"));

    println!(
        "Spawning {:?} (expecting failure due to COPS) with --release and --yes",
        bin_path
    );
    let child = Command::new(&bin_path)
        .arg("deploy")
        .arg("prod")
        .arg("--release")
        .arg("v1.0.0")
        .arg("--yes")
        .current_dir(&repo.root)
        .env(
            "PATH",
            format!(
                "{}:{}",
                bin_dir.to_string_lossy(),
                std::env::var("PATH").unwrap_or_default()
            ),
        )
        .env("DOCKER_CONTROL_SKIP_SSH_AGENT", "1")
        .env("FAIL_SSH", "1") // We'll use FAIL_SSH to make the COPS command fail
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;

    let output = child.wait_with_output()?;

    // Verify COPS failure caused abort
    assert!(
        !output.status.success(),
        "Deploy command should have failed due to COPS"
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("COPS outdated check failed")
            || stderr.contains("Error: SSH command failed")
    );

    Ok(())
}
