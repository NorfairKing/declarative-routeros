use clap::Parser;

mod commands;

use crate::commands::download::command_download;

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
        Command::Download => command_download(),
        Command::Apply => todo!(),
    }
}
