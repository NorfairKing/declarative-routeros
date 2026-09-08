use std::io::{stdout, IsTerminal};
use std::sync::OnceLock;
use std::time::Instant;

// Steps rather than a progress bar: what went wrong is diagnosed from what had
// already been said, and output that erases itself leaves nothing to read.
const RESET: &str = "\x1b[0m";
const BOLD_BLUE: &str = "\x1b[1;34m";
const GREEN: &str = "\x1b[32m";
const DIM: &str = "\x1b[2m";
const BOLD_YELLOW: &str = "\x1b[1;33m";
const BOLD_RED: &str = "\x1b[1;31m";

static STARTED: OnceLock<Instant> = OnceLock::new();

/// Call before anything is printed, so the first line is at zero.
pub fn start() {
    STARTED.get_or_init(Instant::now);
}

pub fn step(what: &str) {
    println!(
        "{} {}==>{} {}",
        since(),
        paint(BOLD_BLUE),
        paint(RESET),
        what
    );
}

pub fn good(what: &str) {
    println!("{}     {}{}{}", since(), paint(GREEN), what, paint(RESET));
}

pub fn detail(what: &str) {
    println!("{}     {}{}{}", since(), paint(DIM), what, paint(RESET));
}

pub fn warn(what: &str) {
    println!(
        "{} {}!!!{} {}",
        since(),
        paint(BOLD_YELLOW),
        paint(RESET),
        what
    );
}

/// A message and an exit code rather than a panic: what goes wrong here is
/// nearly always a router or a file, and neither is a bug in this.
pub fn fatal(what: &str, complaint: &str) -> ! {
    problem(what);
    detail(complaint);
    std::process::exit(1)
}

/// To stderr, the one thing worth keeping when the rest is piped away.
pub fn problem(what: &str) {
    eprintln!(
        "{} {}!!!{} {}",
        since(),
        paint(BOLD_RED),
        paint(RESET),
        what
    );
}

fn since() -> String {
    let seconds = STARTED.get_or_init(Instant::now).elapsed().as_secs();
    let stamp = format!("[{:02}:{:02}]", seconds / 60, seconds % 60);
    format!("{}{}{}", paint(DIM), stamp, paint(RESET))
}

fn paint(code: &str) -> &str {
    if stdout().is_terminal() && std::env::var_os("NO_COLOR").is_none() {
        code
    } else {
        ""
    }
}

pub fn plural(count: usize) -> &'static str {
    if count == 1 {
        ""
    } else {
        "s"
    }
}

pub fn this_command() -> String {
    std::env::args()
        .next()
        .unwrap_or_else(|| "declarative-routeros".to_string())
}
