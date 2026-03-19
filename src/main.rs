#![allow(clippy::collapsible_if)]

use clap::builder::styling::{AnsiColor, Effects, Styles};
use clap::{CommandFactory, FromArgMatches, Parser, Subcommand};
use daemonize::Daemonize;
use std::path::PathBuf;
use tokio::signal;

use docker_control::{assets, commands, docker, ui, utils, SSH_AGENT_PORT};

#[derive(Parser)]
#[command(name = "docker-control")]
#[command(about = "IK Docker Control CLI Plugin", long_about = None)]
#[command(version)]
struct Cli {
    /// Specify the project directory (default: current directory)
    #[arg(short, long, value_name = "DIRECTORY")]
    dir: Option<PathBuf>,

    /// Enable debug output
    #[arg(long, global = true)]
    debug: bool,

    /// Start SSH agent forwarding daemon
    #[arg(long)]
    start_ssh_agent: bool,

    /// Stop SSH agent forwarding daemon
    #[arg(long)]
    stop_ssh_agent: bool,

    /// Restart SSH agent forwarding daemon
    #[arg(long)]
    restart_ssh_agent: bool,

    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Subcommand)]
enum Commands {
    /// Add deployment configuration for environments
    AddDeployConfig,
    /// Build the Docker containers for the project
    Build {
        /// Pass additional arguments to docker-compose build
        #[arg(trailing_var_arg = true)]
        args: Vec<String>,
    },
    /// Open a shell inside a container
    Console {
        /// Container name (defaults to 'php')
        container: Option<String>,
    },
    /// Create a custom control script
    CreateControlScript {
        /// Name of the control script
        name: String,
    },
    /// Deploy a selected release to the specified environment
    Deploy {
        /// Target environment (e.g., production, staging)
        env: String,

        /// Specific release to deploy (skips interactive selection)
        #[arg(short, long)]
        release: Option<String>,

        /// Maintenance mode to use when --yes is specified (hard|soft)
        #[arg(long, default_value = "hard")]
        maintenance_mode: String,

        /// Skip all interactive prompts
        #[arg(short, long)]
        yes: bool,
    },
    /// Initialize an empty directory with the project template
    Init,
    /// Merge release branch to main using selective cherry-pick workflow
    Merge {
        /// Optional module name
        module: Option<String>,
    },
    /// Pull the latest Docker images for the project
    Pull,
    /// Pull the latest ingress-related Docker images
    PullIngress,
    /// Create a new release branch
    Release {
        /// Optional module name
        module: Option<String>,
    },
    /// Restart the project containers
    Restart,
    /// Restart the ingress containers
    RestartIngress,
    /// Show all running projects managed by the Docker plugin
    ShowRunning,
    /// Start the project containers
    Start,
    /// Start the ingress containers
    StartIngress,
    /// Show the status of the project containers
    Status,
    /// Show the status of the ingress containers
    StatusIngress,
    /// Stop the project containers
    Stop,
    /// Stop the ingress containers
    StopIngress,
    /// Update the project with the current template
    Update,
    /// Return metadata for Docker CLI plugin
    #[command(name = "docker-cli-plugin-metadata", hide = true)]
    Metadata,
    /// Execute a custom control script
    #[command(external_subcommand)]
    External(Vec<String>),
}

fn get_help_styles() -> Styles {
    Styles::styled()
        .header(AnsiColor::Yellow.on_default() | Effects::BOLD)
        .usage(AnsiColor::Yellow.on_default() | Effects::BOLD)
        .literal(AnsiColor::Cyan.on_default() | Effects::BOLD)
        .placeholder(AnsiColor::Cyan.on_default())
}

fn main() {
    let args: Vec<String> = std::env::args().collect();

    // Handle stop synchronously
    if args.contains(&"--stop-ssh-agent".to_string()) {
        if let Err(e) = docker_control::utils::stop_ssh_agent() {
            eprintln!("Failed to stop SSH agent: {}", e);
            std::process::exit(1);
        } else {
            println!("SSH agent forwarding stopped.");
        }
        return;
    }

    // Handle restart: stop then start
    if args.contains(&"--restart-ssh-agent".to_string()) {
        if let Err(e) = docker_control::utils::stop_ssh_agent() {
            eprintln!("Warning: Failed to stop SSH agent: {}", e);
        } else {
            // Wait for port to close
            let platform_info = utils::platform::detect_platform();
            for _ in 0..50 {
                // wait up to 5 seconds
                if !utils::forwarding::is_port_open(&platform_info.bind_ip, SSH_AGENT_PORT) {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
        }
        // Fall through to start
    }

    // Handle start or restart
    if args.contains(&"--start-ssh-agent".to_string())
        || args.contains(&"--restart-ssh-agent".to_string())
    {
        let pid_file = "/tmp/docker-control-ssh-agent.pid";
        let stdout_file = "/tmp/docker-control-ssh-agent.log";
        let stderr_file = "/tmp/docker-control-ssh-agent.err";

        let daemonize = Daemonize::new()
            .pid_file(pid_file)
            .stdout(std::fs::File::create(stdout_file).unwrap())
            .stderr(std::fs::File::create(stderr_file).unwrap());

        daemonize.start().expect("Failed to daemonize");

        // Now start the async runtime
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let platform_info = utils::platform::detect_platform();
            if let Err(e) = utils::forwarding::ensure_forwarding(&platform_info).await {
                eprintln!("Forwarding setup failed: {}", e);
                std::process::exit(1);
            }
            unsafe {
                std::env::set_var(
                    "SSH_AUTH_PORT",
                    format!("{}:{}", platform_info.bind_ip, SSH_AGENT_PORT),
                );
            }
            eprintln!("SSH agent forwarding started in daemon mode.");
            signal::ctrl_c().await.unwrap();
        });
        return;
    }

    // Normal path
    let rt = tokio::runtime::Runtime::new().unwrap();
    if let Err(e) = rt.block_on(async_main()) {
        ui::critical(format!("Error: {}", e));
        std::process::exit(1);
    }
}

async fn async_main() -> anyhow::Result<()> {
    let cmd = Cli::command().styles(get_help_styles());

    let matches = cmd.get_matches();
    let cli = Cli::from_arg_matches(&matches).unwrap_or_else(|e| e.exit());

    if cli.debug {
        ui::set_debug(true);
    }

    // Check for help flags early to show status in help
    let args: Vec<String> = std::env::args().collect();
    let is_help = args
        .iter()
        .any(|arg| arg == "--help" || arg == "-h" || arg == "help");

    if is_help {
        // Manually parse dir for status summary in help
        let mut project_dir = std::env::current_dir().expect("Failed to get current directory");
        for i in 0..args.len() {
            if (args[i] == "--dir" || args[i] == "-d") && i + 1 < args.len() {
                project_dir = PathBuf::from(&args[i + 1]);
                break;
            }
        }

        let project_dir = if project_dir.exists() {
            project_dir.canonicalize().unwrap_or(project_dir)
        } else {
            project_dir
        };

        let summary = commands::status::get_summary(&project_dir).await;
        let status_line = format!("{}: {}", ui::yellow("Project Status"), ui::cyan(summary));
        println!("{}\n", status_line);

        let custom_commands = commands::custom::get_custom_commands(&project_dir);
        let mut custom_help = String::new();
        if !custom_commands.is_empty() {
            custom_help.push_str(&format!("\n\n{}\n", ui::yellow("Custom Commands:")));
            for cmd in custom_commands {
                custom_help.push_str(&format!(
                    "  {:22} {}\n",
                    ui::cyan(&cmd.name),
                    cmd.description
                ));
            }
        }

        let help_template = format!(
            "{{before-help}}{{name}} {{version}}\n{{about-with-newline}}\n{{usage-heading}} {{usage}}\n\n{}\n{{subcommands}}{}\n{}\n{{options}}",
            ui::yellow("Commands:"),
            custom_help,
            ui::yellow("Options:")
        );

        // Use the factory to get a new command with the template and print help
        Cli::command()
            .styles(get_help_styles())
            .help_template(help_template)
            .print_help()
            .unwrap();
        println!();
        return Ok(());
    }

    if let Some(Commands::Metadata) = cli.command {
        let metadata = serde_json::json!({
            "SchemaVersion": "2.0.0",
            "Vendor": "INTERLIGENT kommunizieren GmbH",
            "Version": env!("CARGO_PKG_VERSION"),
            "ShortDescription": "IK Docker Control CLI Plugin"
        });
        println!("{}", serde_json::to_string(&metadata).unwrap());
        return Ok(());
    }

    if cli.stop_ssh_agent {
        if let Err(e) = docker_control::utils::stop_ssh_agent() {
            ui::critical(format!("Failed to stop SSH agent: {}", e));
            return Err(e);
        } else {
            ui::info("SSH agent forwarding stopped.");
        }
        return Ok(());
    }

    if cli.restart_ssh_agent {
        if let Err(e) = docker_control::utils::stop_ssh_agent() {
            ui::warning(format!("Failed to stop SSH agent: {}", e));
        }
        // Then start
    }

    if cli.start_ssh_agent || cli.restart_ssh_agent {
        let daemonize = Daemonize::new();
        match daemonize.start() {
            Ok(_) => {
                // In daemon process
                // Platform detection and forwarding
                let platform_info = utils::platform::detect_platform();
                ui::debug(format!("Platform detected: {:?}", platform_info.platform));

                if let Err(e) = utils::forwarding::ensure_forwarding(&platform_info).await {
                    ui::critical(format!("Forwarding setup failed: {}", e));
                    std::process::exit(1);
                }

                // Set SSH_AUTH_PORT
                unsafe {
                    std::env::set_var("SSH_AUTH_PORT", format!("{}:{}", platform_info.bind_ip, SSH_AGENT_PORT));
                }

                ui::info("SSH agent forwarding started in daemon mode.");
                signal::ctrl_c().await.unwrap();
                std::process::exit(0);
            }
            Err(e) => {
                ui::critical(format!("Failed to daemonize: {}", e));
                return Err(anyhow::anyhow!("Failed to daemonize: {}", e));
            }
        }
    }

    // Initialize assets
    if let Ok(asset_manager) = assets::AssetManager::new() {
        if let Err(e) = asset_manager.ensure_assets() {
            ui::warning(format!(
                "Failed to ensure assets: {}. Falling back to local/env paths.",
                e
            ));
        }
    }

    let project_dir = cli
        .dir
        .clone()
        .unwrap_or_else(|| std::env::current_dir().expect("Failed to get current directory"));

    let project_dir = if project_dir.exists() {
        project_dir
            .canonicalize()
            .unwrap_or_else(|_| project_dir.clone())
    } else {
        project_dir
    };

    // Platform detection
    let platform_info = utils::platform::detect_platform();
    ui::debug(format!("Platform detected: {:?}", platform_info.platform));

    // Ensure SSH agent forwarding is running
    if std::env::var("DOCKER_CONTROL_SKIP_SSH_AGENT").is_err() && !utils::forwarding::is_port_open(&platform_info.bind_ip, SSH_AGENT_PORT) {
        ui::info("Starting SSH agent forwarding daemon...");
        // Spawn the daemon
        if let Ok(exe) = std::env::current_exe() {
            if let Err(e) = std::process::Command::new(exe)
                .arg("--start-ssh-agent")
                .spawn()
            {
                ui::warning(format!("Failed to spawn SSH agent daemon: {}", e));
            } else {
                // Wait for it to start
                for _ in 0..50 {
                    if utils::forwarding::is_port_open(&platform_info.bind_ip, SSH_AGENT_PORT) {
                        break;
                    }
                    std::thread::sleep(std::time::Duration::from_millis(100));
                }
            }
        } else {
            ui::warning("Could not determine executable path to start SSH agent daemon");
        }
    }

    if utils::forwarding::is_port_open(&platform_info.bind_ip, SSH_AGENT_PORT) {
        // Set SSH_AUTH_PORT
        unsafe {
            std::env::set_var(
                "SSH_AUTH_PORT",
                format!("{}:{}", platform_info.bind_ip, SSH_AGENT_PORT),
            );
        }
    } else {
        ui::warning("SSH agent forwarding is not available. SSH keys may not be accessible.");
    }

    let command = match cli.command {
        Some(cmd) => cmd,
        None => {
            // If no command is provided, show status and help summary
            if let Err(e) = commands::status::execute(&project_dir).await {
                ui::critical(format!("Error showing status: {}", e));
                return Err(e);
            }
            println!("\nRun 'docker control --help' for a list of available commands.");
            return Ok(());
        }
    };

    match command {
        Commands::Metadata => unreachable!(),
        Commands::AddDeployConfig => {
            commands::add_deploy_config::execute(&project_dir)?;
        }
        Commands::Build { args } => {
            check_managed(&project_dir);
            let mut all_args = vec!["build"];
            for arg in &args {
                all_args.push(arg);
            }
            docker::execute_compose(&project_dir, &all_args)?;
        }
        Commands::Console { container } => {
            check_managed(&project_dir);
            docker::console(&project_dir, container)?;
        }
        Commands::CreateControlScript { name } => {
            commands::create_script::execute(&project_dir, &name)?;
        }
        Commands::Deploy { env, release, maintenance_mode, yes } => {
            commands::deploy::execute(&project_dir, env, release, maintenance_mode, yes).await?;
        }
        Commands::Init => {
            commands::init::execute(&project_dir).await?;
        }
        Commands::Merge { module } => {
            commands::merge::execute(&project_dir, module, commands::merge::MergeOptions::default())?;
        }
        Commands::Pull => {
            check_managed(&project_dir);
            docker::execute_compose(&project_dir, &["pull"])?;
        }
        Commands::PullIngress => {
            docker::execute_ingress_compose(&["pull"])?;
        }
        Commands::Release { module } => {
            commands::release::execute(&project_dir, module, commands::release::ReleaseOptions::default())?;
        }
        Commands::Restart => {
            check_managed(&project_dir);
            docker::execute_compose(&project_dir, &["down"])?;
            docker::execute_compose(&project_dir, &["up", "-d"])?;
        }
        Commands::RestartIngress => {
            docker::execute_ingress_compose(&["down"])?;
            docker::execute_ingress_compose(&["up", "-d"])?;
        }
        Commands::ShowRunning => {
            commands::show_running::execute().await?;
        }
        Commands::Start => {
            check_managed(&project_dir);
            docker::execute_compose(&project_dir, &["up", "-d"])?;
        }
        Commands::StartIngress => {
            docker::execute_ingress_compose(&["up", "-d"])?;
        }
        Commands::Status => {
            commands::status::execute(&project_dir).await?;
            // Also show docker compose ps as it was before
            let _ = docker::execute_compose(&project_dir, &["ps"]);
        }
        Commands::StatusIngress => {
            docker::execute_ingress_compose(&["ps"])?;
        }
        Commands::Stop => {
            check_managed(&project_dir);
            docker::execute_compose(&project_dir, &["stop"])?;
        }
        Commands::StopIngress => {
            docker::execute_ingress_compose(&["stop"])?;
        }
        Commands::Update => {
            commands::update::execute(&project_dir)?;
        }
        Commands::External(args) => {
            execute_external_script(&project_dir, args)?;
        }
    }

    Ok(())
}

fn execute_external_script(project_dir: &std::path::Path, args: Vec<String>) -> anyhow::Result<()> {
    if args.is_empty() {
        return Err(anyhow::anyhow!("No command provided"));
    }

    let command_name = &args[0];
    let command_args = &args[1..];

    let paths = vec![
        project_dir.join(format!(
            "htdocs/.docker-control/control-scripts/{}.sh",
            command_name
        )),
        project_dir.join(format!("control-scripts/{}.sh", command_name)),
    ];

    for path in paths {
        if path.exists() {
            ui::info(format!("Executing custom script: {:?}", path));
            let mut cmd = std::process::Command::new("bash");
            cmd.arg(&path).args(command_args).current_dir(project_dir);

            // Set environment variables for the script if needed
            // original bash script has access to LIB_DIR, PROJECT_DIR, etc.

            let status = cmd.status()?;
            if !status.success() {
                return Err(anyhow::anyhow!(
                    "Custom script failed with status {}",
                    status
                ));
            }
            return Ok(());
        }
    }

    Err(anyhow::anyhow!("Unknown command: {}", command_name))
}

fn check_managed(project_dir: &std::path::Path) {
    if !utils::is_managed(project_dir) {
        ui::critical(format!(
            "{:?} not managed by docker control plugin",
            project_dir
        ));
        std::process::exit(1);
    }
}
