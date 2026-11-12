use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::exit;
use std::time::{SystemTime, UNIX_EPOCH};

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
    let marker = marker();
    upload(
        &session,
        remote_filename,
        &with_marker(&contents_of(&import_settings.script_file), &marker),
    )?;
    import(&session, remote_filename, &marker)
}

/// Unique to this import, so that nothing the file prints and no earlier import
/// can be mistaken for it.
fn marker() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|since| since.as_nanos())
        .unwrap_or_default();
    format!(
        "declarative-routeros imported all of it {}-{}",
        std::process::id(),
        nanos
    )
}

/// A last line that prints the marker, which the router only gets to by
/// running every line above it.
/// It starts on a line of its own, even after a file that ends in a line
/// continued with a backslash, and uses the file's own line endings, since
/// RouterOS reads a file that mixes them differently.
fn with_marker(contents: &[u8], marker: &str) -> Vec<u8> {
    let ending: &[u8] = if contents.windows(2).any(|pair| pair == b"\r\n") {
        b"\r\n"
    } else {
        b"\n"
    };
    let mut marked = contents.to_vec();
    marked.extend_from_slice(ending);
    marked.extend_from_slice(ending);
    marked.extend_from_slice(format!(":put \"{}\"", marker).as_bytes());
    marked.extend_from_slice(ending);
    marked
}

/// The router says nothing it can be held to about an import run over ssh: it
/// exits 0 for a file it would not compile and applied none of.
/// So the verdict is whether the marker the file ends with was printed, and a
/// nonzero exit status counts against it too.
fn import(
    session: &ssh2::Session,
    remote_filename: &Path,
    marker: &str,
) -> Result<bool, ssh2::Error> {
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

    for line in response
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && *line != marker)
    {
        report::detail(line);
    }

    if exit_status == 0 && ran_to_the_end(&response, marker) {
        Ok(true)
    } else {
        report::problem("The router did not run all of the file.");
        report::detail(&format!("Its exit code was {}.", exit_status));
        report::detail("An import stops at the line that fails and keeps everything above it, so how much was applied is not something this can tell you.");
        report::detail("Read the router before running this again.");
        Ok(false)
    }
}

fn ran_to_the_end(response: &str, marker: &str) -> bool {
    response.lines().any(|line| line.trim() == marker)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_marker_comes_last_on_a_line_of_its_own() {
        assert_eq!(
            with_marker(b"/system identity\nset name=a\n", "m"),
            b"/system identity\nset name=a\n\n\n:put \"m\"\n".to_vec()
        );
    }

    #[test]
    fn the_marker_is_not_continued_onto_a_line_that_ends_in_a_backslash() {
        assert_eq!(
            with_marker(b"/system identity\nset name=\\", "m"),
            b"/system identity\nset name=\\\n\n:put \"m\"\n".to_vec()
        );
    }

    #[test]
    fn the_marker_uses_the_files_own_line_endings() {
        assert_eq!(
            with_marker(b"/system identity\r\nset name=a\r\n", "m"),
            b"/system identity\r\nset name=a\r\n\r\n\r\n:put \"m\"\r\n".to_vec()
        );
    }

    #[test]
    fn a_file_that_printed_the_marker_ran_to_the_end() {
        assert!(ran_to_the_end(
            "Script file loaded and executed successfully\r\nm\r\n",
            "m"
        ));
    }

    #[test]
    fn a_refused_file_did_not_run_to_the_end() {
        assert!(!ran_to_the_end(
            "Script Error: expected end of command (line 2 column 51) (:import; line 1)\r\n",
            "m"
        ));
    }

    #[test]
    fn a_line_mentioning_the_marker_is_not_the_marker() {
        assert!(!ran_to_the_end("the marker is m, said the file\r\n", "m"));
    }
}
