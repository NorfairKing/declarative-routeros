use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::exit;
use std::time::{SystemTime, UNIX_EPOCH};

use clap::Args;


use crate::report;
use crate::session::{combine_to_session_settings, connect, contents_of, try_capture_command_remotely, upload, SessionFlags, SessionSettings};

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
/// continued with a backslash, and ends its lines the way the file's last line
/// break does, so a file written with CRLF throughout stays that way.
fn with_marker(contents: &[u8], marker: &str) -> Vec<u8> {
    let ending: &[u8] = if contents
        .iter()
        .rposition(|byte| *byte == b'\n')
        .is_some_and(|newline| contents[..newline].ends_with(b"\r"))
    {
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

#[derive(Debug, PartialEq, Eq)]
enum Verdict {
    RanAll,
    /// The marker printed, so every line ran, whatever the exit status says:
    /// RouterOS's exit status for an import over ssh varies between runs of
    /// the same file.
    RanAllButExitedWith(i32),
    DidNotRunAll,
}

/// Each stream on its own: one that does not end in a line break would
/// otherwise run into the first line of the other.
fn verdict(stdout: &[u8], stderr: &[u8], exit_status: i32, marker: &str) -> Verdict {
    let printed = [stdout, stderr].iter().any(|stream| {
        String::from_utf8_lossy(stream)
            .lines()
            .any(|line| line.trim() == marker)
    });
    match (printed, exit_status) {
        (true, 0) => Verdict::RanAll,
        (true, status) => Verdict::RanAllButExitedWith(status),
        (false, _) => Verdict::DidNotRunAll,
    }
}

/// The router says nothing it can be held to about an import run over ssh: it
/// exits 0 for a file it would not compile and applied none of.
/// So the verdict is whether the marker the file ends with was printed.
fn import(
    session: &ssh2::Session,
    remote_filename: &Path,
    marker: &str,
) -> Result<bool, ssh2::Error> {
    let import_command = format!("/import file={}", remote_filename.display());
    report::detail(&format!("running: {}", import_command));

    let mut channel = session.channel_session()?;
    channel.exec(&import_command)?;
    let mut stdout = Vec::new();
    let mut stderr = Vec::new();
    // Which stream RouterOS uses is not worth finding out the hard way.
    if let Err(complaint) = channel.read_to_end(&mut stdout) {
        report::warn(&format!("Could not read the router's stdout: {}", complaint));
    }
    if let Err(complaint) = channel.stderr().read_to_end(&mut stderr) {
        report::warn(&format!("Could not read the router's stderr: {}", complaint));
    }
    channel.wait_close()?;
    let exit_status = channel.exit_status()?;

    for stream in [&stdout, &stderr] {
        for line in String::from_utf8_lossy(stream)
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty() && *line != marker)
        {
            report::detail(line);
        }
    }

    remove_upload(session, remote_filename);

    match verdict(&stdout, &stderr, exit_status, marker) {
        Verdict::RanAll => Ok(true),
        Verdict::RanAllButExitedWith(status) => {
            report::warn(&format!(
                "The router ran all of the file, but its exit code was {}.",
                status
            ));
            report::detail("It printed the line at the end of the file, which it only gets to after running every line above it.");
            Ok(true)
        }
        Verdict::DidNotRunAll => {
            report::problem("The router did not run all of the file.");
            report::detail(&format!("Its exit code was {}.", exit_status));
            report::detail("An import stops at the line that fails and keeps everything above it, so how much was applied is not something this can tell you.");
            report::detail("Read the router before running this again.");
            Ok(false)
        }
    }
}

/// A warning rather than a failure: whether the import ran is already decided,
/// and a copy left on the router changes nothing it does.
fn remove_upload(session: &ssh2::Session, remote_filename: &Path) {
    // Matched by name rather than passed as one: `remove` takes ids, and a
    // find that matches nothing removes nothing instead of failing.
    let remove_command = format!(
        "/file remove [find name=\"{}\"]",
        remote_filename.display()
    );
    if let Err(complaint) = try_capture_command_remotely(session, &remove_command) {
        report::warn(&format!(
            "Could not remove {} from the router: {}",
            remote_filename.display(),
            complaint
        ));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_marker_is_printed_as_it_is_inside_a_quoted_routeros_string() {
        assert!(marker().chars().all(|character| {
            character.is_ascii_alphanumeric() || character == ' ' || character == '-'
        }));
    }

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
    fn the_marker_ends_its_lines_like_a_crlf_file() {
        assert_eq!(
            with_marker(b"/system identity\r\nset name=a\r\n", "m"),
            b"/system identity\r\nset name=a\r\n\r\n\r\n:put \"m\"\r\n".to_vec()
        );
    }

    #[test]
    fn the_marker_ends_its_lines_like_the_files_last_line_break() {
        assert_eq!(
            with_marker(b"a\r\nb\n", "m"),
            b"a\r\nb\n\n\n:put \"m\"\n".to_vec()
        );
    }

    #[test]
    fn the_marker_ends_its_lines_with_lf_in_a_file_without_line_breaks() {
        assert_eq!(
            with_marker(b"/system identity set name=a", "m"),
            b"/system identity set name=a\n\n:put \"m\"\n".to_vec()
        );
    }

    #[test]
    fn a_file_that_printed_the_marker_and_exited_0_ran_all_of_it() {
        assert_eq!(
            verdict(
                b"Script file loaded and executed successfully\r\nm\r\n",
                b"",
                0,
                "m"
            ),
            Verdict::RanAll
        );
    }

    #[test]
    fn a_file_that_printed_the_marker_ran_all_of_it_whatever_the_exit_status() {
        assert_eq!(
            verdict(
                b"Script file loaded and executed successfully\r\nm\r\n",
                b"",
                1,
                "m"
            ),
            Verdict::RanAllButExitedWith(1)
        );
    }

    #[test]
    fn a_refused_file_did_not_run_all_of_it_though_it_exited_0() {
        assert_eq!(
            verdict(
                b"Script Error: expected end of command (line 2 column 51) (:import; line 1)\r\n",
                b"",
                0,
                "m"
            ),
            Verdict::DidNotRunAll
        );
    }

    #[test]
    fn a_line_mentioning_the_marker_is_not_the_marker() {
        assert_eq!(
            verdict(b"the marker is m, said the file\r\n", b"", 0, "m"),
            Verdict::DidNotRunAll
        );
    }

    #[test]
    fn the_marker_on_stderr_counts() {
        assert_eq!(verdict(b"", b"m\r\n", 0, "m"), Verdict::RanAll);
    }

    #[test]
    fn the_marker_at_the_end_of_stdout_does_not_run_into_stderr() {
        assert_eq!(
            verdict(b"loaded\r\nm", b"warning\r\n", 0, "m"),
            Verdict::RanAll
        );
    }

    #[test]
    fn a_stream_that_is_not_utf8_still_shows_the_marker() {
        assert_eq!(
            verdict(b"\xff\xfe set name=\xe9\r\nm\r\n", b"", 0, "m"),
            Verdict::RanAll
        );
    }
}
