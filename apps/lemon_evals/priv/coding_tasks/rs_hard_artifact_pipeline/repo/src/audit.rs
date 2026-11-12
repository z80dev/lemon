use crate::{Engine, EventSource};
#[derive(Debug, PartialEq, Eq)]
pub struct Totals {
    pub runs: usize,
    pub built: usize,
    pub cached: usize,
    pub bytes: usize,
}
pub fn totals(engine: &Engine) -> Totals {
    let mut result = Totals {
        runs: engine.journal.len(),
        built: 0,
        cached: 0,
        bytes: 0,
    };
    for commit in &engine.journal {
        for event in &commit.report.events {
            match event.source {
                EventSource::Built => result.built += 1,
                EventSource::Cached => result.cached += 1,
            }
            result.bytes += event.output.len();
        }
    }
    result
}
