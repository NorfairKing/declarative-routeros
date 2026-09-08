use std::path::{Path, PathBuf};

use clap::Args;
use ssh2::Session;
use tracing::debug;

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
    command_with(
        combine_to_session_settings(flags.session),
        reset_into_settings_for(&flags.script_file),
    )
}

pub fn command_with(
    session_settings: SessionSettings,
    reset_into_settings: ResetIntoSettings,
) -> Result<(), ssh2::Error> {
    let session = connect(session_settings)?;
    reset_into(reset_into_settings, session)?;
    Ok(())
}

const REMOTE_FILENAME: &str = "declarative-routeros-script.rsc";

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
    channel.exec(&reset_command)?;
    // No response to read: the router is already resetting.
    let exit_status = channel.exit_status()?;
    debug!("Exit code: {}", exit_status);
    if exit_status != 0 {
        report::warn(&format!("Exit code {} from the reset.", exit_status));
    }
    Ok(())
}
