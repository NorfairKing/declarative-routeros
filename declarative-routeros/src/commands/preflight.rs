use std::path::{Path, PathBuf};
use std::process::exit;

use clap::Args;

use crate::report;
use crate::session::{
    combine_to_session_settings, connect, contents_of, SessionFlags, SessionSettings,
};

/// Asks the router that is going to run some files whether it can compile every
/// command in them, without running any of them.
#[derive(Debug, Clone, Args)]
pub struct PreflightFlags {
    #[command(flatten)]
    session: SessionFlags,
    #[arg(required = true)]
    script_files: Vec<PathBuf>,
}

/// Every file is asked about, so one refusal does not hide another.
pub fn command(flags: PreflightFlags) -> Result<(), ssh2::Error> {
    let session_settings = combine_to_session_settings(flags.session);
    let mut all_compile = true;
    for script_file in &flags.script_files {
        all_compile &= preflight(session_settings.clone(), script_file)?;
    }
    if all_compile {
        Ok(())
    } else {
        exit(1)
    }
}

/// `/import` compiles a whole file before it runs any of it, so one word the
/// router's RouterOS does not know means none of the file is applied.
/// A vm cannot answer for that when it runs another version, and an export only
/// knows the words the router already uses.
/// The router's own console highlighter can: it marks a parameter, value or
/// command its RouterOS does not have, and it runs nothing.
pub fn preflight(
    session_settings: SessionSettings,
    script_file: &Path,
) -> Result<bool, ssh2::Error> {
    let text = String::from_utf8_lossy(&contents_of(script_file)).into_owned();
    let lines = lines_in(&text);
    report::detail(&format!(
        "asking about {} line{} in {}",
        lines.len(),
        report::plural(lines.len()),
        script_file.display()
    ));
    let session = connect(session_settings)?;
    let mut section = String::new();
    let mut refused = 0;
    for line in &lines {
        let input = input_for(&section, &line.body);
        let tokens = highlight(&session, &input);
        match verdict(&tokens) {
            Verdict::Compiles => (),
            Verdict::Menu => section = section_after(&section, &line.body),
            Verdict::Error { byte } => {
                refused += 1;
                report::problem(&format!(
                    "{}:{}: the router does not know {}",
                    script_file.display(),
                    line.number,
                    word_at(&input, byte)
                ));
                report::detail(&input);
            }
            Verdict::NoCommand => {
                refused += 1;
                // Still the menu the lines below were written for, so they are
                // not refused again for being asked about in another one.
                if line.body.starts_with('/') {
                    section = section_after(&section, &line.body);
                }
                report::problem(&format!(
                    "{}:{}: the router has no such command",
                    script_file.display(),
                    line.number
                ));
                report::detail(&input);
            }
        }
    }
    if refused == 0 {
        report::good("the router can compile all of it");
        Ok(true)
    } else {
        report::detail(&format!(
            "The router would refuse all of {}, so nothing has been changed.",
            script_file.display()
        ));
        Ok(false)
    }
}

/// What the router reads as one line: a physical line, with the lines a
/// trailing backslash continues it onto, and with the rest of a block whose
/// braces it opens.
#[derive(Debug, PartialEq)]
struct Line {
    /// Of its first physical line, from one, as an editor counts them.
    number: usize,
    /// Continuations joined, the lines of a block kept apart by newlines.
    body: String,
}

// [check:tag ReadingOfAFile] Each reader of a configuration file splits it into
// what the router reads as one command.
// When one learns a shape of line, consider whether the others need it too.
fn lines_in(text: &str) -> Vec<Line> {
    let mut lines = Vec::new();
    let mut open: Option<Line> = None;
    for (index, raw) in text.lines().enumerate() {
        let piece = raw.trim();
        let skipped = piece.is_empty() || piece.starts_with('#');
        match open.as_mut() {
            None if skipped => continue,
            None => {
                open = Some(Line {
                    number: index + 1,
                    body: piece.to_string(),
                })
            }
            // RouterOS drops the indentation of a continued line, which is why
            // an export spells a space that starts one as `\_`.
            Some(line) if line.body.ends_with('\\') => {
                line.body.pop();
                line.body.push_str(piece);
            }
            Some(_) if skipped => continue,
            Some(line) => {
                line.body.push('\n');
                line.body.push_str(piece);
            }
        }
        if let Some(line) = open.take() {
            if line.body.ends_with('\\') || braces_open_in(&line.body) > 0 {
                open = Some(line);
            } else {
                lines.push(line);
            }
        }
    }
    // An unfinished last line is still asked about: the router says what is
    // wrong with it.
    lines.extend(open);
    lines
}

/// Braces inside a string do not open a block.
fn braces_open_in(body: &str) -> i64 {
    let mut depth = 0;
    let mut in_string = false;
    let mut escaped = false;
    for c in body.chars() {
        match c {
            _ if escaped => escaped = false,
            '\\' => escaped = true,
            '"' => in_string = !in_string,
            '{' if !in_string => depth += 1,
            '}' if !in_string => depth -= 1,
            _ => (),
        }
    }
    depth
}

/// The highlighter is asked about one line on its own, so a line in a menu
/// carries the menu with it.
/// A line naming its own menu, or a scripting command starting with a colon,
/// is asked about as it is.
fn input_for(section: &str, body: &str) -> String {
    if section.is_empty() || body.starts_with('/') || body.starts_with(':') {
        body.to_string()
    } else {
        format!("/{} {}", section, body)
    }
}

/// A line that is only a menu moves into it, like `cd` does: from the top when
/// it starts with a slash, and from the current menu otherwise.
fn section_after(section: &str, body: &str) -> String {
    match body.strip_prefix('/') {
        Some(path) => path.trim().to_string(),
        None if section.is_empty() => body.trim().to_string(),
        None => format!("{} {}", section, body.trim()),
    }
}

/// One token per byte of the input, naming what the router took that byte to
/// be.
fn highlight(session: &ssh2::Session, input: &str) -> Vec<String> {
    let asked = format!(
        ":put ([/console inspect request=highlight input={} as-value]->\"highlight\")",
        routeros_string(input)
    );
    let answer = match ask(session, &asked) {
        Ok(answer) => answer,
        Err(complaint) => report::fatal(
            "Could not ask the router whether it can compile the file.",
            &complaint,
        ),
    };
    let tokens: Vec<String> = answer.trim().split(';').map(str::to_string).collect();
    // Anything else is an answer to some other question, and reading a verdict
    // into it would let a file through that nobody has asked about.
    if tokens.len() != input.len() {
        report::fatal(
            "The router's answer does not describe the command it was asked about.",
            &format!(
                "{} tokens for {} bytes of: {}\nIt said: {}",
                tokens.len(),
                input.len(),
                input,
                answer.trim()
            ),
        );
    }
    tokens
}

fn ask(session: &ssh2::Session, command: &str) -> Result<String, String> {
    use std::io::Read;
    let mut channel = session
        .channel_session()
        .map_err(|complaint| format!("no channel: {}", complaint))?;
    channel
        .exec(command)
        .map_err(|complaint| format!("could not run it: {}", complaint))?;
    let mut answer = String::new();
    channel
        .read_to_string(&mut answer)
        .map_err(|complaint| format!("could not read the answer: {}", complaint))?;
    channel
        .wait_close()
        .map_err(|complaint| format!("the channel did not close: {}", complaint))?;
    match channel.exit_status() {
        Ok(0) => Ok(answer),
        Ok(status) => Err(format!("exit code {}: {}", status, answer.trim())),
        Err(complaint) => Err(format!("no exit status: {}", complaint)),
    }
}

#[derive(Debug, PartialEq)]
enum Verdict {
    Compiles,
    /// Only the name of a menu, which the router moves into.
    Menu,
    /// Where the first byte the router could not make sense of is.
    Error {
        byte: usize,
    },
    /// Nothing in it is a command: the highlighter reads a menu it does not
    /// have as the name of an object in the one above, not as an error.
    NoCommand,
}

fn verdict(tokens: &[String]) -> Verdict {
    if let Some(byte) = tokens.iter().position(|token| token == "error") {
        Verdict::Error { byte }
    } else if tokens.iter().any(|token| token == "cmd") {
        Verdict::Compiles
    } else if tokens.iter().any(|token| token == "dir")
        && tokens.iter().all(|token| token == "dir" || token == "none")
    {
        Verdict::Menu
    } else {
        Verdict::NoCommand
    }
}

/// The whole word around a byte, for a message that says what to look at.
fn word_at(input: &str, byte: usize) -> String {
    let bytes = input.as_bytes();
    let is_part = |b: u8| !b.is_ascii_whitespace();
    let mut start = byte.min(bytes.len());
    while start > 0 && is_part(bytes[start - 1]) {
        start -= 1;
    }
    let mut end = byte.min(bytes.len());
    while end < bytes.len() && is_part(bytes[end]) {
        end += 1;
    }
    String::from_utf8_lossy(&bytes[start..end]).into_owned()
}

/// A RouterOS string literal for any text, byte for byte, so that what the
/// router reads is exactly the command and nothing in it is substituted.
fn routeros_string(text: &str) -> String {
    let mut quoted = String::from("\"");
    for byte in text.bytes() {
        match byte {
            b'"' => quoted.push_str("\\\""),
            b'\\' => quoted.push_str("\\\\"),
            b'$' => quoted.push_str("\\$"),
            b'?' => quoted.push_str("\\?"),
            b' '..=b'~' => quoted.push(byte as char),
            _ => quoted.push_str(&format!("\\{:02X}", byte)),
        }
    }
    quoted.push('"');
    quoted
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tokens(names: &[&str]) -> Vec<String> {
        names.iter().map(|name| name.to_string()).collect()
    }

    fn line(number: usize, body: &str) -> Line {
        Line {
            number,
            body: body.to_string(),
        }
    }

    #[test]
    fn every_line_but_comments_and_blanks_is_asked_about() {
        let text = "# a comment\r\n/ip firewall nat\r\n\r\nadd chain=srcnat action=masquerade\r\n:delay 1s\r\n/tool netwatch add host=192.168.88.9\r\n";
        assert_eq!(
            lines_in(text),
            vec![
                line(2, "/ip firewall nat"),
                line(4, "add chain=srcnat action=masquerade"),
                line(5, ":delay 1s"),
                line(6, "/tool netwatch add host=192.168.88.9"),
            ]
        );
    }

    #[test]
    fn a_continued_line_is_one_line_without_its_indentation() {
        let text = "add comment=adguard down-script=\"/ip dhcp-server network set [find where addre\\\n    ss=\\\"192.168.88.0/24\\\"] dns-server=8.8.8.8; [find\\\n    \\_where comment=x]\"\n";
        assert_eq!(
            lines_in(text),
            vec![line(
                1,
                "add comment=adguard down-script=\"/ip dhcp-server network set [find where address=\\\"192.168.88.0/24\\\"] dns-server=8.8.8.8; [find\\_where comment=x]\""
            )]
        );
    }

    #[test]
    fn a_block_is_one_line_with_its_own_lines_kept_apart() {
        let text = ":if (true) do={\n  # inside\n  :put \"}\"\n\n  :put 1\n}\n:put 2\n";
        assert_eq!(
            lines_in(text),
            vec![
                line(1, ":if (true) do={\n:put \"}\"\n:put 1\n}"),
                line(7, ":put 2"),
            ]
        );
    }

    #[test]
    fn an_unfinished_last_line_is_still_asked_about() {
        assert_eq!(
            lines_in(":if (true) do={\n:put 1\n"),
            vec![line(1, ":if (true) do={\n:put 1")]
        );
    }

    #[test]
    fn a_line_in_a_menu_carries_the_menu() {
        assert_eq!(
            input_for("ip firewall nat", "add chain=srcnat"),
            "/ip firewall nat add chain=srcnat"
        );
    }

    #[test]
    fn a_line_naming_its_own_menu_is_asked_about_as_it_is() {
        assert_eq!(
            input_for("ip firewall nat", "/tool netwatch add type=dns"),
            "/tool netwatch add type=dns"
        );
        assert_eq!(input_for("ip firewall nat", ":delay 1s"), ":delay 1s");
        assert_eq!(input_for("", "add x=1"), "add x=1");
    }

    #[test]
    fn a_menu_with_a_slash_is_from_the_top() {
        assert_eq!(section_after("ip firewall nat", "/tool netwatch"), "tool netwatch");
    }

    #[test]
    fn a_menu_without_a_slash_is_from_the_current_one() {
        assert_eq!(section_after("ip firewall", "nat"), "ip firewall nat");
        assert_eq!(section_after("", "ip"), "ip");
    }

    #[test]
    fn only_the_name_of_a_menu_is_a_menu() {
        assert_eq!(
            verdict(&tokens(&["dir", "dir", "dir", "none", "dir", "dir"])),
            Verdict::Menu
        );
    }

    #[test]
    fn an_error_anywhere_is_where_it_stops() {
        assert_eq!(
            verdict(&tokens(&[
                "dir", "none", "cmd", "none", "arg", "error", "error"
            ])),
            Verdict::Error { byte: 5 }
        );
    }

    #[test]
    fn a_menu_the_router_does_not_have_has_no_command_in_it() {
        assert_eq!(
            verdict(&tokens(&["dir", "none", "obj-inactive", "none", "none"])),
            Verdict::NoCommand
        );
    }

    #[test]
    fn a_command_with_nothing_wrong_compiles() {
        assert_eq!(
            verdict(&tokens(&[
                "dir",
                "none",
                "cmd",
                "none",
                "arg",
                "syntax-meta",
                "none"
            ])),
            Verdict::Compiles
        );
    }

    #[test]
    fn the_word_around_an_error_is_the_whole_word() {
        let input = "/tool netwatch add type=dns dns-server=1.1.1.1";
        let byte = input.find("dns-server").unwrap() + 2;
        assert_eq!(word_at(input, byte), "dns-server=1.1.1.1");
    }

    #[test]
    fn strings_escape_what_routeros_would_otherwise_read() {
        assert_eq!(
            routeros_string(
                r#"up-script="/ip firewall nat enable [find where comment=\"x\"]" $v ?"#
            ),
            r#""up-script=\"/ip firewall nat enable [find where comment=\\\"x\\\"]\" \$v \?""#
        );
    }

    #[test]
    fn strings_spell_other_bytes_in_hex() {
        assert_eq!(routeros_string("a\tb\u{e9}"), "\"a\\09b\\C3\\A9\"");
    }
}
