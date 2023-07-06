use ssh2::Session;
use std::net::{SocketAddr, TcpStream};

pub fn connect(settings: SessionSettings) -> Result<ssh2::Session, ssh2::Error> {
    // Connect to the local SSH server
    let tcp = TcpStream::connect(settings.address).unwrap();
    let mut session = Session::new()?;
    session.set_tcp_stream(tcp);
    session.handshake()?;

    session.userauth_password(&settings.user, &settings.password)?;
    Ok(session)
}

pub struct SessionSettings {
    pub user: String,
    pub password: String,
    pub address: SocketAddr,
}
