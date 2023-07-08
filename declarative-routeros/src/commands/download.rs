use std::io::prelude::*;
use std::path::Path;
use std::{fs::File, path::PathBuf};

use clap::Args;
use tracing::{debug, info};

use crate::session::{connect, run_command_remotely, SessionSettings};

#[derive(Debug, Clone, Args)]
pub struct DownloadFlags {
    #[arg(short, long)]
    output_file: Option<PathBuf>,
}

pub struct DownloadSettings {
    output_file: PathBuf,
}

pub fn combine_to_download_settings(flags: DownloadFlags) -> DownloadSettings {
    let output_file = flags
        .output_file
        .unwrap_or(Path::new("declarative-routeros-download.rsc").to_path_buf());
    DownloadSettings { output_file }
}

pub fn command(
    session_settings: SessionSettings,
    download_settings: DownloadSettings,
) -> Result<(), ssh2::Error> {
    let session = connect(session_settings)?;
    download(download_settings, &session)
}

// Based on the example at https://docs.rs/ssh2/latest/ssh2/
fn download(settings: DownloadSettings, session: &ssh2::Session) -> Result<(), ssh2::Error> {
    let backup_remote_file_name = "declarative-routeros-backup.rsc";

    create_backup_remotely(session, backup_remote_file_name)?;
    let contents = transfer_backup_to_local(session, backup_remote_file_name);
    write_file_locally(&settings.output_file, contents);
    delete_backup_remotely(session, backup_remote_file_name)
}

/// Create the backup script export on the router side
fn create_backup_remotely(
    session: &ssh2::Session,
    backup_remote_file_name: &str,
) -> Result<(), ssh2::Error> {
    let export_command = format!("/export file=\"{}\"", backup_remote_file_name);
    run_command_remotely(session, &export_command)
}

/// Transfer the backup script to the local machine
fn transfer_backup_to_local(session: &ssh2::Session, backup_remote_file_name: &str) -> Vec<u8> {
    let remote_file_path = Path::new(backup_remote_file_name);
    let (mut remote_file, stat) = session.scp_recv(remote_file_path).unwrap();
    info!("Fetching remote file: {}", remote_file_path.display());
    debug!("Remote file size: {}", stat.size());
    let mut contents = Vec::new();
    remote_file.read_to_end(&mut contents).unwrap();
    remote_file.send_eof().unwrap();
    remote_file.wait_eof().unwrap();
    remote_file.close().unwrap();
    remote_file.wait_close().unwrap();
    contents
}

/// Write the file locally
fn write_file_locally(local_file_path: &Path, contents: Vec<u8>) {
    let mut f = File::create(local_file_path).unwrap();
    info!("Writing local file: {}", local_file_path.display());
    f.write_all(contents.as_slice()).unwrap();
}

/// Delete the backup script remotely
fn delete_backup_remotely(
    session: &ssh2::Session,
    backup_remote_file_name: &str,
) -> Result<(), ssh2::Error> {
    let remove_command = format!("/file remove \"{}\"", backup_remote_file_name);
    run_command_remotely(session, &remove_command)
}
