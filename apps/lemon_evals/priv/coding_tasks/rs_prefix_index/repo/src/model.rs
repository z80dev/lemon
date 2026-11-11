#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Scope { Global, Tenant(u64) }

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Action { Route(String), Deny }

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuleMatch { pub scope: Scope, pub prefix: String, pub action: Action }

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Lookup { pub matched: Option<RuleMatch>, pub nodes_visited: usize }

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PathError { NotAbsolute, ParentSegment, InvalidCharacter }
