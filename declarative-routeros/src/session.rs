use clap::Args;
use rpassword::prompt_password;
use ssh2::Session;
use std::{
    env,
    fs,
    io::Read,
    io::Write,
    net::{IpAddr, SocketAddr, TcpStream},
    path::Path,
    process::exit,
    sync::OnceLock,
    time::Duration,
};
use tracing::debug;


use crate::report;

#[derive(Debug, Clone, Args)]
pub struct SessionFlags {
    #[arg(short, long)]
    username: String,
    /// The ssh port, for a router reached through a forwarded one
    #[arg(long, default_value = "22")]
    port: u16,
    #[arg()]
    router_address: IpAddr,
}

#[derive(Clone)]
pub struct SessionSettings {
    pub username: String,
    pub router_address: SocketAddr,
}

pub fn combine_to_session_settings(flags: SessionFlags) -> SessionSettings {
    SessionSettings {
        username: flags.username,
        router_address: SocketAddr::new(flags.router_address, flags.port),
    }
}

/// On the first connection rather than when arguments are read, so a bad
/// argument is reported before a prompt, and asked once however many follow.
fn password() -> &'static str {
    PASSWORD.get_or_init(|| {
        match env::var("ROUTEROS_SSH_PASSWORD") {
            Ok(password) => password,
            Err(_) => match prompt_password("Password: ") {
                Ok(password) => password,
                Err(complaint) => {
                    report::problem("There is no password to be had.");
                    report::detail(&format!(
                        "ROUTEROS_SSH_PASSWORD is unset and there is nothing to ask on: {}",
                        complaint
                    ));
                    exit(1)
                }
            },
        }
    })
}

static PASSWORD: OnceLock<String> = OnceLock::new();

pub fn connect(settings: SessionSettings) -> Result<ssh2::Session, ssh2::Error> {
    match try_connect(&settings) {
        Ok(session) => Ok(session),
        Err(complaint) => {
            report::problem("Could not reach the router.");
            report::detail(&complaint);
            exit(1)
        }
    }
}

pub fn try_connect(settings: &SessionSettings) -> Result<Session, String> {
    let tcp = TcpStream::connect_timeout(&settings.router_address, Duration::from_secs(10))
        .map_err(|complaint| format!("no tcp connection: {}", complaint))?;
    let mut session = Session::new().map_err(|complaint| format!("no ssh session: {}", complaint))?;
    session.set_tcp_stream(tcp);
    session
        .handshake()
        .map_err(|complaint| format!("no ssh handshake: {}", complaint))?;
    // RouterOS accepts a connection well before it will authenticate one, so
    // this is the step that says whether the router is really back.
    session
        .userauth_password(&settings.username, password())
        .map_err(|complaint| format!("no ssh authentication: {}", complaint))?;
    Ok(session)
}

/// Stdout only: a value with an error mixed into it is worse than an error.
pub fn capture_command_remotely(
    session: &ssh2::Session,
    command: &str,
) -> Result<String, ssh2::Error> {
    match try_capture_command_remotely(session, command) {
        Ok(response) => Ok(response),
        Err(complaint) => {
            report::problem(&format!("Could not run: {}", command));
            report::detail(&complaint);
            exit(1)
        }
    }
}

pub fn try_capture_command_remotely(
    session: &ssh2::Session,
    command: &str,
) -> Result<String, String> {
    let mut channel = session
        .channel_session()
        .map_err(|complaint| format!("no channel: {}", complaint))?;
    report::detail(&format!("running: {}", command));
    channel
        .exec(command)
        .map_err(|complaint| format!("could not run it: {}", complaint))?;
    let mut response = String::new();
    channel
        .read_to_string(&mut response)
        .map_err(|complaint| format!("could not read the answer: {}", complaint))?;
    channel
        .wait_close()
        .map_err(|complaint| format!("the channel did not close: {}", complaint))?;
    let exit_status = channel
        .exit_status()
        .map_err(|complaint| format!("no exit status: {}", complaint))?;
    if exit_status != 0 {
        report::warn(&format!("Exit code {} from: {}", exit_status, command));
        report::detail(response.trim());
    }
    Ok(response)
}


/// Fatal: every caller was handed this path by something that built the file.
pub fn contents_of(path: &Path) -> Vec<u8> {
    fs::read(path).unwrap_or_else(|complaint| {
        report::fatal(
            &format!("Could not read {}.", path.display()),
            &complaint.to_string(),
        )
    })
}

pub fn upload(session: &Session, remote: &Path, bytes: &[u8]) -> Result<(), ssh2::Error> {
    let mut remote_file = session.scp_send(remote, 0o644, bytes.len() as u64, None)?;
    let sent = remote_file
        .write_all(bytes)
        .map_err(|complaint| complaint.to_string());
    // All of them: an unfinished transfer is a file the router has some of.
    let finished = [
        remote_file.send_eof(),
        remote_file.wait_eof(),
        remote_file.close(),
        remote_file.wait_close(),
    ];
    if let Err(complaint) = sent {
        report::fatal(
            &format!("Could not send {} to the router.", remote.display()),
            &complaint,
        );
    }
    for step in finished {
        if let Err(complaint) = step {
            report::fatal(
                &format!("Could not finish sending {} to the router.", remote.display()),
                &complaint.to_string(),
            );
        }
    }
    Ok(())
}
