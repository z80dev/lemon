use std::collections::BTreeMap;
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Kind {
    Text { nonempty: bool },
    Integer { min: i64, max: i64 },
    Boolean,
    List { min: usize, max: usize },
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Rule {
    pub path: String,
    pub kind: Kind,
    pub required: bool,
    pub secret: bool,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Constraint {
    Requires { when: String, path: String },
    Exclusive(Vec<String>),
}
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Schema {
    pub rules: Vec<Rule>,
    pub constraints: Vec<Constraint>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Op {
    Set { path: String, value: String },
    SetList { path: String, values: Vec<String> },
    Append { path: String, values: Vec<String> },
    Remove { path: String, values: Vec<String> },
    Delete { path: String },
}
impl Op {
    pub fn path(&self) -> &str {
        match self {
            Self::Set { path, .. }
            | Self::SetList { path, .. }
            | Self::Append { path, .. }
            | Self::Remove { path, .. }
            | Self::Delete { path } => path,
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Layer {
    pub name: String,
    pub parents: Vec<String>,
    pub operations: Vec<Op>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Origin {
    pub layer: String,
    pub operation: usize,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Value {
    Text(String),
    Integer(i64),
    Boolean(bool),
    List(Vec<String>),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Resolved {
    pub value: Value,
    pub origin: Origin,
    pub contributors: Vec<Origin>,
    pub references: Vec<String>,
}
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Compiled {
    pub layers: Vec<String>,
    pub values: BTreeMap<String, Resolved>,
    pub tombstones: BTreeMap<String, Origin>,
}
