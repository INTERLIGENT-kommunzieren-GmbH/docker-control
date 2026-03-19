use console::{StyledObject, style};
use std::sync::atomic::{AtomicBool, Ordering};

static DEBUG: AtomicBool = AtomicBool::new(false);

pub fn set_debug(enabled: bool) {
    DEBUG.store(enabled, Ordering::Relaxed);
}

pub fn is_debug() -> bool {
    DEBUG.load(Ordering::Relaxed)
}

pub fn debug<S: Into<String>>(msg: S) {
    if is_debug() {
        eprintln!("{} {}", style("[DEBUG]").dim(), msg.into());
    }
}

pub fn critical<S: Into<String>>(msg: S) {
    eprintln!("{}", style(msg.into()).red().bold());
}

pub fn info<S: Into<String>>(msg: S) {
    println!("{}", style(msg.into()).blue());
}

pub fn warning<S: Into<String>>(msg: S) {
    println!("{}", style(msg.into()).yellow());
}

pub fn success<S: Into<String>>(msg: S) {
    println!("{}", style(msg.into()).green());
}

#[allow(dead_code)]
pub fn bold<S: Into<String>>(msg: S) -> StyledObject<String> {
    style(msg.into()).bold()
}

#[allow(dead_code)]
pub fn cyan<S: Into<String>>(msg: S) -> StyledObject<String> {
    style(msg.into()).cyan()
}

pub fn yellow<S: Into<String>>(msg: S) -> StyledObject<String> {
    style(msg.into()).yellow()
}
