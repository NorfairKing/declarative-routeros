use crate::session::connect;

pub fn command() -> Result<(), ssh2::Error> {
    let _session = connect()?;
    Ok(())
}
