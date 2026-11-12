use std::thread::sleep;
use std::time::{Duration, Instant};

use clap::Args;

use crate::report;
use crate::session::{combine_to_session_settings, try_capture_command_remotely, try_probe, SessionFlags, SessionSettings};

#[derive(Debug, Clone, Args)]
pub struct WaitFlags {
    #[command(flatten)]
    session: SessionFlags,
}

/// RouterOS listens well before it will authenticate, so a port that answers
/// promises nothing. No deadline: one that fires half way through a deployment
/// is worse than waiting.
pub fn command(flags: WaitFlags) -> Result<(), ssh2::Error> {
    wait_for(combine_to_session_settings(flags.session))
}

pub fn wait_for(session_settings: SessionSettings) -> Result<(), ssh2::Error> {
    let mut attempts = 1;
    loop {
        match answers(&session_settings) {
            Ok(()) => {
                report::good(&format!("answered after {} attempt{}", attempts, report::plural(attempts)));
                return Ok(());
            }
            Err(complaint) => {
                // One that prints once looks like one that has hung.
                report::detail(&format!("attempt {}: {}", attempts, complaint));
                attempts += 1;
                sleep(Duration::from_secs(2));
            }
        }
    }
}

/// A router told to reset goes on answering, on the configuration it is about
/// to throw away, for a moment that can outlast a whole import, so one that
/// answers may not have reset yet.
/// Nor does seeing it go down work: a connection attempt can last through the
/// whole reboot.
/// What does is its uptime, which a router that has not rebooted has had for
/// at least as long as it had before plus the time since.
/// A router that never resets, because it refused to or never got the
/// command, would otherwise be waited for forever, so there is a deadline, far
/// longer than a reboot takes even in an emulated vm.
pub fn wait_for_reset(
    session_settings: &SessionSettings,
    uptime_before: Duration,
    asked_at: Instant,
) {
    let mut attempts = 1;
    loop {
        // Measured to before the probe opens rather than to its answer, which
        // the router gives later, so that the time the probe takes can only
        // make a router that has rebooted look as if it has not.
        let since = asked_at.elapsed();
        let reset = uptime(session_settings).and_then(|uptime| {
            if has_rebooted(uptime_before, since, uptime) {
                Ok(())
            } else {
                Err(format!(
                    "up for {}, so it has not reset yet",
                    written_uptime(uptime)
                ))
            }
        });
        match reset {
            Ok(()) => {
                report::good(&format!(
                    "reset, after {} attempt{}",
                    attempts,
                    report::plural(attempts)
                ));
                return;
            }
            Err(complaint) if asked_at.elapsed() > RESET_DEADLINE => report::fatal(
                "The router has not reset.",
                &format!(
                    "It had not rebooted {} minutes after it was told to reset: {}\nIt may still be on its old configuration, or reset later: look at it before deploying again.",
                    RESET_DEADLINE.as_secs() / 60,
                    complaint
                ),
            ),
            Err(complaint) => {
                report::detail(&format!("attempt {}: {}", attempts, complaint));
                attempts += 1;
                sleep(Duration::from_secs(2));
            }
        }
    }
}

const RESET_DEADLINE: Duration = Duration::from_secs(15 * 60);

/// Whether a router that was up for `uptime_before` when it was told to reset
/// has rebooted, given `since`, the time from then until the uptime it now
/// reports was asked for, which the router reads after that.
/// A router shows whole seconds of uptime, so one that has not rebooted may
/// show up to a second less than it has had; the slack is more than that.
fn has_rebooted(uptime_before: Duration, since: Duration, uptime_now: Duration) -> bool {
    uptime_now + Duration::from_secs(2) < uptime_before + since
}

pub fn uptime(settings: &SessionSettings) -> Result<Duration, String> {
    let session = try_probe(settings)?;
    uptime_over(&session)
}

pub fn uptime_over(session: &ssh2::Session) -> Result<Duration, String> {
    let answer = try_capture_command_remotely(session, ":put [/system resource get uptime]")?;
    parse_uptime(answer.trim()).ok_or_else(|| format!("an uptime of {:?}", answer.trim()))
}

/// RouterOS writes a duration as weeks and days, then hours, minutes and
/// seconds: `1w2d03:04:05`, `00:00:34`.
fn parse_uptime(text: &str) -> Option<Duration> {
    let mut seconds: u64 = 0;
    let mut rest = text;
    for (unit, length) in [('w', 7 * 24 * 3600), ('d', 24 * 3600)] {
        if let Some((count, after)) = rest.split_once(unit) {
            seconds += count.parse::<u64>().ok()? * length;
            rest = after;
        }
    }
    let parts: Vec<u64> = rest
        .split(':')
        .map(|part| part.parse::<u64>().ok())
        .collect::<Option<_>>()?;
    match parts.as_slice() {
        [hours, minutes, secs] => Some(Duration::from_secs(
            seconds + hours * 3600 + minutes * 60 + secs,
        )),
        _ => None,
    }
}

/// As RouterOS writes it, leaving out weeks and days it does not have.
fn written_uptime(uptime: Duration) -> String {
    let seconds = uptime.as_secs();
    let weeks = seconds / (7 * 24 * 3600);
    let days = seconds / (24 * 3600) % 7;
    let clock = format!(
        "{:02}:{:02}:{:02}",
        seconds / 3600 % 24,
        seconds / 60 % 60,
        seconds % 60
    );
    match (weeks, days) {
        (0, 0) => clock,
        (0, days) => format!("{}d{}", days, clock),
        (weeks, 0) => format!("{}w{}", weeks, clock),
        (weeks, days) => format!("{}w{}d{}", weeks, days, clock),
    }
}

fn answers(settings: &SessionSettings) -> Result<(), String> {
    let session = try_probe(settings)?;
    let response = try_capture_command_remotely(&session, ":put ready").map_err(|complaint| {
        format!(
            "the router took the connection but not a command: {}",
            complaint
        )
    })?;
    if response.trim() == "ready" {
        Ok(())
    } else {
        Err(format!(
            "the router said {:?} rather than ready",
            response.trim()
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_an_uptime_of_seconds() {
        assert_eq!(parse_uptime("00:00:34"), Some(Duration::from_secs(34)));
    }

    #[test]
    fn reads_an_uptime_of_weeks_and_days() {
        assert_eq!(
            parse_uptime("1w2d03:04:05"),
            Some(Duration::from_secs(9 * 24 * 3600 + 3 * 3600 + 4 * 60 + 5))
        );
        assert_eq!(
            parse_uptime("3d00:00:01"),
            Some(Duration::from_secs(3 * 24 * 3600 + 1))
        );
    }

    #[test]
    fn refuses_what_is_not_an_uptime() {
        assert_eq!(parse_uptime("ready"), None);
        assert_eq!(parse_uptime(""), None);
        assert_eq!(parse_uptime("00:34"), None);
    }

    #[test]
    fn a_router_up_for_all_that_time_has_not_rebooted() {
        let before = Duration::from_secs(30);
        let since = Duration::from_secs(10);
        assert!(!has_rebooted(before, since, Duration::from_secs(40)));
        assert!(!has_rebooted(before, since, Duration::from_secs(39)));
    }

    #[test]
    fn a_router_up_for_less_than_that_has_rebooted() {
        assert!(has_rebooted(
            Duration::from_secs(30),
            Duration::from_secs(40),
            Duration::from_secs(15)
        ));
    }

    #[test]
    fn a_router_that_did_not_reboot_is_never_said_to_have() {
        // The router reads its uptime some time before it is told to reset,
        // and again some time after the probe is opened, and shows whole
        // seconds of it.
        fn did_not_reboot(
            before_millis: u32,
            until_asked_millis: u16,
            since_millis: u32,
            until_read_millis: u16,
        ) -> bool {
            let now_millis = u64::from(before_millis)
                + u64::from(until_asked_millis)
                + u64::from(since_millis)
                + u64::from(until_read_millis);
            !has_rebooted(
                Duration::from_secs(u64::from(before_millis) / 1000),
                Duration::from_millis(u64::from(since_millis)),
                Duration::from_secs(now_millis / 1000),
            )
        }
        quickcheck::quickcheck(did_not_reboot as fn(u32, u16, u32, u16) -> bool);
    }

    #[test]
    fn an_uptime_reads_back_as_written() {
        fn reads_back(seconds: u32) -> bool {
            let uptime = Duration::from_secs(u64::from(seconds));
            parse_uptime(&written_uptime(uptime)) == Some(uptime)
        }
        quickcheck::quickcheck(reads_back as fn(u32) -> bool);
    }

    #[test]
    fn an_uptime_is_written_as_routeros_writes_it() {
        assert_eq!(written_uptime(Duration::from_secs(34)), "00:00:34");
        assert_eq!(
            written_uptime(Duration::from_secs(9 * 24 * 3600 + 3 * 3600 + 4 * 60 + 5)),
            "1w2d03:04:05"
        );
    }
}
