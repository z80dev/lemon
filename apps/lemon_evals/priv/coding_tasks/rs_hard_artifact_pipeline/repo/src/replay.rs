use crate::{Commit, Engine, Error};
pub fn replay(commits: &[Commit]) -> Result<Engine, Error> {
    let mut engine = Engine::new();
    for commit in commits {
        for event in &commit.report.events {
            engine
                .cache
                .insert(event.key.clone(), crate::cache::entry(event.output.clone()));
        }
        engine.journal.push(commit.clone());
    }
    Ok(engine)
}
