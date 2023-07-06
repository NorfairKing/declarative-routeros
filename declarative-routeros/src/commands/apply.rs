use crate::session::{connect, SessionSettings};

pub fn command(settings: SessionSettings) -> Result<(), ssh2::Error> {
    let _session = connect(settings)?;
    Ok(())
}
