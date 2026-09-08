use std::io::prelude::*;
use std::path::Path;
use std::{fs::File, path::PathBuf};

use clap::Args;
use serde_json::json;
use tracing::{debug, error, info};

use crate::report;
use crate::session::{capture_command_remotely, combine_to_session_settings, connect, SessionFlags, SessionSettings};

#[derive(Debug, Clone, Args)]
pub struct DownloadFlags {
    #[command(flatten)]
    session: SessionFlags,
    /// Write all three into this directory, under the names a check looks for
    #[arg(long)]
    into: PathBuf,
}

pub struct DownloadSettings {
    output_file: PathBuf,
    verbose_output_file: PathBuf,
    chassis_file: PathBuf,
}

pub fn download_into(directory: &Path) -> DownloadSettings {
    DownloadSettings {
        output_file: directory.join("export.rsc"),
        verbose_output_file: directory.join("export-verbose.rsc"),
        chassis_file: directory.join("chassis.json"),
    }
}

pub fn command(flags: DownloadFlags) -> Result<(), ssh2::Error> {
    let session = connect(combine_to_session_settings(flags.session))?;
    download(download_into(&flags.into), &session)
}

pub fn command_with(
    session_settings: SessionSettings,
    download_settings: DownloadSettings,
) -> Result<(), ssh2::Error> {
    let session = connect(session_settings)?;
    download(download_settings, &session)
}

fn download(settings: DownloadSettings, session: &ssh2::Session) -> Result<(), ssh2::Error> {
    download_export(session, "/export", &settings.output_file);
    // A parameter printed at its default is one this router knows the name of,
    // which is what tells an unknown name from an unused one.
    download_export(session, "/export verbose", &settings.verbose_output_file);
    download_chassis(session, &settings.chassis_file)
}

fn download_export(session: &ssh2::Session, export_command: &str, local_file_path: &Path) {
    let contents = fetch_export(session, export_command)
        .unwrap_or_else(|complaint| report::fatal("Could not read the export.", &complaint));
    write_file_locally(local_file_path, &contents);
}

pub fn fetch_export(session: &ssh2::Session, export_command: &str) -> Result<Vec<u8>, String> {
    let remote_file_name = "declarative-routeros-read.rsc";
    create_export_remotely(session, export_command, remote_file_name)
        .map_err(|complaint| format!("could not run {}: {}", export_command, complaint))?;
    let contents = transfer_export_to_local(session, remote_file_name)?;
    delete_export_remotely(session, remote_file_name)
        .map_err(|complaint| format!("could not tidy up {}: {}", remote_file_name, complaint))?;
    Ok(strip_export_header(&contents).to_vec())
}

fn create_export_remotely(
    session: &ssh2::Session,
    export_command: &str,
    remote_file_name: &str,
) -> Result<(), ssh2::Error> {
    let command = format!("{} file=\"{}\"", export_command, remote_file_name);
    capture_command_remotely(session, &command).map(|_| ())
}

/// Fallible rather than fatal: a router that has just been reset drops
/// connections, and that is an answer.
fn transfer_export_to_local(
    session: &ssh2::Session,
    remote_file_name: &str,
) -> Result<Vec<u8>, String> {
    let remote_file_path = Path::new(remote_file_name);
    let (mut remote_file, stat) = session
        .scp_recv(remote_file_path)
        .map_err(|complaint| format!("could not fetch {}: {}", remote_file_name, complaint))?;
    info!("Fetching remote file: {}", remote_file_path.display());
    debug!("Remote file size: {}", stat.size());
    let mut contents = Vec::new();
    remote_file
        .read_to_end(&mut contents)
        .map_err(|complaint| format!("could not read {}: {}", remote_file_name, complaint))?;
    for step in [
        remote_file.send_eof(),
        remote_file.wait_eof(),
        remote_file.close(),
        remote_file.wait_close(),
    ] {
        step.map_err(|complaint| format!("could not finish reading {}: {}", remote_file_name, complaint))?;
    }
    Ok(contents)
}

fn write_file_locally(local_file_path: &Path, contents: &[u8]) {
    info!("Writing local file: {}", local_file_path.display());
    File::create(local_file_path)
        .and_then(|mut file| file.write_all(contents))
        .unwrap_or_else(|complaint| {
            report::fatal(
                &format!("Could not write {}.", local_file_path.display()),
                &complaint.to_string(),
            )
        });
}

fn delete_export_remotely(
    session: &ssh2::Session,
    remote_file_name: &str,
) -> Result<(), ssh2::Error> {
    // Matched by name rather than passed as one: `remove` takes ids, and a
    // find that matches nothing removes nothing instead of failing.
    let remove_command = format!("/file remove [find name=\"{}\"]", remote_file_name);
    capture_command_remotely(session, &remove_command).map(|_| ())
}

/// The block RouterOS puts at the top carries the time, which makes every
/// download a diff, and the serial number and software id, which have no
/// business in a committed file. Later comments stay.
fn strip_export_header(contents: &[u8]) -> &[u8] {
    let mut offset = 0;
    for line in contents.split_inclusive(|byte| *byte == b'\n') {
        let body = trim_ascii(line);
        if !(body.is_empty() || body.starts_with(b"#")) {
            break;
        }
        offset += line.len();
    }
    &contents[offset..]
}

fn trim_ascii(bytes: &[u8]) -> &[u8] {
    let mut body = bytes;
    while let [first, rest @ ..] = body {
        if first.is_ascii_whitespace() {
            body = rest;
        } else {
            break;
        }
    }
    while let [rest @ .., last] = body {
        if last.is_ascii_whitespace() {
            body = rest;
        } else {
            break;
        }
    }
    body
}

/// Asked of the router rather than inferred from the file it is meant to check.
fn download_chassis(session: &ssh2::Session, chassis_file: &Path) -> Result<(), ssh2::Error> {
    // `default-name`, so a renamed interface still reports what the hardware
    // calls it, in the order a vm has to rename them in.
    let interfaces = capture_command_remotely(
        session,
        ":foreach i in=[/interface ethernet find] do={:put [/interface ethernet get $i default-name]}",
    )?;
    let serial_ports = capture_command_remotely(session, ":put [:len [/port find]]")?;
    let board_name = capture_command_remotely(session, ":put [/system resource get board-name]")?;
    let architecture_name =
        capture_command_remotely(session, ":put [/system resource get architecture-name]")?;
    let version = capture_command_remotely(session, ":put [/system resource get version]")?;

    let interfaces = parse_interfaces(&interfaces);
    let serial_ports = match parse_serial_ports(&serial_ports) {
        Ok(count) => count,
        Err(complaint) => {
            error!(
                "Could not read how many serial ports this router has: {}",
                complaint
            );
            return Ok(());
        }
    };

    let chassis = json!({
        "boardName": parse_word(&board_name),
        "architectureName": parse_word(&architecture_name),
        "version": parse_word(&version),
        "interfaces": interfaces,
        "serialPorts": serial_ports,
    });
    let mut written = serde_json::to_string_pretty(&chassis)
        .unwrap_or_else(|complaint| report::fatal("Could not write the chassis.", &complaint.to_string()));
    written.push('\n');
    write_file_locally(chassis_file, written.as_bytes());
    Ok(())
}

fn parse_interfaces(output: &str) -> Vec<String> {
    output
        .lines()
        .map(|line| line.trim())
        .filter(|line| !line.is_empty())
        .map(|line| line.to_string())
        .collect()
}

fn parse_serial_ports(output: &str) -> Result<usize, String> {
    let trimmed = output.trim();
    trimmed
        .parse()
        .map_err(|_| format!("expected a number, got {:?}", trimmed))
}

/// The first word: RouterOS puts the release channel after a version.
fn parse_word(output: &str) -> &str {
    output.split_whitespace().next().unwrap_or("")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_interfaces_in_the_order_the_router_gave_them() {
        let output = "ether1\r\nsfp-sfpplus1\r\nsfp-sfpplus2\r\nsfp28-1\r\n";
        assert_eq!(
            parse_interfaces(output),
            vec!["ether1", "sfp-sfpplus1", "sfp-sfpplus2", "sfp28-1"]
        );
    }

    #[test]
    fn ignores_the_blank_lines_routeros_pads_with() {
        assert_eq!(
            parse_interfaces("\r\nether1\r\n\r\nether2\r\n\r\n"),
            vec!["ether1", "ether2"]
        );
    }

    #[test]
    fn a_router_with_no_ethernet_has_no_interfaces() {
        assert_eq!(parse_interfaces(""), Vec::<String>::new());
    }

    #[test]
    fn reads_the_serial_port_count() {
        assert_eq!(parse_serial_ports("1\r\n"), Ok(1));
        assert_eq!(parse_serial_ports("  2  "), Ok(2));
    }

    #[test]
    fn refuses_to_guess_when_the_router_said_something_else() {
        assert!(parse_serial_ports("bad command name port (line 1 column 12)").is_err());
        assert!(parse_serial_ports("").is_err());
    }

    #[test]
    fn reads_a_version_without_its_channel() {
        assert_eq!(parse_word("7.11beta4 (testing)\r\n"), "7.11beta4");
        assert_eq!(parse_word("7.21\r\n"), "7.21");
        assert_eq!(parse_word("arm64\r\n"), "arm64");
        assert_eq!(parse_word("CCR2004-1G-12S+2XS\r\n"), "CCR2004-1G-12S+2XS");
    }

    #[test]
    fn strips_the_header_an_export_begins_with() {
        let export = b"# 2026-09-07 11:15:49 by RouterOS 7.11beta4\r\n\
                       # software id = XXXX-XXXX\r\n\
                       #\r\n\
                       # model = CCR2004-1G-12S+2XS\r\n\
                       # serial number = XXXXXXXXXXX\r\n\
                       #\r\n\
                       /interface bridge\r\n\
                       add name=lan\r\n";
        assert_eq!(
            strip_export_header(export),
            b"/interface bridge\r\nadd name=lan\r\n"
        );
    }

    #[test]
    fn keeps_the_comments_an_export_writes_about_the_configuration() {
        let export = b"# 2026-09-07 11:15:49 by RouterOS 7.11beta4\r\n\
                       /ip firewall filter\r\n\
                       # in/out-interface matcher not possible\r\n\
                       add action=accept chain=input\r\n";
        assert_eq!(
            strip_export_header(export),
            b"/ip firewall filter\r\n# in/out-interface matcher not possible\r\n\
              add action=accept chain=input\r\n"
        );
    }

    #[test]
    fn leaves_a_headerless_export_alone() {
        assert_eq!(
            strip_export_header(b"/port\r\nset 0 name=serial0\r\n"),
            b"/port\r\nset 0 name=serial0\r\n"
        );
        assert_eq!(strip_export_header(b""), b"");
    }
}
