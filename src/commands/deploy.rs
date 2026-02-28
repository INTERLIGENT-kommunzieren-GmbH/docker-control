use crate::config::{DeployConfig, Environment};
use crate::git::GitService;
use crate::ssh;
use crate::ui;
use anyhow::{Result, anyhow};
use inquire::{Confirm, Select};
use std::fs;
use std::path::Path;
use std::process::Command;

pub async fn execute(project_dir: &Path, env_name: String) -> Result<()> {
    ui::info(format!("Preparing deployment to: {}", env_name));

    let config = DeployConfig::load(project_dir)?;
    let env = config
        .environments
        .get(&env_name)
        .ok_or_else(|| anyhow!("Environment '{}' not found in config", env_name))?;

    let git_path = project_dir.join("htdocs");
    let git = GitService::open(&git_path)?;

    ui::info("Fetching available releases...");
    // Fetch tags to ensure we have the latest
    let _ = Command::new("git")
        .arg("-C")
        .arg(&git_path)
        .args(["fetch", "--tags"])
        .status();

    let tags = git.list_tags()?;
    if tags.is_empty() {
        return Err(anyhow!(
            "No tags found in repository. Please create a release first."
        ));
    }

    let release = Select::new("Select release to deploy", tags).prompt()?;
    ui::info(format!("Selected release: {}", release));

    let project_name = get_project_name(project_dir);
    let changelog = git.get_changelog(&release);

    // Confirm deployment
    if !Confirm::new(&format!(
        "Proceed with deployment of '{}' to '{}' environment?",
        release, env_name
    ))
    .with_default(false)
    .prompt()?
    {
        ui::info("Deployment cancelled");
        return Ok(());
    }

    // Teams notification: started
    if let Some(webhook) = &env.teams_webhook_url {
        let _ = send_teams_notification(
            webhook,
            &project_name,
            &env_name,
            &release,
            "started",
            &changelog,
        )
        .await;
    }

    ui::info(format!("Deploying to {}@{}...", env.user, env.domain));

    // Create deployment archive
    let timestamp = chrono::Utc::now().format("%Y%m%d%H%M%S").to_string();
    let release_dir = format!("{}_{}", timestamp, release);
    let archive_name = format!("{}.7z", release_dir);
    let deployments_dir = project_dir.join("deployments");
    if !deployments_dir.exists() {
        fs::create_dir_all(&deployments_dir)?;
    }
    let archive_path = deployments_dir.join(&archive_name);

    if let Err(e) = create_deployment_archive(project_dir, &release, &archive_path) {
        if let Some(webhook) = &env.teams_webhook_url {
            let _ = send_teams_notification(
                webhook,
                &project_name,
                &env_name,
                &release,
                "failed",
                &format!("Archive creation failed: {}", e),
            )
            .await;
        }
        return Err(e);
    }

    // Transfer and execute
    let server_root = env.service_root.as_deref().unwrap_or("/var/www/html");

    if let Err(e) = perform_deployment(
        project_dir,
        env,
        &env_name,
        &archive_path,
        &release_dir,
        server_root,
    )
    .await
    {
        if let Some(webhook) = &env.teams_webhook_url {
            let _ = send_teams_notification(
                webhook,
                &project_name,
                &env_name,
                &release,
                "failed",
                &format!("Deployment failed: {}", e),
            )
            .await;
        }
        return Err(e);
    }

    // Teams notification: success
    if let Some(webhook) = &env.teams_webhook_url {
        let _ = send_teams_notification(
            webhook,
            &project_name,
            &env_name,
            &release,
            "success",
            &changelog,
        )
        .await;
    }

    ui::success("Deployment completed successfully!");

    Ok(())
}

fn get_project_name(project_dir: &Path) -> String {
    get_env_var(project_dir, "PROJECTNAME").unwrap_or_else(|| {
        project_dir
            .file_name()
            .unwrap_or_default()
            .to_string_lossy()
            .to_string()
    })
}

fn get_env_var(project_dir: &Path, key: &str) -> Option<String> {
    if let Ok(content) = fs::read_to_string(project_dir.join(".env")) {
        for line in content.lines() {
            if let Some(pos) = line.find('=') {
                let k = line[..pos].trim();
                let v = line[pos + 1..].trim();
                if k == key {
                    return Some(v.trim_matches('"').trim_matches('\'').to_string());
                }
            }
        }
    }
    None
}

fn create_deployment_archive(project_dir: &Path, release: &str, archive_path: &Path) -> Result<()> {
    ui::info(format!("Creating deployment archive for {}...", release));

    let deployments_dir = project_dir.join("deployments");
    let temp_extract_dir = deployments_dir.join(format!("temp_{}", release));
    if temp_extract_dir.exists() {
        fs::remove_dir_all(&temp_extract_dir)?;
    }
    fs::create_dir_all(&temp_extract_dir)?;

    // git archive --format=tar <release> | tar -x -C <temp_dir>
    let output = Command::new("git")
        .arg("-C")
        .arg(project_dir.join("htdocs"))
        .arg("archive")
        .arg("--format=tar")
        .arg(release)
        .output()?;

    if !output.status.success() {
        return Err(anyhow!(
            "Git archive failed: {}",
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    let mut child = Command::new("tar")
        .arg("-x")
        .arg("-C")
        .arg(&temp_extract_dir)
        .stdin(std::process::Stdio::piped())
        .spawn()?;

    if let Some(mut stdin) = child.stdin.take() {
        use std::io::Write;
        stdin.write_all(&output.stdout)?;
    }
    child.wait()?;

    // Run composer install inside a container for parity with bash
    let php_version = get_env_var(project_dir, "PHP_VERSION").unwrap_or_else(|| "8.2".to_string());
    let ssh_auth_port = get_env_var(project_dir, "SSH_AUTH_PORT");

    ui::info(format!(
        "Running composer install via Docker (PHP {})...",
        php_version
    ));

    let mut docker_cmd = Command::new("docker");
    docker_cmd
        .arg("run")
        .arg("--rm")
        .arg("-u")
        .arg(format!("{}:{}", unsafe { libc::getuid() }, unsafe {
            libc::getgid()
        }))
        .arg("--group-add")
        .arg("www-data");

    if let Some(port) = ssh_auth_port {
        docker_cmd.arg("-e").arg(format!("SSH_AUTH_PORT={}", port));
    }

    docker_cmd
        .arg("-e")
        .arg("SSH_AUTH_SOCK=/tmp/ssh-agent.sock")
        .arg("--add-host")
        .arg("host.docker.internal:host-gateway")
        .arg("-v")
        .arg(format!(
            "{}/volumes/composer-cache:/var/www/.composer/cache",
            project_dir.display()
        ))
        .arg("-v")
        .arg(format!("{}:/var/www/html", temp_extract_dir.display()))
        .arg(format!("fduarte42/docker-php:{}", php_version))
        .arg("bash")
        .arg("-c")
        .arg("/docker-php-init; composer i -o");

    let status = docker_cmd.status()?;
    if !status.success() {
        return Err(anyhow!("Composer install failed"));
    }

    // 7z a <archive_path> <temp_dir>/*
    let status = Command::new("7z")
        .arg("a")
        .arg(archive_path)
        .arg(format!("{}/.", temp_extract_dir.display()))
        .status()?;

    if !status.success() {
        return Err(anyhow!("7z compression failed"));
    }

    fs::remove_dir_all(&temp_extract_dir)?;

    Ok(())
}

async fn perform_deployment(
    project_dir: &Path,
    env: &Environment,
    env_name: &str,
    archive_path: &Path,
    release_dir: &str,
    server_root: &str,
) -> Result<()> {
    let user = &env.user;
    let domain = &env.domain;
    let remote_releases = format!("{}/releases", server_root);
    let remote_archive = format!(
        "{}/{}",
        remote_releases,
        archive_path.file_name().unwrap().to_str().unwrap()
    );
    let remote_release_path = format!("{}/{}", remote_releases, release_dir);

    // 1. Ensure releases dir exists
    ssh::exec_ssh(user, domain, &format!("mkdir -p {}", remote_releases))?;

    // 2. Transfer archive
    ui::info("Transferring archive...");
    ssh::copy_ssh(user, domain, archive_path, &remote_archive)?;

    // 3. Extract and remove archive
    ui::info("Extracting archive...");
    ssh::exec_ssh(user, domain, &format!("mkdir -p {}", remote_release_path))?;
    ssh::exec_ssh(
        user,
        domain,
        &format!("7z x -o{} {}", remote_release_path, remote_archive),
    )?;
    ssh::exec_ssh(user, domain, &format!("rm -f {}", remote_archive))?;

    // 4. Cleanup old releases (keep last 5)
    // ls -d1t $SERVER_ROOT/releases/* | grep -v $(readlink -f $SERVER_ROOT/current) | egrep "^$SERVER_ROOT/releases/[0-9]{14}_.+$" | tail -n +6 | xargs rm -rf
    let cleanup_cmd = format!(
        "bash -c 'ls -d1t {}/* 2>/dev/null | grep -v $(readlink -f {}/current 2>/dev/null || echo \"none\") | grep -E \"{}/[0-9]{{14}}_.+$\" | tail -n +6 | xargs rm -rf 2>/dev/null || true'",
        remote_releases, server_root, remote_releases
    );
    let _ = ssh::exec_ssh(user, domain, &cleanup_cmd);

    // 5. Reload FPM
    ui::info("Reloading FPM...");
    let _ = ssh::exec_ssh(user, domain, "sudo php-fpm-reload.sh");

    // 6. Maintenance mode selection and activation
    let maintenance_mode = Select::new("Select maintenance mode", vec!["hard", "soft"])
        .with_starting_cursor(0)
        .prompt()?;
    ui::info(format!("Enabling maintenance mode ({})", maintenance_mode));

    let console_current = format!("php {}/current/public/index.php", server_root);
    let console_new = format!("php {}/public/index.php", remote_release_path);

    // We try to enable maintenance on current if it exists, and on new.
    let _ = ssh::exec_ssh(
        user,
        domain,
        &format!(
            "{} shared:maintenance {}",
            console_current, maintenance_mode
        ),
    );
    let _ = ssh::exec_ssh(
        user,
        domain,
        &format!("{} shared:maintenance {}", console_new, maintenance_mode),
    );

    // 7. Hooks: pre_deploy_hook
    execute_hook(
        project_dir,
        env_name,
        "pre_deploy_hook",
        vec![user, domain, server_root, release_dir, &console_new],
    )?;

    // 8. Cache clearing, migrations, etc.
    ui::info("Executing deployment tasks...");
    ssh::exec_ssh(user, domain, &format!("{} shared:clear-opcc", console_new))?;
    ssh::exec_ssh(
        user,
        domain,
        &format!("{} orm:clear-cache:metadata", console_new),
    )?;
    ssh::exec_ssh(
        user,
        domain,
        &format!("{} orm:clear-cache:query", console_new),
    )?;

    if Confirm::new("Clear result cache?")
        .with_default(false)
        .prompt()?
    {
        ssh::exec_ssh(
            user,
            domain,
            &format!("{} orm:clear-cache:result", console_new),
        )?;
    }

    if Confirm::new("Execute migrations?")
        .with_default(true)
        .prompt()?
    {
        ssh::exec_ssh(
            user,
            domain,
            &format!("{} migrations:migrate --no-interaction", console_new),
        )?;
    }

    if Confirm::new("Execute schema-tool?")
        .with_default(false)
        .prompt()?
    {
        ssh::exec_ssh(
            user,
            domain,
            &format!("{} orm:schema-tool:update --dump-sql", console_new),
        )?;
    }

    // 9. COPS Integration
    if env.cops_integration.unwrap_or(false) {
        ui::info("Executing COPS integration...");

        if let Err(e) = ssh::exec_ssh(user, domain, &format!("{} cops:outdated", console_new)) {
            ui::warning(format!("COPS outdated command failed: {}", e));
            if !Confirm::new("Do you want to continue deployment despite COPS command failure?")
                .with_default(false)
                .prompt()?
            {
                // Disable maintenance mode before exiting
                let _ = ssh::exec_ssh(
                    user,
                    domain,
                    &format!("{} shared:maintenance off", console_new),
                );
                return Err(anyhow!(
                    "Deployment aborted due to COPS integration failure"
                ));
            }
        }

        if let Err(e) = ssh::exec_ssh(user, domain, &format!("{} cops:permissions", console_new)) {
            ui::warning(format!("COPS permissions command failed: {}", e));
            if !Confirm::new("Do you want to continue deployment despite COPS command failure?")
                .with_default(false)
                .prompt()?
            {
                // Disable maintenance mode before exiting
                let _ = ssh::exec_ssh(
                    user,
                    domain,
                    &format!("{} shared:maintenance off", console_new),
                );
                return Err(anyhow!(
                    "Deployment aborted due to COPS integration failure"
                ));
            }
        }
    }

    // 10. Hooks: post_deploy_hook
    execute_hook(
        project_dir,
        env_name,
        "post_deploy_hook",
        vec![user, domain, server_root, release_dir, &console_new],
    )?;

    ui::info("Basic deployment done. You can now run custom commands on the server.");
    ui::info("Press ENTER to continue and finish deployment...");
    let mut input = String::new();
    std::io::stdin().read_line(&mut input)?;

    // 11. Maintenance mode OFF (on new release)
    ui::info("Disabling maintenance mode...");
    ssh::exec_ssh(
        user,
        domain,
        &format!("{} shared:maintenance off", console_new),
    )?;

    // 12. Update symlink
    ui::info("Updating current symlink...");
    ssh::exec_ssh(
        user,
        domain,
        &format!(
            "rm -f {}/current && ln -s releases/{} {}/current",
            server_root, release_dir, server_root
        ),
    )?;

    // 13. Shared paths
    ui::info("Handling shared paths...");
    if let Some(dirs) = &env.shared_directories {
        for dir in dirs {
            let shared_path = format!("{}/shared/{}", server_root, dir);
            let target_path = format!("{}/current/{}", server_root, dir);
            ssh::exec_ssh(user, domain, &format!("mkdir -p {}", shared_path))?;
            ssh::exec_ssh(
                user,
                domain,
                &format!(
                    "rm -rf {} && ln -sf {} {}",
                    target_path, shared_path, target_path
                ),
            )?;
        }
    }
    if let Some(files) = &env.shared_files {
        for file in files {
            let shared_path = format!("{}/shared/{}", server_root, file);
            let target_path = format!("{}/current/{}", server_root, file);
            let shared_dir = Path::new(&shared_path).parent().unwrap().to_string_lossy();
            ssh::exec_ssh(user, domain, &format!("mkdir -p {}", shared_dir))?;
            ssh::exec_ssh(user, domain, &format!("touch {}", shared_path))?;
            ssh::exec_ssh(
                user,
                domain,
                &format!(
                    "rm -f {} && ln -sf {} {}",
                    target_path, shared_path, target_path
                ),
            )?;
        }
    }

    // 14. Final bytecode cache clear
    ui::info("Final bytecode cache clear...");
    ssh::exec_ssh(user, domain, &format!("{} shared:clear-opcc", console_new))?;

    // 15. Hooks: done_deploy_hook
    execute_hook(
        project_dir,
        env_name,
        "done_deploy_hook",
        vec![user, domain, server_root, release_dir, &console_new],
    )?;

    Ok(())
}

fn sanitize_name(name: &str) -> String {
    name.to_lowercase()
        .replace(['/', '\\', '.', ':', ',', '-'], "_")
}

fn execute_hook(
    project_dir: &Path,
    env_name: &str,
    hook_name: &str,
    args: Vec<&str>,
) -> Result<()> {
    let sanitized_env = sanitize_name(env_name);
    let hook_path = if project_dir
        .join("htdocs/.docker-control/deployment-scripts")
        .join(format!("{}.sh", env_name))
        .exists()
    {
        project_dir
            .join("htdocs/.docker-control/deployment-scripts")
            .join(format!("{}.sh", env_name))
    } else if project_dir
        .join("deployments/scripts")
        .join(format!("{}.sh", env_name))
        .exists()
    {
        project_dir
            .join("deployments/scripts")
            .join(format!("{}.sh", env_name))
    } else {
        return Ok(());
    };

    ui::info(format!("Executing hook: {}...", hook_name));

    let args_str = args.join(" ");
    let hook_path_str = hook_path.display();
    let cmd = format!(
        ". {hook_path_str} && if [[ $(type -t {hook_name}_{sanitized_env}) == \"function\" ]]; then {hook_name}_{sanitized_env} \"{args_str}\" ; fi",
    );

    let status = Command::new("bash").arg("-c").arg(cmd).status()?;

    if !status.success() {
        ui::warning(format!("Hook {hook_name} failed"));
    }

    Ok(())
}

async fn send_teams_notification(
    webhook_url: &str,
    project_name: &str,
    env_name: &str,
    release: &str,
    status: &str,
    changelog: &str,
) -> Result<()> {
    let client = reqwest::Client::new();
    let title = format!("Deployment {status} - {project_name} [{env_name}]");
    let color = match status {
        "started" => "0078D4",
        "success" => "00FF00",
        "failed" => "FF0000",
        _ => "CCCCCC",
    };

    let body = serde_json::json!({
        "@type": "MessageCard",
        "@context": "http://schema.org/extensions",
        "themeColor": color,
        "summary": title,
        "sections": [{
            "activityTitle": title,
            "facts": [
                { "name": "Project", "value": project_name },
                { "name": "Environment", "value": env_name },
                { "name": "Release", "value": release },
                { "name": "Status", "value": status }
            ],
            "text": changelog
        }]
    });

    let _ = client.post(webhook_url).json(&body).send().await;

    Ok(())
}
