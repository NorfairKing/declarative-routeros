use std::fs;
use std::io::{stdin, stdout, Write};
use std::path::PathBuf;
use std::process::exit;

use crate::commands::{download, import, reset_into, settle, wait};
use crate::report;
use crate::session::{connect, contents_of, SessionSettings};

pub struct ApplySettings {
    pub name: String,
    pub prefix: PathBuf,
    pub rest: PathBuf,
    pub checked_against: PathBuf,
    pub record_into: PathBuf,
    pub asking: Asking,
}

pub enum Asking {
    Ask,
    AlreadyAnswered,
}

/// A missing file is not an empty one: reading it as empty would deploy half a
/// configuration and call it done.
enum Half {
    Missing,
    Empty,
    HasContent,
}

/// `/import` compiles a whole file before running any of it, so one RouterOS
/// cannot compile leaves a reset router with nothing. Hence two halves: the
/// reset is paired with the prefix, and the rest goes onto the router that came
/// up, where being refused costs a message.
pub fn command(
    session_settings: SessionSettings,
    apply_settings: ApplySettings,
) -> Result<(), ssh2::Error> {
    // A deployment that has already run cannot be told to run somewhere else.
    if !apply_settings.record_into.is_dir() {
        report::problem(&format!(
            "There is no {} here to record this in.",
            apply_settings.record_into.display()
        ));
        report::detail("Run this from the directory that holds it.");
        exit(1);
    }

    report::step(&format!(
        "applying {}'s configuration to {}@{}",
        apply_settings.name, session_settings.username, session_settings.router_address
    ));
    report::detail(&format!("prefix: {}", apply_settings.prefix.display()));
    report::detail(&format!("rest: {}", apply_settings.rest.display()));

    report::step("checking the router is the one the checks read");
    let live = {
        let session = connect(session_settings.clone())?;
        download::fetch_export(&session, "/export verbose")
            .unwrap_or_else(|complaint| report::fatal("Could not read the router.", &complaint))
    };
    // A router changed since the checks read it is one they answer nothing for.
    let checked = contents_of(&apply_settings.checked_against);
    if live != checked {
        report::problem(&format!("{} is not the router these checks read.", apply_settings.name));
        report::detail(&format!("Download it again: {} download", report::this_command()));
        report::detail("Then build this again.");
        exit(1);
    }
    report::good(&format!("matches {}", apply_settings.checked_against.display()));

    match apply_settings.asking {
        Asking::AlreadyAnswered => (),
        Asking::Ask => {
            if !confirmed(&apply_settings.name) {
                report::detail("Not applying it.");
                return Ok(());
            }
        }
    }

    report::step("resetting into the prefix");
    reset_into::command_with(
        session_settings.clone(),
        reset_into::reset_into_settings_for(&apply_settings.prefix),
    )?;

    report::step(&format!(
        "connecting to {} and running :put ready until it answers",
        session_settings.router_address
    ));
    wait::wait_for(session_settings.clone())?;

    match half_at(&apply_settings.rest) {
      Half::Missing => report::fatal(
          &format!("There is no {}.", apply_settings.rest.display()),
          "That is half of a configuration, and a deployment that skipped it would reset the router into the other half and call it done.",
      ),
      Half::Empty => {
        report::step("no rest to import");
      }
      Half::HasContent => {
        report::step("importing the rest");
        if !import::import_onto(
            session_settings.clone(),
            import::import_settings_for(&apply_settings.rest),
        )? {
            report::detail(&format!("{} has the prefix and not the rest.", apply_settings.name));
            report::detail(&format!("Finish it with: {} import-rest", report::this_command()));
            exit(1);
        }
      }
    }

    // Reading it back sooner records a router half way through coming up.
    report::step("reading /export until it has no error comments");
    settle::settle_for(session_settings.clone())?;

    report::step(&format!("recording into {}", apply_settings.record_into.display()));
    download::command_with(
        session_settings,
        download::download_into(&apply_settings.record_into),
    )?;
    report::good("recorded");
    Ok(())
}

fn half_at(path: &PathBuf) -> Half {
    match fs::metadata(path) {
        Err(_) => Half::Missing,
        Ok(file) if file.len() == 0 => Half::Empty,
        Ok(_) => Half::HasContent,
    }
}

fn confirmed(name: &str) -> bool {
    print!("Apply it to {}? [y/N] ", name);
    stdout().flush().unwrap();
    let mut answer = String::new();
    if stdin().read_line(&mut answer).is_err() {
        return false;
    }
    matches!(answer.trim().to_lowercase().as_str(), "y" | "yes")
}
