use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::exit;

use clap::Args;


use crate::report;
use crate::session::{combine_to_session_settings, connect, contents_of, upload, SessionFlags, SessionSettings};

/// The half that is allowed to fail: the router is still there either way.
#[derive(Debug, Clone, Args)]
pub struct ImportFlags {
    #[command(flatten)]
    session: SessionFlags,
    #[arg()]
    script_file: PathBuf,
}

pub struct ImportSettings {
    script_file: PathBuf,
}

pub fn import_settings_for(script_file: &Path) -> ImportSettings {
    ImportSettings {
        script_file: script_file.to_path_buf(),
    }
}

const REMOTE_FILENAME: &str = "declarative-routeros-import.rsc";

pub fn command(flags: ImportFlags) -> Result<(), ssh2::Error> {
    if import_onto(
        combine_to_session_settings(flags.session),
        import_settings_for(&flags.script_file),
    )? {
        Ok(())
    } else {
        exit(1)
    }
}

pub fn import_onto(
    session_settings: SessionSettings,
    import_settings: ImportSettings,
) -> Result<bool, ssh2::Error> {
    let session = connect(session_settings)?;
    let remote_filename = Path::new(REMOTE_FILENAME);
    upload_script(import_settings, &session, remote_filename)?;
    import(&session, remote_filename)
}

fn upload_script(
    import_settings: ImportSettings,
    session: &ssh2::Session,
    remote_filename: &Path,
) -> Result<(), ssh2::Error> {
    upload(
        session,
        remote_filename,
        &contents_of(&import_settings.script_file),
    )
}

/// RouterOS says nothing about an import run over ssh, though the same command
/// on a console prints every line, so the exit status is the only verdict.
fn import(session: &ssh2::Session, remote_filename: &Path) -> Result<bool, ssh2::Error> {
    let import_command = format!("/import file={}", remote_filename.display());
    report::detail(&format!("running: {}", import_command));

    let mut channel = session.channel_session()?;
    channel.exec(&import_command)?;
    let mut response = String::new();
    // Which stream RouterOS uses is not worth finding out the hard way.
    for stream in ["stdout", "stderr"] {
        let read = if stream == "stdout" {
            channel.read_to_string(&mut response)
        } else {
            channel.stderr().read_to_string(&mut response)
        };
        if let Err(complaint) = read {
            report::warn(&format!("Could not read the router's {}: {}", stream, complaint));
        }
    }
    channel.wait_close()?;
    let exit_status = channel.exit_status()?;

    for line in response.lines().map(str::trim).filter(|line| !line.is_empty()) {
        report::detail(line);
    }

    if exit_status == 0 {
        Ok(true)
    } else {
        report::problem(&format!("The router refused the file, exit code {}.", exit_status));
        report::detail("An import stops at the line that fails and keeps everything above it, so how much was applied is not something this can tell you.");
        report::detail("Read the router before running this again.");
        Ok(false)
    }
}
