#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Change {
    Set { prefix: String, target: String },
    Remove { prefix: String },
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Resolved {
    pub prefix: String,
    pub target: String,
    pub remainder: String,
    pub layer: usize,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RouteError { InvalidPath(String), EmptyTarget { index: usize } }
