use crate::{Commit, Error, Event, EventSource, Manifest, Report, Request};
use std::collections::BTreeMap;
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Engine {
    pub cache: crate::cache::Cache,
    pub journal: Vec<Commit>,
}
impl Engine {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn build(&mut self, manifest: &Manifest, request: &Request) -> Result<Report, Error> {
        let plan = crate::planning::plan(manifest, request)?;
        let nodes: BTreeMap<&str, &crate::Artifact> = manifest
            .artifacts
            .iter()
            .map(|node| (node.id.as_str(), node))
            .collect();
        let mut keys = BTreeMap::new();
        let mut values: BTreeMap<String, String> = BTreeMap::new();
        let mut staged = BTreeMap::new();
        let mut events = Vec::new();
        for id in plan.order {
            let node = nodes[id.as_str()];
            let key = crate::fingerprint::key(node, request, &keys);
            let (output, source) = if let Some(output) = crate::cache::lookup(&self.cache, &key) {
                (output.to_owned(), EventSource::Cached)
            } else {
                let inputs: Vec<&str> = node.deps.iter().map(|dep| values[dep].as_str()).collect();
                let output = crate::recipes::execute(node, request, &inputs)?;
                staged.insert(key.clone(), crate::cache::entry(output.clone()));
                (output, EventSource::Built)
            };
            keys.insert(id.clone(), key.clone());
            values.insert(id.clone(), output.clone());
            events.push(Event {
                id,
                key,
                output,
                source,
            });
        }
        let outputs = plan
            .roots
            .iter()
            .map(|id| (id.clone(), values[id].clone()))
            .collect();
        let report = Report {
            run: self.journal.len() as u64 + 1,
            roots: plan.roots,
            events,
            outputs,
        };
        self.cache.extend(staged);
        self.journal.push(Commit {
            manifest: manifest.clone(),
            request: request.clone(),
            report: report.clone(),
        });
        Ok(report)
    }
    pub fn restore(&mut self, commits: &[Commit]) -> Result<(), Error> {
        *self = crate::replay::replay(commits)?;
        Ok(())
    }
}
