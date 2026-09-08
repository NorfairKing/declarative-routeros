use clap::{Parser, Subcommand};
use tracing_subscriber::EnvFilter;

mod commands;
mod report;
mod session;

use crate::commands::download::{self, DownloadFlags};
use crate::commands::import::{self, ImportFlags};
use crate::commands::reset_into::{self, ResetIntoFlags};
use crate::commands::router::{self, RouterFlags};
use crate::commands::settle::{self, SettleFlags};
use crate::commands::wait::{self, WaitFlags};

#[derive(Debug, Clone, Parser)]
struct Arguments {
    #[command(subcommand)]
    command: Command,
}

/// Which router, per command: `router` is told by its file, the rest on the
/// command line.
#[derive(Debug, Clone, Subcommand)]
enum Command {
    /// Download a system's configuration
    Download(DownloadFlags),
    /// Reset the router into one whole configuration file
    ResetInto(ResetIntoFlags),
    /// Import a configuration onto a running router, without resetting it
    Import(ImportFlags),
    /// Connect and run :put ready until the router answers
    Wait(WaitFlags),
    /// Read /export until it has no error comments
    Settle(SettleFlags),
    /// Everything for one router, from a file a flake wrote
    Router(RouterFlags),
}

fn main() -> Result<(), ssh2::Error> {
    report::start();
    let arguments = Arguments::parse();

    tracing_subscriber::fmt()
        .with_target(false)
        .with_thread_ids(false)
        .with_thread_names(false)
        .with_env_filter(EnvFilter::from_default_env())
        .compact()
        .init();

    match arguments.command {
        Command::Download(flags) => download::command(flags),
        Command::ResetInto(flags) => reset_into::command(flags),
        Command::Import(flags) => import::command(flags),
        Command::Wait(flags) => wait::command(flags),
        Command::Settle(flags) => settle::command(flags),
        Command::Router(flags) => router::command(flags),
    }
}
