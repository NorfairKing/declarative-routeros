use std::{
    fs::read_to_string,
    io::Write,
    path::{Path, PathBuf},
};

use clap::Args;
use ssh2::Session;
use tracing::{debug, error, info};

use crate::session::{connect, SessionSettings};

#[derive(Debug, Clone, Args)]
pub struct ApplyFlags {
    #[arg()]
    script_file: PathBuf,
}

pub struct ApplySettings {
    script_file: PathBuf,
}

pub fn combine_to_apply_settings(flags: ApplyFlags) -> ApplySettings {
    let script_file = flags.script_file;
    ApplySettings { script_file }
}

pub fn command(
    session_settings: SessionSettings,
    apply_settings: ApplySettings,
) -> Result<(), ssh2::Error> {
    let session = connect(session_settings)?;
    apply(apply_settings, session)?;
    Ok(())
}

const REMOTE_FILENAME: &str = "declarative-routeros-script.rsc";

fn apply(apply_settings: ApplySettings, session: Session) -> Result<(), ssh2::Error> {
    let remote_filename = Path::new(REMOTE_FILENAME);
    upload_script(apply_settings, &session, remote_filename)?;
    reset_into_configuration(session, remote_filename)
}

/// Upload the configuration script
fn upload_script(
    apply_settings: ApplySettings,
    session: &Session,
    remote_filename: &Path,
) -> Result<(), ssh2::Error> {
    // TODO error handling about the filename
    let str = read_to_string(apply_settings.script_file).unwrap();
    let bytes = str.as_bytes();

    let mut remote_file = session.scp_send(remote_filename, 0o644, bytes.len() as u64, None)?;
    remote_file.write_all(bytes).unwrap();

    // Close the channel and wait for the whole content to be tranferred
    remote_file.send_eof().unwrap();
    remote_file.wait_eof().unwrap();
    remote_file.close().unwrap();
    remote_file.wait_close().unwrap();
    Ok(())
}

/// Reset the router with the new configuration
fn reset_into_configuration(session: Session, remote_filename: &Path) -> Result<(), ssh2::Error> {
    let mut channel = session.channel_session()?;
    let reset_command = format!(
        "/system reset-configuration keep-users=yes no-defaults=yes run-after-reset={}",
        remote_filename.display()
    );
    info!("Running remotely: {}", reset_command);
    // We can't use the `run_command_remotely` function here because it tries reads the router's response
    // in the ssh2 channel, but the router does not send such a respond because it's already busy
    // resetting.
    channel.exec(&reset_command)?;
    // Don't wait for a response because the system resets immediately
    let exit_status = channel.exit_status()?;
    debug!("Exit code: {}", exit_status);
    if exit_status != 0 {
        error!("Command failed with exit code: {}.", exit_status);
    }
    Ok(())
}
