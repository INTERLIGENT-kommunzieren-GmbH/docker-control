#![allow(clippy::collapsible_if)]

use clap::{Parser, Subcommand};
use std::path::PathBuf;

mod assets;
mod commands;
mod config;
mod docker;
mod git;
mod ssh;
mod ui;
mod utils;

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
    },
    /// Initialize an empty directory with the project template
    Init,
    /// Install the Docker CLI plugin system-wide
    InstallPlugin,
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
    /// Update the Docker plugin to the latest version
    UpdatePlugin,
    /// Return metadata for Docker CLI plugin
    #[command(name = "docker-cli-plugin-metadata", hide = true)]
    Metadata,
    /// Execute a custom control script
    #[command(external_subcommand)]
    External(Vec<String>),
}

#[tokio::main]
async fn main() {
    // Check for help flags early to show status in help
    let args: Vec<String> = std::env::args().collect();
    let is_help = args.iter().any(|arg| arg == "--help" || arg == "-h" || arg == "help");

    if is_help {
        // Manually parse dir for status summary in help
        let mut project_dir = std::env::current_dir().expect("Failed to get current directory");
        for i in 0..args.len() {
            if (args[i] == "--dir" || args[i] == "-d") && i + 1 < args.len() {
                project_dir = PathBuf::from(&args[i + 1]);
                break;
            }
        }
        let summary = commands::status::get_summary(&project_dir);
        println!("{}", ui::cyan(format!("Project Status: {}", summary)));
        println!();
    }

    let cli = Cli::parse();

    if cli.debug {
        ui::set_debug(true);
    }

    if let Some(Commands::Metadata) = cli.command {
        let metadata = serde_json::json!({
            "SchemaVersion": "0.1.0",
            "Vendor": "INTERLIGENT kommunizieren GmbH",
            "Version": env!("CARGO_PKG_VERSION"),
            "ShortDescription": "IK Docker Control CLI Plugin"
        });
        println!("{}", serde_json::to_string(&metadata).unwrap());
        return;
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

    // Platform detection and forwarding
    let platform_info = utils::platform::detect_platform();
    ui::debug(format!("Platform detected: {:?}", platform_info.platform));

    if let Err(e) = utils::forwarding::ensure_forwarding(&platform_info) {
        ui::warning(format!("Forwarding setup failed: {}", e));
    }

    // Set environment variables for child processes (docker compose, etc.)
    let (ssh_auth_host, docker_host_ip) = match platform_info.platform {
        utils::platform::Platform::NativeLinux(_) if platform_info.bind_ip != "localhost" => {
            (platform_info.bind_ip.clone(), platform_info.bind_ip.clone())
        }
        _ => (
            "host.docker.internal".to_string(),
            "host.docker.internal".to_string(),
        ),
    };

    ui::debug(format!(
        "Setting SSH_AUTH_PORT to {}:2222",
        ssh_auth_host
    ));
    ui::debug(format!(
        "Setting DOCKER_HOST to tcp://{}:2375",
        docker_host_ip
    ));

    unsafe {
        std::env::set_var("SSH_AUTH_PORT", format!("{}:2222", ssh_auth_host));
        std::env::set_var("DOCKER_HOST", format!("tcp://{}:2375", docker_host_ip));
    }

    let command = match cli.command {
        Some(cmd) => cmd,
        None => {
            // If no command is provided, show status and help summary
            if let Err(e) = commands::status::execute(&project_dir) {
                ui::critical(format!("Error showing status: {}", e));
            }
            println!("\nRun 'docker control --help' for a list of available commands.");
            return;
        }
    };

    match command {
        Commands::Metadata => unreachable!(),
        Commands::AddDeployConfig => {
            if let Err(e) = commands::add_deploy_config::execute(&project_dir) {
                ui::critical(format!("Error: {}", e));
            }
        }
        Commands::Build { args } => {
            check_managed(&project_dir);
            let mut all_args = vec!["build"];
            for arg in &args {
                all_args.push(arg);
            }
            if let Err(e) = docker::execute_compose(&project_dir, &all_args) {
                ui::critical(format!("Error: {}", e));
            }
        }
        Commands::Console { container } => {
            check_managed(&project_dir);
            if let Err(e) = docker::console(&project_dir, container) {
                ui::critical(format!("Error: {}", e));
            }
        }
        Commands::CreateControlScript { name } => {
            if let Err(e) = commands::create_script::execute(&project_dir, &name) {
                ui::critical(format!("Error: {}", e));
            }
        }
        Commands::Deploy { env } => {
            if let Err(e) = commands::deploy::execute(&project_dir, env).await {
                ui::critical(format!("Error: {}", e));
            }
        }
        Commands::Init => {
            if let Err(e) = commands::init::execute(&project_dir) {
                ui::critical(format!("Error: {}", e));
            }
        }
        Commands::InstallPlugin => {
            if let Err(e) = commands::install_plugin::execute() {
                ui::critical(format!("Error: {}", e));
            }
        }
        Commands::Merge { module } => {
            if let Err(e) = commands::merge::execute(&project_dir, module) {
                ui::critical(format!("Error: {}", e));
            }
        }
        Commands::Pull => {
            check_managed(&project_dir);
            if let Err(e) = docker::execute_compose(&project_dir, &["pull"]) {
                ui::critical(format!("Error: {}", e));
            }
        }
        Commands::PullIngress => {
            if let Err(e) = docker::execute_ingress_compose(&["pull"]) {
                ui::critical(format!("Error: {}", e));
            }
        }
        Commands::Release { module } => {
            if let Err(e) = commands::release::execute(&project_dir, module) {
                ui::critical(format!("Error: {}", e));
            }
        }
        Commands::Restart => {
            check_managed(&project_dir);
            if let Err(e) = docker::execute_compose(&project_dir, &["down"]) {
                ui::critical(format!("Error: {}", e));
            }
            if let Err(e) = docker::execute_compose(&project_dir, &["up", "-d"]) {
                ui::critical(format!("Error: {}", e));
            }
        }
        Commands::RestartIngress => {
            if let Err(e) = docker::execute_ingress_compose(&["down"]) {
                ui::critical(format!("Error: {}", e));
            }
            if let Err(e) = docker::execute_ingress_compose(&["up", "-d"]) {
                ui::critical(format!("Error: {}", e));
            }
        }
        Commands::ShowRunning => {
            if let Err(e) = commands::show_running::execute() {
                ui::critical(format!("Error: {}", e));
            }
        }
        Commands::Start => {
            check_managed(&project_dir);
            if let Err(e) = docker::execute_compose(&project_dir, &["up", "-d"]) {
                ui::critical(format!("Error: {}", e));
            }
        }
        Commands::StartIngress => {
            if let Err(e) = docker::execute_ingress_compose(&["up", "-d"]) {
                ui::critical(format!("Error: {}", e));
            }
        }
        Commands::Status => {
            if let Err(e) = commands::status::execute(&project_dir) {
                ui::critical(format!("Error: {}", e));
            }
            // Also show docker compose ps as it was before
            let _ = docker::execute_compose(&project_dir, &["ps"]);
        }
        Commands::StatusIngress => {
            if let Err(e) = docker::execute_ingress_compose(&["ps"]) {
                ui::critical(format!("Error: {}", e));
            }
        }
        Commands::Stop => {
            check_managed(&project_dir);
            if let Err(e) = docker::execute_compose(&project_dir, &["stop"]) {
                ui::critical(format!("Error: {}", e));
            }
        }
        Commands::StopIngress => {
            if let Err(e) = docker::execute_ingress_compose(&["stop"]) {
                ui::critical(format!("Error: {}", e));
            }
        }
        Commands::Update => {
            if let Err(e) = commands::update::execute(&project_dir) {
                ui::critical(format!("Error: {}", e));
            }
        }
        Commands::UpdatePlugin => {
            if let Err(e) = utils::update() {
                ui::critical(format!("Error: {}", e));
            }
        }
        Commands::External(args) => {
            if let Err(e) = execute_external_script(&project_dir, args) {
                ui::critical(format!("Error: {}", e));
            }
        }
    }
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
