use std::{
    fs::read_to_string,
    io::Write,
    path::{Path, PathBuf},
};

use clap::Parser;
use ssh2::Session;

use crate::session::{connect, SessionSettings};

#[derive(Parser, Debug)]
pub struct ApplyFlags {
    #[arg(short, long)]
    script_file: PathBuf,
}

pub struct ApplySettings {
    script_file: PathBuf,
}

pub fn combine_to_apply_settings(flags: ApplyFlags) -> ApplySettings {
    let script_file = flags.script_file.to_path_buf();
    ApplySettings { script_file }
}

pub fn command(
    session_settings: SessionSettings,
    apply_settings: ApplySettings,
) -> Result<(), ssh2::Error> {
    let session = connect(session_settings)?;
    apply(apply_settings, session);
    Ok(())
}

const REMOTE_FILENAME: &Path = Path::new("declarative-routeros-script.rsc");

fn apply(apply_settings: ApplySettings, session: Session) -> Result<(), ssh2::Error> {
    let mut remote_file = session.scp_send(&REMOTE_FILENAME, 0o644, 10, None)?;

    let str = read_to_string(apply_settings.script_file)?;
    remote_file.write(str).unwrap();

    // Close the channel and wait for the whole content to be tranferred
    remote_file.send_eof().unwrap();
    remote_file.wait_eof().unwrap();
    remote_file.close().unwrap();
    remote_file.wait_close().unwrap();

    // let mut channel = sess.channel_session().unwrap();
    // channel.exec("echo running: /system reset-configuration keep-users no-defaults run-after-reset=new-build.rsc").unwrap();
    // let mut s = String::new();
    // channel.read_to_string(&mut s).unwrap();
    // println!("{}", s);
    // channel.wait_close();
    // println!("{}", channel.exit_status().unwrap());
}
