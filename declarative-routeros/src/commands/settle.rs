use std::thread::sleep;
use std::time::Duration;

use clap::Args;

use crate::commands::download::fetch_export;
use crate::report;
use crate::session::{combine_to_session_settings, try_connect, SessionFlags, SessionSettings};

#[derive(Debug, Clone, Args)]
pub struct SettleFlags {
    #[command(flatten)]
    session: SessionFlags,
}

/// RouterOS writes a comment into its own export for every part of the
/// configuration it cannot resolve yet, which asks the question without knowing
/// which parts wait on something arriving over the wire. No deadline, as in
/// `wait`.
pub fn command(flags: SettleFlags) -> Result<(), ssh2::Error> {
    settle_for(combine_to_session_settings(flags.session))
}

pub fn settle_for(session_settings: SessionSettings) -> Result<(), ssh2::Error> {
    let mut attempts = 1;
    loop {
        match unresolved(&session_settings) {
            Ok(complaints) if complaints.is_empty() => {
                report::good(&format!(
                    "no error comments, after {} read{}",
                    attempts,
                    report::plural(attempts)
                ));
                return Ok(());
            }
            Ok(complaints) => {
                for complaint in &complaints {
                    report::detail(&format!("attempt {}: {}", attempts, complaint));
                }
            }
            // A failed read is one of the ways of not having settled.
            Err(complaint) => report::detail(&format!("attempt {}: {}", attempts, complaint)),
        }
        attempts += 1;
        sleep(Duration::from_secs(5));
    }
}

/// A connection per attempt: one held across the wait goes away in the middle.
fn unresolved(settings: &SessionSettings) -> Result<Vec<String>, String> {
    let session = try_connect(settings)?;
    Ok(complaints_in(&fetch_export(&session, "/export")?))
}

/// A menu RouterOS could not print is not configuration that has not resolved:
/// a CHR says this about the routerboard on every export it will ever produce,
/// and waiting for it to stop is waiting forever.
fn complaints_in(export: &[u8]) -> Vec<String> {
    String::from_utf8_lossy(export)
        .lines()
        .map(|line| line.trim())
        .filter(|line| line.starts_with('#') && line.to_lowercase().contains("error"))
        .filter(|line| !line.starts_with("#error exporting"))
        .map(|line| line.to_string())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_pool_that_has_not_arrived_is_a_complaint() {
        let export = b"/ipv6 address\r\n\
                       # address pool error: pool not found: v6pool (4)\r\n\
                       add address=::1 from-pool=v6pool interface=lan\r\n";
        assert_eq!(
            complaints_in(export),
            vec!["# address pool error: pool not found: v6pool (4)"]
        );
    }

    #[test]
    fn the_comments_routeros_writes_about_working_configuration_are_not() {
        let export = b"/ip firewall filter\r\n\
                       # in/out-interface matcher not possible when interface (ether1) is slave - use master instead (lan)\r\n\
                       add action=accept chain=input in-interface=ether1\r\n";
        assert_eq!(complaints_in(export), Vec::<String>::new());
    }

    #[test]
    fn a_menu_the_hardware_does_not_have_is_not_a_complaint() {
        let export = b"# 2026-09-08 10:00:00 by RouterOS 7.21\r\n\
                       #error exporting \"/system/routerboard/mode-button\"\r\n\
                       #error exporting \"/system/routerboard/reset-button\"\r\n\
                       #error exporting \"/system/routerboard/wps-button\"\r\n\
                       /port\r\n\
                       set 0 name=serial0\r\n";
        assert_eq!(complaints_in(export), Vec::<String>::new());
    }

    #[test]
    fn a_settled_router_has_nothing_to_say() {
        assert_eq!(
            complaints_in(b"/port\r\nset 0 name=serial0\r\n"),
            Vec::<String>::new()
        );
    }
}
