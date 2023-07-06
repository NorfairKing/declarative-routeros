use ssh2::Session;
use std::env;
use std::fs::File;
use std::io::prelude::*;
use std::net::TcpStream;
use std::path::Path;

pub fn command_download() -> Result<(), ssh2::Error> {
    let session = connect()?;
    sftp_download_backup(&session);
    Ok(())
}

fn connect() -> Result<ssh2::Session, ssh2::Error> {
    // Connect to the local SSH server
    let tcp = TcpStream::connect("192.168.100.1:22").unwrap();
    let mut session = Session::new()?;
    session.set_tcp_stream(tcp);
    session.handshake()?;

    session.userauth_password(
        &env::var("ROUTEROS_SSH_USER").unwrap(),
        &env::var("ROUTEROS_SSH_PASSWORD").unwrap(),
    )?;
    Ok(session)
}

// Based on the example at https://docs.rs/ssh2/latest/ssh2/
fn sftp_download_backup(session: &ssh2::Session) {
    let backup_file_name = "declarative-routeros-backup.rsc";

    // Create the backup script export on the router side
    let mut channel = session.channel_session().unwrap();
    let export_command = format!("/export file=\"{}\"", backup_file_name);
    println!("Running remotely: {}", export_command);
    channel.exec(&export_command).unwrap();
    let mut s = String::new();
    channel.read_to_string(&mut s).unwrap();
    println!("Response: {}", s);
    channel.wait_close().unwrap();
    println!("{}", channel.exit_status().unwrap()); // TODO only print this if it failed.

    // Transfer the backup script to the local machine
    let remote_file_path = Path::new(backup_file_name);
    let (mut remote_file, stat) = session.scp_recv(remote_file_path).unwrap();
    println!("Fetching remote file: {}", remote_file_path.display());
    println!("remote file size: {}", stat.size());
    let mut contents = Vec::new();
    remote_file.read_to_end(&mut contents).unwrap();
    remote_file.send_eof().unwrap();
    remote_file.wait_eof().unwrap();
    remote_file.close().unwrap();
    remote_file.wait_close().unwrap();

    // Write the file locally
    let local_file_path = Path::new(backup_file_name);
    let mut f = File::create(local_file_path).unwrap();
    println!("Writing local file:: {}", local_file_path.display());
    f.write_all(contents.as_slice()).unwrap();

    // Delete the backup script on the router side
    let mut channel = session.channel_session().unwrap();
    let remove_command = format!("/file remove \"{}\"", backup_file_name);
    println!("Running remotely: {}", remove_command);
    channel.exec(&remove_command).unwrap();
    let mut s = String::new();
    channel.read_to_string(&mut s).unwrap();
    println!("Response after removing the remote backup file: {}", s);
    channel.wait_close().unwrap();
    println!("{}", channel.exit_status().unwrap()); // TODO only print this if it failed.
}