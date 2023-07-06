use std::env;

use clap::Parser;
use commands::apply::combine_to_apply_settings;
use commands::apply::ApplyFlags;
use session::SessionSettings;

mod commands;
mod session;

use crate::commands::apply;
use crate::commands::download;

#[derive(Parser, Debug)]
enum Command {
    /// Download a system's configuration
    Download,
    /// Apply a configuration
    Apply(ApplyFlags),
}

fn main() -> Result<(), ssh2::Error> {
    let command = Command::parse();
    let settings = SessionSettings {
        user: env::var("ROUTEROS_SSH_USER").unwrap(),
        password: env::var("ROUTEROS_SSH_PASSWORD").unwrap(),
        address: "192.168.100.1:22".parse().unwrap(),
    };

    match command {
        Command::Download => download::command(settings),
        Command::Apply(apply_flags) => {
            apply::command(settings, combine_to_apply_settings(apply_flags))
        }
    }
}
