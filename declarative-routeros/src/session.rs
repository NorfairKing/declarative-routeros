use clap::Args;
use rpassword::prompt_password;
use ssh2::Session;
use std::{
    env,
    net::{IpAddr, SocketAddr, TcpStream},
};

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
