use crate::{Commit, Engine, Error};
pub fn replay(commits: &[Commit]) -> Result<Engine, Error> {
    let mut engine = Engine::new();
    for (index, commit) in commits.iter().enumerate() {
        let report = engine
            .build(&commit.manifest, &commit.request)
            .map_err(|_| Error::new("journal", index.to_string()))?;
        if report != commit.report {
            return Err(Error::new("journal", index.to_string()));
        }
    }
    Ok(engine)
}
