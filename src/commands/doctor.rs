use crate::docker;
use crate::ui;
use crate::utils;
use anyhow::{Result, anyhow};
use std::path::Path;
use std::process::Command;

/// Project directories the `php` container writes to through bind mounts, and
/// so the ones that can hold files the host user doesn't own.
const BIND_MOUNTED_DIRS: &[&str] = &["htdocs", "volumes/composer-cache"];

/// Maximum number of offending paths to list before truncating the output.
const MAX_LISTED: usize = 50;

/// Checks that `www-data` in the `php` container runs with the host user's ids,
/// and that the host user owns every file under the bind-mounted project
/// directories. With `fix`, re-owns the files that aren't.
///
/// Ownership, not just write access, is what matters: setting an explicit
/// mtime (what PhpStorm does when syncing) is an owner-only operation, which no
/// group membership or ACL entry can grant. Files a pre-remap container wrote as
/// uid 33 stay that way until they're re-owned once.
pub fn execute(project_dir: &Path, fix: bool) -> Result<()> {
    let (uid, gid) = docker::host_ids();
    let mut healthy = true;

    ui::info("Checking www-data's ids in the php container...");
    if docker::is_running(project_dir) {
        healthy &= check_www_data_ids(project_dir, uid, gid)?;
    } else {
        ui::info("Project containers are not running; skipping the container check.");
    }

    ui::info("Checking file ownership...");
    let dirs = existing_dirs(project_dir);
    let mut foreign = find_foreign_owned(project_dir, &dirs, uid)?;
    if !foreign.is_empty() && fix {
        ui::info(format!(
            "Re-owning {} to {}:{} (may prompt for sudo password)...",
            dirs.join(", "),
            uid,
            gid
        ));
        let owner = format!("{}:{}", uid, gid);
        let mut args = vec!["chown", "-R", owner.as_str()];
        args.extend(dirs.iter().map(String::as_str));
        utils::sudo::run_in(Some(project_dir), &args)?;
        foreign = find_foreign_owned(project_dir, &dirs, uid)?;
    }
    if foreign.is_empty() {
        ui::success(format!("All files in {} belong to you.", dirs.join(", ")));
    } else {
        ui::warning(format!(
            "{} path(s) are not owned by you (uid {}):",
            foreign.len(),
            uid
        ));
        for path in foreign.iter().take(MAX_LISTED) {
            ui::warning(format!("  {}", path));
        }
        if foreign.len() > MAX_LISTED {
            ui::warning(format!("  ... and {} more", foreign.len() - MAX_LISTED));
        }
        healthy = false;
    }

    if healthy {
        return Ok(());
    }

    if fix {
        Err(anyhow!("permission problems remain after --fix"))
    } else {
        ui::info("Run `dc2 doctor --fix` to repair file ownership.");
        Err(anyhow!("permission problems detected"))
    }
}

/// The `php` image's entrypoint that remaps `www-data` to `WWW_DATA_UID`/
/// `WWW_DATA_GID`. Images built before it existed ignore the variables, and
/// with no ACLs applied any more, `www-data` (uid 33) then can't write the
/// host user's files.
const REMAP_ENTRYPOINT: &str = "/usr/local/bin/docker-php-entrypoint";

/// Makes sure the running `php` container can remap `www-data` to the host
/// user, called by `start`/`restart` right after `up`. An image that predates
/// the remap is pulled and the container recreated, since the project can't
/// work with it any more. Never fails the command; problems are reported.
pub fn ensure_www_data_remap(project_dir: &Path) {
    let mut state = match read_php_state(project_dir) {
        Ok(Some(state)) => state,
        _ => {
            ui::warning("Could not inspect the php container; run `dc2 doctor` to check it.");
            return;
        }
    };

    if !state.image_supports_remap {
        ui::warning(
            "The php image predates the www-data remap docker-control relies on; pulling the latest one...",
        );
        let recreated = docker::execute_compose(project_dir, &["pull", "php"])
            .and_then(|_| docker::execute_compose(project_dir, &["up", "-d", "php"]));
        if let Err(e) = recreated {
            ui::warning(format!("Failed to update the php image: {}", e));
        }
        match read_php_state(project_dir) {
            Ok(Some(new_state)) if new_state.image_supports_remap => state = new_state,
            _ => {
                ui::warning(
                    "The php container still runs an image without the www-data remap, so it can't write your files. \
                     The registry may not have the new image yet (try `dc2 pull` and `dc2 restart` later), \
                     or compose.override.yml pins another image; update it, then run `dc2 restart`.",
                );
                return;
            }
        }
    }

    if !state.remap_requested {
        ui::warning(
            "compose.yml doesn't pass WWW_DATA_UID/WWW_DATA_GID to the php service, so www-data can't write your files. \
             Run `dc2 update`, then `dc2 restart`.",
        );
        return;
    }

    let (uid, _) = docker::host_ids();
    if has_foreign_owned(project_dir, &existing_dirs(project_dir), uid) {
        ui::warning(
            "Some project files aren't owned by you (likely written before www-data was remapped). \
             Run `dc2 doctor --fix` to re-own them.",
        );
    }
}

/// Compares `www-data`'s ids in the running `php` container with the host
/// user's, and explains the likely cause of a mismatch. `--fix` can't repair
/// this one: it takes a newer image or a template update, then a restart.
fn check_www_data_ids(project_dir: &Path, uid: u32, gid: u32) -> Result<bool> {
    let Some(state) = read_php_state(project_dir)? else {
        ui::warning("Could not read www-data's ids from the php container.");
        return Ok(false);
    };

    if (state.uid, state.gid) == (uid, gid) {
        ui::success(format!("www-data runs as {}:{}, your ids.", uid, gid));
        return Ok(true);
    }

    ui::warning(format!(
        "www-data runs as {}:{} in the php container, not as you ({}:{}).",
        state.uid, state.gid, uid, gid
    ));
    if !state.image_supports_remap {
        if docker::newer_image_pulled(project_dir, "php") {
            ui::warning(
                "The php container runs an image that predates the www-data remap, but a newer one is already pulled. Run `dc2 restart` to use it.",
            );
        } else {
            ui::warning(
                "The php image predates the www-data remap. Run `dc2 pull`, then `dc2 restart`.",
            );
        }
    } else if !state.remap_requested {
        ui::warning(
            "compose.yml doesn't pass WWW_DATA_UID/WWW_DATA_GID to the php service. Run `dc2 update`, then `dc2 restart`.",
        );
    } else {
        ui::warning(
            "The remap is still running or failed; check the php container's log (`docker compose logs php`).",
        );
    }
    Ok(false)
}

#[derive(Debug, PartialEq)]
struct PhpState {
    uid: u32,
    gid: u32,
    /// Whether the container got `WWW_DATA_UID`, i.e. whether compose.yml
    /// passes the host ids through.
    remap_requested: bool,
    /// Whether the image ships [`REMAP_ENTRYPOINT`].
    image_supports_remap: bool,
}

/// Reads [`PhpState`] from the running `php` container; `None` if the output
/// can't be parsed.
fn read_php_state(project_dir: &Path) -> Result<Option<PhpState>> {
    let script = format!(
        "id -u www-data; id -g www-data; echo \"${{WWW_DATA_UID:-}}\"; \
         if [ -x {REMAP_ENTRYPOINT} ]; then echo yes; else echo no; fi"
    );
    let output = docker::exec_as_user_output(project_dir, "php", "root", &["sh", "-c", &script])?;
    Ok(parse_php_state(&String::from_utf8_lossy(&output.stdout)))
}

/// Parses the four lines printed by [`read_php_state`]'s script.
fn parse_php_state(stdout: &str) -> Option<PhpState> {
    let mut lines = stdout.lines().map(str::trim);
    let uid = lines.next()?.parse().ok()?;
    let gid = lines.next()?.parse().ok()?;
    let remap_requested = !lines.next()?.is_empty();
    let image_supports_remap = match lines.next()? {
        "yes" => true,
        "no" => false,
        _ => return None,
    };
    Some(PhpState {
        uid,
        gid,
        remap_requested,
        image_supports_remap,
    })
}

/// The [`BIND_MOUNTED_DIRS`] that exist in this project.
fn existing_dirs(project_dir: &Path) -> Vec<String> {
    BIND_MOUNTED_DIRS
        .iter()
        .filter(|dir| project_dir.join(dir).is_dir())
        .map(|dir| dir.to_string())
        .collect()
}

/// Lists paths under `dirs` (relative to `project_dir`) not owned by `uid`.
/// Runs on the host, so it sees host ids whatever the container maps them to.
/// `find` exits non-zero on directories it can't enter, but those are
/// foreign-owned themselves and already printed, so its status is ignored.
fn find_foreign_owned(project_dir: &Path, dirs: &[String], uid: u32) -> Result<Vec<String>> {
    if dirs.is_empty() {
        return Ok(Vec::new());
    }
    let output = Command::new("find")
        .args(dirs)
        .args(["!", "-user", &uid.to_string(), "-print"])
        .current_dir(project_dir)
        .output()?;
    Ok(parse_paths(&String::from_utf8_lossy(&output.stdout)))
}

/// Whether anything under `dirs` isn't owned by `uid`; stops at the first hit,
/// so it's cheap enough to run on every start.
fn has_foreign_owned(project_dir: &Path, dirs: &[String], uid: u32) -> bool {
    !dirs.is_empty()
        && Command::new("find")
            .args(dirs)
            .args(["!", "-user", &uid.to_string(), "-print", "-quit"])
            .current_dir(project_dir)
            .output()
            .is_ok_and(|o| !o.stdout.is_empty())
}

/// Parses `find` output into a list of paths, trimming whitespace and dropping
/// blank lines.
fn parse_paths(stdout: &str) -> Vec<String> {
    stdout
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .map(String::from)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_paths_empty_is_empty() {
        assert!(parse_paths("").is_empty());
        assert!(parse_paths("   \n\n  \n").is_empty());
    }

    #[test]
    fn parse_paths_trims_and_drops_blanks() {
        let out = "htdocs/vendor\n  htdocs/var/cache  \n\nvolumes/composer-cache/x\n";
        assert_eq!(
            parse_paths(out),
            vec![
                "htdocs/vendor".to_string(),
                "htdocs/var/cache".to_string(),
                "volumes/composer-cache/x".to_string(),
            ]
        );
    }

    #[test]
    fn parse_php_state_reads_all_fields() {
        assert_eq!(
            parse_php_state("1000\n1000\n1000\nyes\n"),
            Some(PhpState {
                uid: 1000,
                gid: 1000,
                remap_requested: true,
                image_supports_remap: true,
            })
        );
    }

    #[test]
    fn parse_php_state_old_image_and_compose_file() {
        // An unset variable echoes an empty line, keeping the line positions.
        assert_eq!(
            parse_php_state("33\n33\n\nno\n"),
            Some(PhpState {
                uid: 33,
                gid: 33,
                remap_requested: false,
                image_supports_remap: false,
            })
        );
    }

    #[test]
    fn parse_php_state_rejects_garbage() {
        assert_eq!(parse_php_state(""), None);
        assert_eq!(parse_php_state("33\n33\n\n"), None);
        assert_eq!(parse_php_state("id: 'www-data': no such user\n"), None);
    }

    #[test]
    fn existing_dirs_keeps_only_present_ones() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir(dir.path().join("htdocs")).unwrap();
        assert_eq!(existing_dirs(dir.path()), vec!["htdocs".to_string()]);
    }

    #[test]
    fn find_foreign_owned_ignores_own_files() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join("htdocs/sub")).unwrap();
        std::fs::write(dir.path().join("htdocs/sub/a.php"), "").unwrap();
        let (uid, _) = docker::host_ids();
        let dirs = existing_dirs(dir.path());
        assert!(
            find_foreign_owned(dir.path(), &dirs, uid)
                .unwrap()
                .is_empty()
        );
        // Everything is foreign to another uid.
        assert_eq!(
            find_foreign_owned(dir.path(), &dirs, uid + 1)
                .unwrap()
                .len(),
            3
        );
    }
}
