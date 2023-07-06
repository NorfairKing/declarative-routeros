use ssh2::Session;
use std::env;
use std::net::TcpStream;

pub fn connect() -> Result<ssh2::Session, ssh2::Error> {
    // Connect to the local SSH server
    let tcp = TcpStream::connect("192.168.100.1:22").unwrap();
    let mut session = Session::new()?;
    session.set_tcp_stream(tcp);
    session.handshake()?;

    session.userauth_password(
        &env::var("ROUTEROS_SSH_USER").unwrap(),
        &env::var("ROUTEROS_SSH_PASSWORD").unwrap(),
    )?;
    Ok(session)
}
