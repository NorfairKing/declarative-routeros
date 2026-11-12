use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::exit;
use std::time::{Duration, Instant};

use clap::Args;
use ssh2::Session;
use tracing::debug;

use crate::commands::preflight::preflight;
use crate::commands::wait;
use crate::report;
use crate::session::{combine_to_session_settings, connect, contents_of, upload, SessionFlags, SessionSettings};

#[derive(Debug, Clone, Args)]
pub struct ResetIntoFlags {
    #[command(flatten)]
    session: SessionFlags,
    #[arg()]
    script_file: PathBuf,
}

pub struct ResetIntoSettings {
    script_file: PathBuf,
}

pub fn reset_into_settings_for(script_file: &Path) -> ResetIntoSettings {
    ResetIntoSettings {
        script_file: script_file.to_path_buf(),
    }
}

pub fn command(flags: ResetIntoFlags) -> Result<(), ssh2::Error> {
    let session_settings = combine_to_session_settings(flags.session);
    // A file the router refuses after the reset leaves it with nothing on it.
    if !preflight(session_settings.clone(), &flags.script_file)? {
        exit(1)
    }
    command_with(session_settings, reset_into_settings_for(&flags.script_file))
}

pub fn command_with(
    session_settings: SessionSettings,
    reset_into_settings: ResetIntoSettings,
) -> Result<(), ssh2::Error> {
    let session = connect(session_settings.clone())?;
    let uptime_before = wait::uptime_over(&session).unwrap_or_else(|complaint| {
        report::fatal("Could not read the router's uptime.", &complaint)
    });
    let asked_at = Instant::now();
    reset_into(reset_into_settings, session)?;
    report::detail("waiting for the router to have reset");
    wait::wait_for_reset(&session_settings, uptime_before, asked_at);
    Ok(())
}

const REMOTE_FILENAME: &str = "declarative-routeros-script.rsc";

const RESET_ANSWER_TIMEOUT: Duration = Duration::from_secs(60);

fn reset_into(reset_into_settings: ResetIntoSettings, session: Session) -> Result<(), ssh2::Error> {
    let remote_filename = Path::new(REMOTE_FILENAME);
    upload_script(reset_into_settings, &session, remote_filename)?;
    reset_into_configuration(session, remote_filename)
}

fn upload_script(
    reset_into_settings: ResetIntoSettings,
    session: &Session,
    remote_filename: &Path,
) -> Result<(), ssh2::Error> {
    upload(
        session,
        remote_filename,
        &contents_of(&reset_into_settings.script_file),
    )
}

fn reset_into_configuration(session: Session, remote_filename: &Path) -> Result<(), ssh2::Error> {
    let mut channel = session.channel_session()?;
    let reset_command = format!(
        "/system reset-configuration keep-users=yes no-defaults=yes run-after-reset={}",
        remote_filename.display()
    );
    report::detail(&format!("running: {}", reset_command));
    // A router that goes down before it closes the channel could otherwise
    // keep this waiting forever.
    session.set_timeout(RESET_ANSWER_TIMEOUT.as_millis() as u32);
    channel.exec(&reset_command)?;
    let mut answer = String::new();
    // Before the channel has closed, the exit status is 0 whatever the command
    // did.
    let closed = channel
        .read_to_string(&mut answer)
        .map_err(|complaint| complaint.to_string())
        .and_then(|_| channel.wait_close().map_err(|complaint| complaint.to_string()));
    if let Err(complaint) = closed {
        report::fatal(
            "Could not tell whether the router took the reset.",
            &format!(
                "{}\nIt may be resetting: look at it before deploying again.",
                complaint
            ),
        );
    }
    let exit_status = channel.exit_status()?;
    debug!("Exit code: {}", exit_status);
    // A router that refused the reset keeps its configuration, and waiting for
    // it to reboot would wait for nothing.
    if exit_status != 0 {
        report::fatal(
            "The router refused to reset.",
            &format!("Exit code {}: {}", exit_status, answer.trim()),
        );
    }
    Ok(())
}
