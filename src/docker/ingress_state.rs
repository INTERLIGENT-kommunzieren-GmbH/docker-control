//! Records which ingress stack the running proxy was started from, so that an
//! upgrade which actually changed `ingress/` can be noticed afterwards.
//!
//! This exists because Homebrew has no hook to hang it off. A formula's only
//! hook is `post_install`, which runs *after* the new keg is linked (so it can
//! never stop the proxy first) and runs sandboxed with `deny_read_home` and
//! `deny_all_network` (so it cannot reach the Docker socket or the
//! `~/.docker` context at all). `preflight`/`uninstall_preflight`, which would
//! give the wanted semantics, are cask-only and casks are macOS-only. So the
//! tool has to notice for itself, on a later invocation.
//!
//! The stamp is a *content* fingerprint rather than a version, because
//! `ingress/` changes far less often than the tool does: stamping the version
//! would offer a proxy restart after every single upgrade while changing
//! nothing. Same reasoning as the template state in [`crate::template`].

use crate::ui;
use crate::utils;
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use walkdir::WalkDir;

const STATE_FILE: &str = ".state.json";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IngressState {
    /// Hash over the contents of the ingress asset directory the proxy was
    /// last started from.
    pub ingress_fingerprint: String,
    /// docker-control version that started it. Used for the notice's wording
    /// only — the fingerprint above is what decides staleness.
    pub started_with: String,
}

impl IngressState {
    /// `<prefix>/etc/docker-control/ingress/.state.json`.
    ///
    /// Beside `volumes/` and never inside it: `ensure_ingress_volumes` copies
    /// over that subtree wholesale on every `up`. The parent directory is
    /// already written to on every `up` for the same reason, so it is known to
    /// be writable wherever the proxy can be started at all.
    ///
    /// Takes the prefix rather than resolving it so tests can point it at a
    /// temporary directory.
    pub fn path_in(prefix: &Path) -> PathBuf {
        prefix
            .join("etc")
            .join("docker-control")
            .join("ingress")
            .join(STATE_FILE)
    }

    /// Loads the state, or `None` when it is missing or unreadable. A corrupt
    /// file is treated as absent rather than fatal, like
    /// [`crate::template::TemplateState::load`]: the worst case is one skipped
    /// notice, which must never block the command being run.
    pub fn load_from(prefix: &Path) -> Option<Self> {
        let raw = std::fs::read_to_string(Self::path_in(prefix)).ok()?;
        serde_json::from_str(&raw).ok()
    }

    pub fn save_to(&self, prefix: &Path) -> Result<()> {
        let path = Self::path_in(prefix);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("Failed to create {:?}", parent))?;
        }
        let json = serde_json::to_string_pretty(self)?;
        std::fs::write(&path, format!("{}\n", json))
            .with_context(|| format!("Failed to write {:?}", path))
    }
}

/// A single hash standing in for the whole ingress asset directory.
///
/// Deliberately not [`crate::template::manifest`]: its runtime filter skips
/// `volumes/` at the root, which is precisely the ingress payload
/// (`volumes/vhosts.d`, `volumes/tls`). The fold is
/// [`crate::template::fingerprint`], so both stamps reduce a manifest the same
/// way.
pub fn fingerprint(ingress_dir: &Path) -> Result<String> {
    let mut files = BTreeMap::new();
    for entry in WalkDir::new(ingress_dir).min_depth(1) {
        let entry = entry?;
        if !entry.file_type().is_file() {
            continue;
        }
        let rel = entry
            .path()
            .strip_prefix(ingress_dir)
            .with_context(|| format!("{:?} is not under {:?}", entry.path(), ingress_dir))?
            .components()
            .map(|c| c.as_os_str().to_string_lossy())
            .collect::<Vec<_>>()
            .join("/");
        files.insert(rel, utils::hash_file(entry.path())?);
    }
    Ok(crate::template::fingerprint(&files))
}

/// Records the ingress assets the proxy has just been started from.
///
/// Best-effort: a failure only means the staleness notice stays quiet, so it is
/// logged at debug level rather than failing an `up` that already succeeded —
/// the same trade-off [`crate::utils::throttle_cache::record`] makes. The whole
/// error chain is printed, since the interesting part of a failed write here is
/// the underlying `EACCES`, not the path.
pub fn record(ingress_dir: &Path) {
    let prefix = super::resolve_brew_prefix();
    if let Err(e) = record_in(Path::new(&prefix), ingress_dir) {
        ui::debug(format!("Could not record ingress state: {:#}", e));
    }
}

pub fn record_in(prefix: &Path, ingress_dir: &Path) -> Result<()> {
    IngressState {
        ingress_fingerprint: fingerprint(ingress_dir)?,
        started_with: env!("CARGO_PKG_VERSION").to_string(),
    }
    .save_to(prefix)
}

/// The recorded state when the proxy was started from a different ingress stack
/// than this binary ships, or `None` when the two match.
///
/// A missing or unreadable stamp is deliberately *not* reported as stale.
/// Nothing but a `start-ingress` can clear an unknown base, so treating it as
/// stale would nag on every invocation forever — the same reason
/// `maybe_report_template_drift` leaves `unknown` out of its notice.
pub fn stale() -> Option<IngressState> {
    let prefix = super::resolve_brew_prefix();
    stale_in(Path::new(&prefix), &super::find_ingress_dir().ok()?)
}

pub fn stale_in(prefix: &Path, ingress_dir: &Path) -> Option<IngressState> {
    let recorded = IngressState::load_from(prefix)?;
    let current = fingerprint(ingress_dir).ok()?;
    (recorded.ingress_fingerprint != current).then_some(recorded)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Builds a stand-in for the shipped `ingress/` directory: a compose file
    /// plus the two volume subtrees the real one has.
    fn ingress_dir(root: &Path, compose: &str) -> PathBuf {
        let dir = root.join("ingress");
        std::fs::create_dir_all(dir.join("volumes/vhosts.d")).unwrap();
        std::fs::create_dir_all(dir.join("volumes/tls")).unwrap();
        std::fs::write(dir.join("compose.yml"), compose).unwrap();
        std::fs::write(dir.join("volumes/vhosts.d/default"), "default\n").unwrap();
        std::fs::write(dir.join("volumes/tls/.gitkeep"), "").unwrap();
        dir
    }

    #[test]
    fn fingerprint_is_stable_across_calls() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = ingress_dir(tmp.path(), "services: {}\n");
        assert_eq!(fingerprint(&dir).unwrap(), fingerprint(&dir).unwrap());
    }

    #[test]
    fn fingerprint_follows_compose_content() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = ingress_dir(tmp.path(), "services: {}\n");
        let before = fingerprint(&dir).unwrap();
        std::fs::write(dir.join("compose.yml"), "services: {nginx: {}}\n").unwrap();
        assert_ne!(before, fingerprint(&dir).unwrap());
    }

    #[test]
    fn fingerprint_covers_the_volumes_subtree() {
        // The whole point of not reusing `template::manifest`, whose runtime
        // filter would skip `volumes/` and miss a changed vhost.
        let tmp = tempfile::tempdir().unwrap();
        let dir = ingress_dir(tmp.path(), "services: {}\n");
        let before = fingerprint(&dir).unwrap();
        std::fs::write(
            dir.join("volumes/vhosts.d/default"),
            "client_max_body_size 0;\n",
        )
        .unwrap();
        assert_ne!(before, fingerprint(&dir).unwrap());
    }

    #[test]
    fn fingerprint_notices_an_added_file() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = ingress_dir(tmp.path(), "services: {}\n");
        let before = fingerprint(&dir).unwrap();
        std::fs::write(dir.join("volumes/vhosts.d/extra"), "default\n").unwrap();
        assert_ne!(before, fingerprint(&dir).unwrap());
    }

    #[test]
    fn state_round_trips_through_the_prefix() {
        let tmp = tempfile::tempdir().unwrap();
        let state = IngressState {
            ingress_fingerprint: "abc123".to_string(),
            started_with: "2.7.0".to_string(),
        };
        state.save_to(tmp.path()).unwrap();

        let loaded = IngressState::load_from(tmp.path()).unwrap();
        assert_eq!(loaded.ingress_fingerprint, "abc123");
        assert_eq!(loaded.started_with, "2.7.0");
    }

    #[test]
    fn state_lives_beside_the_volumes_the_up_overwrites() {
        // Inside `volumes/` it would be clobbered by `ensure_ingress_volumes`.
        let path = IngressState::path_in(Path::new("/opt/homebrew"));
        assert_eq!(
            path,
            Path::new("/opt/homebrew/etc/docker-control/ingress/.state.json")
        );
    }

    #[test]
    fn nothing_recorded_is_not_stale() {
        // An unknown base must stay quiet: only `start-ingress` can clear it,
        // so reporting it would nag forever.
        let tmp = tempfile::tempdir().unwrap();
        let dir = ingress_dir(tmp.path(), "services: {}\n");
        assert!(stale_in(tmp.path(), &dir).is_none());
    }

    #[test]
    fn a_corrupt_stamp_is_not_stale() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = ingress_dir(tmp.path(), "services: {}\n");
        let path = IngressState::path_in(tmp.path());
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, "{ not json").unwrap();
        assert!(stale_in(tmp.path(), &dir).is_none());
    }

    #[test]
    fn unchanged_assets_are_not_stale() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = ingress_dir(tmp.path(), "services: {}\n");
        record_in(tmp.path(), &dir).unwrap();
        assert!(stale_in(tmp.path(), &dir).is_none());
    }

    #[test]
    fn changed_assets_are_stale_and_report_what_started_the_proxy() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = ingress_dir(tmp.path(), "services: {}\n");
        record_in(tmp.path(), &dir).unwrap();

        std::fs::write(dir.join("compose.yml"), "services: {nginx: {}}\n").unwrap();

        let stale = stale_in(tmp.path(), &dir).expect("changed ingress should be stale");
        assert_eq!(stale.started_with, env!("CARGO_PKG_VERSION"));
    }

    #[test]
    fn re_recording_clears_the_staleness() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = ingress_dir(tmp.path(), "services: {}\n");
        record_in(tmp.path(), &dir).unwrap();
        std::fs::write(dir.join("compose.yml"), "services: {nginx: {}}\n").unwrap();
        assert!(stale_in(tmp.path(), &dir).is_some());

        record_in(tmp.path(), &dir).unwrap();
        assert!(stale_in(tmp.path(), &dir).is_none());
    }
}
