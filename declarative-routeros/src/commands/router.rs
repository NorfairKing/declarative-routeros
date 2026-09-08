use std::net::{IpAddr, SocketAddr};
use std::path::PathBuf;

use clap::{Args, Subcommand};
use serde::Deserialize;

use crate::commands::{apply, download, import};
use crate::report;
use crate::session::{contents_of, SessionSettings};

#[derive(Debug, Clone, Args)]
pub struct RouterFlags {
    /// Everything about one router, as the flake that built this wrote it
    #[arg(long)]
    settings: PathBuf,
    #[command(subcommand)]
    action: Option<Action>,
    /// Do not ask before applying
    #[arg(long)]
    yes: bool,
}

/// Applying is the default; the other two are what a stopped deployment needs.
#[derive(Debug, Clone, Subcommand)]
enum Action {
    /// Reset into the half that gets you back in, then import the other half
    Apply,
    /// Read what the router says about itself into the record the checks read
    Download,
    /// Import the second half onto the router as it is, without resetting it
    ImportRest,
}

/// Written by nix: all of it is known when the deployment is built.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Router {
    name: String,
    username: String,
    address: IpAddr,
    port: u16,
    prefix: PathBuf,
    rest: PathBuf,
    checked_against: PathBuf,
    record_into: PathBuf,
}

pub fn command(flags: RouterFlags) -> Result<(), ssh2::Error> {
    let router: Router = match serde_json::from_slice(&contents_of(&flags.settings)) {
        Ok(router) => router,
        Err(complaint) => report::fatal(
            &format!("Could not read {}.", flags.settings.display()),
            &complaint.to_string(),
        ),
    };
    let session = SessionSettings {
        username: router.username.clone(),
        router_address: SocketAddr::new(router.address, router.port),
    };
    match flags.action.unwrap_or(Action::Apply) {
        Action::Apply => apply::command(
            session,
            apply::ApplySettings {
                name: router.name,
                prefix: router.prefix,
                rest: router.rest,
                checked_against: router.checked_against,
                record_into: router.record_into,
                asking: if flags.yes {
                    apply::Asking::AlreadyAnswered
                } else {
                    apply::Asking::Ask
                },
            },
        ),
        Action::Download => {
            download::command_with(session, download::download_into(&router.record_into))
        }
        Action::ImportRest => {
            if import::import_onto(session, import::import_settings_for(&router.rest))? {
                Ok(())
            } else {
                std::process::exit(1)
            }
        }
    }
}

