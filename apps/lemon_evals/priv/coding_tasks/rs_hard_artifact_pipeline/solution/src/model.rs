use std::collections::BTreeMap;
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Recipe {
    Source(String),
    Join(String),
    Replace { from: String, to: String },
    Slice { start: usize, end: usize },
    Fail(String),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Artifact {
    pub id: String,
    pub deps: Vec<String>,
    pub recipe: Recipe,
}
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Manifest {
    pub artifacts: Vec<Artifact>,
}
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Request {
    pub targets: Vec<String>,
    pub overrides: BTreeMap<String, String>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Plan {
    pub roots: Vec<String>,
    pub order: Vec<String>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EventSource {
    Built,
    Cached,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Event {
    pub id: String,
    pub key: String,
    pub output: String,
    pub source: EventSource,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Report {
    pub run: u64,
    pub roots: Vec<String>,
    pub events: Vec<Event>,
    pub outputs: BTreeMap<String, String>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CacheEntry {
    pub output: String,
    pub digest: String,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Commit {
    pub manifest: Manifest,
    pub request: Request,
    pub report: Report,
}
