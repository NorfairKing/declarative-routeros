use clap::{Parser, Subcommand};
use commands::apply::combine_to_apply_settings;
use commands::apply::ApplyFlags;
use commands::download::combine_to_download_settings;
use commands::download::DownloadFlags;
use session::combine_to_session_settings;
use session::SessionFlags;
use tracing_subscriber::EnvFilter;

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
    Download(DownloadFlags),
    /// Apply a configuration
    Apply(ApplyFlags),
}

fn main() -> Result<(), ssh2::Error> {
    let arguments = Arguments::parse();
    let settings = combine_to_session_settings(arguments.flags);

    tracing_subscriber::fmt()
        .with_target(false) // don't include targets
        .with_thread_ids(false) // include the thread ID of the current thread
        .with_thread_names(false) // include the name of the current thread
        .with_env_filter(EnvFilter::from_default_env())
        .compact()
        .init();

    match arguments.command {
        Command::Download(download_flags) => {
            download::command(settings, combine_to_download_settings(download_flags))
        }
        Command::Apply(apply_flags) => {
            apply::command(settings, combine_to_apply_settings(apply_flags))
        }
    }
}
