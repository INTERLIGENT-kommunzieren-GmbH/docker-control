use crate::docker;
use crate::ui;
use crate::utils::{dependencies::is_brew_eligible, platform, throttle_cache};
use anyhow::{Context, Result, bail};
use std::path::PathBuf;
use std::process::Command;

const TAP_FORMULA: &str = "INTERLIGENT-kommunzieren-GmbH/tap/docker-control";

/// Name the formula installs into `<prefix>/bin`, used to find the *upgraded*
/// binary once `brew upgrade` has returned.
const BINARY_NAME: &str = "docker-control";

/// Minimum time between checking Homebrew for a newer docker-control
/// release. Throttled like the container image staleness check, since it's
/// not something worth doing on every single invocation.
const UPDATE_CHECK_INTERVAL: chrono::Duration = chrono::Duration::days(7);

pub fn execute() -> Result<()> {
    execute_with(&RealUpgradeOps)
}

/// Upgrades the tool, cycling the ingress proxy around it so it doesn't carry
/// the pre-upgrade ingress stack across.
///
/// The stop is worth doing here even though a plain `brew upgrade` can't do it
/// (Homebrew has no pre-upgrade hook — see [`docker::ingress_state`]): this is
/// the one code path that owns the whole sequence, so it can give the proxy a
/// clean cycle instead of leaving a notice for later.
pub fn execute_with(ops: &dyn UpgradeOps) -> Result<()> {
    let stopped = if ops.ingress_running() {
        ui::info("Stopping the ingress before upgrading...");
        match ops.stop_ingress() {
            Ok(()) => true,
            Err(e) => {
                // The proxy is presumably still up, so don't try to start it
                // again afterwards. Upgrading doesn't require it down — the
                // stop is only there to make the restart a clean cycle.
                ui::warning(format!(
                    "Could not stop the ingress ({}); upgrading with it running.",
                    e
                ));
                false
            }
        }
    } else {
        false
    };

    ui::info(format!("Upgrading {}...", TAP_FORMULA));
    if let Err(e) = ops.brew_upgrade() {
        // A failed upgrade must not leave the proxy down. Starting it from this
        // process is right here: the keg didn't change, so the ingress assets
        // this binary resolves are still the ones that were running.
        if stopped {
            ui::info("Bringing the ingress back up after the failed upgrade...");
            if let Err(e) = ops.start_ingress() {
                ui::warning(format!(
                    "Could not bring the ingress back up ({}). Run `docker control start-ingress`.",
                    e
                ));
            }
        }
        return Err(e);
    }

    ui::success("docker-control upgraded successfully.");

    if stopped {
        ui::info("Starting the ingress on the upgraded version...");
        // Not fatal: the upgrade itself succeeded, and the user is told exactly
        // what to run. Failing here would report a successful upgrade as an
        // error.
        if let Err(e) = ops.start_upgraded_ingress() {
            ui::warning(format!(
                "Could not start the ingress ({}). Run `docker control start-ingress`.",
                e
            ));
        }
    }

    Ok(())
}

/// The side effects [`execute_with`] sequences, behind a trait so the ordering
/// can be tested without stopping a real proxy or shelling out to `brew` —
/// matching how [`UpgradePromptProvider`] abstracts the confirmation.
pub trait UpgradeOps {
    fn ingress_running(&self) -> bool;
    fn stop_ingress(&self) -> Result<()>;
    fn brew_upgrade(&self) -> Result<()>;
    /// Starts the ingress from this process, for restoring a proxy that was
    /// stopped for an upgrade that then failed.
    fn start_ingress(&self) -> Result<()>;
    /// Starts the ingress from the *newly installed* binary.
    fn start_upgraded_ingress(&self) -> Result<()>;
}

pub struct RealUpgradeOps;

impl UpgradeOps for RealUpgradeOps {
    fn ingress_running(&self) -> bool {
        docker::ingress_running()
    }

    fn stop_ingress(&self) -> Result<()> {
        docker::execute_ingress_compose(&["down"])
    }

    fn brew_upgrade(&self) -> Result<()> {
        let status = Command::new("brew")
            .args(["upgrade", TAP_FORMULA])
            .status()
            .context("Failed to execute brew")?;
        if !status.success() {
            bail!("brew upgrade failed with status {}", status);
        }
        Ok(())
    }

    fn start_ingress(&self) -> Result<()> {
        docker::execute_ingress_compose(&["up", "-d"])
    }

    fn start_upgraded_ingress(&self) -> Result<()> {
        start_via_installed_binary()
    }
}

/// Brings the ingress up by invoking the freshly installed binary instead of
/// doing it in-process.
///
/// This is the part that's easy to get wrong. `execute_ingress_compose`
/// resolves the ingress assets relative to the running executable
/// (`find_ingress_dir` → `AssetManager::new()` → canonicalised
/// `current_exe()`), and this process is still the *pre-upgrade* keg. Starting
/// in-process would therefore seed `etc/docker-control/ingress/volumes` from the
/// old `share/docker-control/ingress` and start the old `compose.yml` — exactly
/// the staleness the stop/start exists to clear.
fn start_via_installed_binary() -> Result<()> {
    let installed = PathBuf::from(docker::resolve_brew_prefix())
        .join("bin")
        .join(BINARY_NAME);

    // Fall back to the name on `PATH`: an unusual prefix, or a binary linked
    // somewhere else, still resolves that way.
    let program = if installed.exists() {
        installed.into_os_string()
    } else {
        BINARY_NAME.into()
    };

    match Command::new(&program).arg("start-ingress").status() {
        Ok(status) if status.success() => return Ok(()),
        Ok(status) => ui::warning(format!(
            "{:?} start-ingress failed with status {}",
            program, status
        )),
        Err(e) => ui::warning(format!("Could not run {:?}: {}", program, e)),
    }

    // Last resort: start it from here, and say what that means rather than
    // reporting a clean success — these may be the pre-upgrade assets.
    ui::warning(
        "Starting the ingress from the pre-upgrade binary instead. If this release changed the \
         ingress, run `docker control restart-ingress` to pick it up.",
    );
    docker::execute_ingress_compose(&["up", "-d"])
}

/// Cache file recording when docker-control itself was last checked for
/// updates, so the check can be throttled to once a week. Lives in the OS
/// config dir since it's local machine state, not tied to any project.
fn update_check_cache_path() -> Option<std::path::PathBuf> {
    let proj_dirs = directories::ProjectDirs::from("com", "interligent", "docker-control")?;
    Some(proj_dirs.config_dir().join("self-update-check.json"))
}

/// Best-effort check, via Homebrew only, of whether a newer docker-control
/// release is available. Returns `None` when it can't be determined (not on
/// a Homebrew-standard platform, Homebrew missing, offline, checked too
/// recently, etc.) — this never blocks or fails the command being run.
pub fn check_outdated() -> Option<bool> {
    if std::env::var("DOCKER_CONTROL_SKIP_SELF_UPDATE_CHECK").is_ok() {
        return None;
    }

    let cache_path = update_check_cache_path();

    // Cheap cache-file check first, before the platform probe below (which
    // can shell out to `docker info`) — no point paying that cost on the
    // ~6 out of 7 invocations where the throttle would skip the check anyway.
    if !throttle_cache::is_due(cache_path.as_deref(), UPDATE_CHECK_INTERVAL) {
        ui::debug("Skipping self-update check (last checked within the past week)".to_string());
        return None;
    }

    if !is_brew_eligible(&platform::detect_platform().platform) {
        return None;
    }

    let output = Command::new("brew")
        .args(["outdated", "--json=v2", TAP_FORMULA])
        .output()
        .ok()?;

    // `brew outdated <formula>` exits non-zero both when the formula IS
    // outdated and on a real error (e.g. unknown formula) — the exit code
    // alone can't tell those apart. On a real error nothing is printed to
    // stdout, so trust the JSON on stdout as the source of truth instead of
    // gating on the exit status.
    let json: serde_json::Value = serde_json::from_slice(&output.stdout).ok()?;
    let formulae = json.get("formulae")?.as_array()?;

    // Only stamp the cache once we actually got a parseable answer, so a
    // one-off failure (bad JSON, brew missing, etc.) doesn't suppress the
    // real check for a week.
    throttle_cache::record(cache_path.as_deref());

    Some(!formulae.is_empty())
}

/// Abstracts the "upgrade now?" confirmation so tests can inject a fixed
/// answer instead of blocking on a real prompt, matching the
/// `PromptProvider`/`MergePromptProvider` pattern used elsewhere in this
/// codebase for interactive `inquire` prompts.
pub trait UpgradePromptProvider {
    fn confirm_upgrade(&self) -> bool;
}

pub struct InteractiveUpgradePromptProvider;

impl UpgradePromptProvider for InteractiveUpgradePromptProvider {
    fn confirm_upgrade(&self) -> bool {
        inquire::Confirm::new("Upgrade docker-control now?")
            .with_default(true)
            .prompt()
            .unwrap_or(false)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    /// Records the order the upgrade steps were taken in, so a test can assert
    /// the sequencing rather than just the outcome.
    #[derive(Default)]
    struct FakeOps {
        running: bool,
        stop_fails: bool,
        brew_fails: bool,
        calls: RefCell<Vec<&'static str>>,
    }

    impl FakeOps {
        fn calls(&self) -> Vec<&'static str> {
            self.calls.borrow().clone()
        }
    }

    impl UpgradeOps for FakeOps {
        fn ingress_running(&self) -> bool {
            self.running
        }

        fn stop_ingress(&self) -> Result<()> {
            self.calls.borrow_mut().push("stop");
            if self.stop_fails {
                bail!("cannot stop");
            }
            Ok(())
        }

        fn brew_upgrade(&self) -> Result<()> {
            self.calls.borrow_mut().push("brew");
            if self.brew_fails {
                bail!("brew exploded");
            }
            Ok(())
        }

        fn start_ingress(&self) -> Result<()> {
            self.calls.borrow_mut().push("start");
            Ok(())
        }

        fn start_upgraded_ingress(&self) -> Result<()> {
            self.calls.borrow_mut().push("start-upgraded");
            Ok(())
        }
    }

    #[test]
    fn cycles_the_ingress_around_the_upgrade() {
        let ops = FakeOps {
            running: true,
            ..Default::default()
        };
        execute_with(&ops).unwrap();
        // The start must be the upgraded binary's, not this process's: in-process
        // it would re-seed the volumes from the pre-upgrade keg.
        assert_eq!(ops.calls(), vec!["stop", "brew", "start-upgraded"]);
    }

    #[test]
    fn leaves_a_stopped_ingress_stopped() {
        let ops = FakeOps::default();
        execute_with(&ops).unwrap();
        assert_eq!(ops.calls(), vec!["brew"]);
    }

    #[test]
    fn a_failed_upgrade_brings_the_ingress_back_up() {
        // In-process, deliberately: the keg didn't change, so this binary's
        // ingress assets are still the ones that were running.
        let ops = FakeOps {
            running: true,
            brew_fails: true,
            ..Default::default()
        };
        assert!(execute_with(&ops).is_err());
        assert_eq!(ops.calls(), vec!["stop", "brew", "start"]);
    }

    #[test]
    fn a_failed_stop_still_upgrades_but_never_starts() {
        // The proxy is presumably still up; starting it again would be a no-op
        // at best and would mask the failure at worst.
        let ops = FakeOps {
            running: true,
            stop_fails: true,
            ..Default::default()
        };
        execute_with(&ops).unwrap();
        assert_eq!(ops.calls(), vec!["stop", "brew"]);
    }

    #[test]
    fn a_failed_stop_followed_by_a_failed_upgrade_leaves_the_proxy_alone() {
        let ops = FakeOps {
            running: true,
            stop_fails: true,
            brew_fails: true,
            ..Default::default()
        };
        assert!(execute_with(&ops).is_err());
        assert_eq!(ops.calls(), vec!["stop", "brew"]);
    }
}
