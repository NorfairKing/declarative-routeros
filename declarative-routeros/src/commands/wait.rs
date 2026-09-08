use std::thread::sleep;
use std::time::Duration;

use clap::Args;

use crate::report;
use crate::session::{combine_to_session_settings, try_capture_command_remotely, try_connect, SessionFlags, SessionSettings};

#[derive(Debug, Clone, Args)]
pub struct WaitFlags {
    #[command(flatten)]
    session: SessionFlags,
}

/// RouterOS listens well before it will authenticate, so a port that answers
/// promises nothing. No deadline: one that fires half way through a deployment
/// is worse than waiting.
pub fn command(flags: WaitFlags) -> Result<(), ssh2::Error> {
    wait_for(combine_to_session_settings(flags.session))
}

pub fn wait_for(session_settings: SessionSettings) -> Result<(), ssh2::Error> {
    let mut attempts = 1;
    loop {
        match answers(&session_settings) {
            Ok(()) => {
                report::good(&format!("answered after {} attempt{}", attempts, report::plural(attempts)));
                return Ok(());
            }
            Err(complaint) => {
                // One that prints once looks like one that has hung.
                report::detail(&format!("attempt {}: {}", attempts, complaint));
                attempts += 1;
                sleep(Duration::from_secs(2));
            }
        }
    }
}

fn answers(settings: &SessionSettings) -> Result<(), String> {
    let session = try_connect(settings)?;
    let response = try_capture_command_remotely(&session, ":put ready").map_err(|complaint| {
        format!(
            "the router took the connection but not a command: {}",
            complaint
        )
    })?;
    if response.trim() == "ready" {
        Ok(())
    } else {
        Err(format!(
            "the router said {:?} rather than ready",
            response.trim()
        ))
    }
}
