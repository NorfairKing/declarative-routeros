use clap::Parser;

mod commands;
mod session;

use crate::commands::apply;
use crate::commands::download;

#[derive(Parser, Debug)]
enum Command {
    /// Download a system's configuration
    Download,
    /// Apply a configuration
    Apply,
}

fn main() -> Result<(), ssh2::Error> {
    let command = Command::parse();

    match command {
        Command::Download => download::command(),
        Command::Apply => apply::command(),
    }
}
