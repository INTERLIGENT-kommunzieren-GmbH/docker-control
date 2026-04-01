/*
 * Example deployment hooks for docker-control
 * 
 * This file should be named after your environment (e.g., prod.rhai, staging.rhai)
 * and placed in:
 * - htdocs/.docker-control/deployment-scripts/
 * OR
 * - deployments/scripts/
 */

// --- PRE-DEPLOY HOOK ---
// Executed before cache clearing and migrations
fn pre_deploy(console_current, release_dir, console_new, server_root) {
    print("Executing pre-deploy hook...");
    print("Release: " + release_dir);

    // Example: Run a custom command on the server
    exec_ssh(console_new + " --help");
}

// --- POST-DEPLOY HOOK ---
// Executed after migrations and COPS integration, but before switching symlink
fn post_deploy(console_current, release_dir, console_new, server_root) {
    print("Executing post-deploy hook...");

    // Example: Clear some custom cache on the remote server
    exec_ssh("rm -rf " + release_dir + "/data/cache/*");
}

// --- DONE-DEPLOY HOOK ---
// Executed after symlink update and final bytecode cache clear
fn done_deploy(console_current, release_dir, console_new, server_root) {
    print("Deployment completed!");

    // Example: Send a custom notification or trigger a webhook
    // exec_ssh("curl -X POST https://api.example.com/deploy-webhook");
}

// Dummy, will be replaced on runtime by the Rust integration
fn exec_ssh(cmd) { }
