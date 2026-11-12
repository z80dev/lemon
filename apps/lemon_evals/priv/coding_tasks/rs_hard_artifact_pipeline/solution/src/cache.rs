use crate::CacheEntry;
use std::collections::BTreeMap;
pub type Cache = BTreeMap<String, CacheEntry>;
pub fn lookup<'a>(cache: &'a Cache, key: &str) -> Option<&'a str> {
    let entry = cache.get(key)?;
    (crate::digest::hash(entry.output.as_bytes()) == entry.digest).then_some(entry.output.as_str())
}
pub fn entry(output: String) -> CacheEntry {
    CacheEntry {
        digest: crate::digest::hash(output.as_bytes()),
        output,
    }
}
