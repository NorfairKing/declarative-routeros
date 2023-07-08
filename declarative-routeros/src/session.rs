use clap::Args;
use rpassword::prompt_password;
use ssh2::Session;
use std::{
    env,
    io::Read,
    net::{IpAddr, SocketAddr, TcpStream},
};
use tracing::{debug, error, info};

#[derive(Debug, Clone, Args)]
pub struct SessionFlags {
    #[arg(short, long)]
    username: String,
    #[arg()]
    router_address: IpAddr,
}

pub struct SessionSettings {
    pub username: String,
    pub password: String,
    pub router_address: SocketAddr,
}

pub fn combine_to_session_settings(flags: SessionFlags) -> SessionSettings {
    let username = flags.username;
    let password = env::var("ROUTEROS_SSH_PASSWORD")
        .or_else(|_| prompt_password("Password: "))
        .unwrap();
    let router_address = SocketAddr::new(flags.router_address, 22);
    SessionSettings {
        username,
        password,
        router_address,
    }
}

pub fn connect(settings: SessionSettings) -> Result<ssh2::Session, ssh2::Error> {
    // Connect to the local SSH server
    let tcp = TcpStream::connect(settings.router_address).unwrap();
    let mut session = Session::new()?;
    session.set_tcp_stream(tcp);
    session.handshake()?;

    session.userauth_password(&settings.username, &settings.password)?;
    Ok(session)
}

pub fn run_command_remotely(session: &ssh2::Session, command: &str) -> Result<(), ssh2::Error> {
    let mut channel = session.channel_session()?;
    info!("Running remotely: {}", command);
    channel.exec(&command)?;
    let mut response = String::new();
    channel.read_to_string(&mut response).unwrap();
    debug!(
        "Response after removing the remote backup file: {}.",
        response
    );
    channel.wait_close()?;
    let exit_status = channel.exit_status()?;
    debug!("Exit code: {}", exit_status);
    if exit_status != 0 {
        error!(
            "Command failed with exit code: {}.\n{}",
            exit_status, response
        );
    }
    Ok(())
}
