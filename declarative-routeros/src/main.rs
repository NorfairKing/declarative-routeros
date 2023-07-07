use clap::{Parser, Subcommand};
use commands::apply::combine_to_apply_settings;
use commands::apply::ApplyFlags;
use session::combine_to_session_settings;
use session::SessionFlags;

mod commands;
mod session;

use crate::commands::apply;
use crate::commands::download;

#[derive(Debug, Clone, Parser)]
struct Arguments {
    #[command(subcommand)]
    command: Command,

    #[command(flatten)]
    flags: SessionFlags,
}

#[derive(Debug, Clone, Subcommand)]
enum Command {
    /// Download a system's configuration
    Download,
    /// Apply a configuration
    Apply(ApplyFlags),
}

fn main() -> Result<(), ssh2::Error> {
    let arguments = Arguments::parse();
    let settings = combine_to_session_settings(arguments.flags);

    match arguments.command {
        Command::Download => download::command(settings),
        Command::Apply(apply_flags) => {
            apply::command(settings, combine_to_apply_settings(apply_flags))
        }
    }
}
