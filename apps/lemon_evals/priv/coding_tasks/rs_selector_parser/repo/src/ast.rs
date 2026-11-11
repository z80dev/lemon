#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Operator { Eq, Ne, Prefix, Suffix, Contains }

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Expr {
    Compare { key: String, op: Operator, value: String },
    Exists(String),
    Not(Box<Expr>),
    And(Box<Expr>, Box<Expr>),
    Or(Box<Expr>, Box<Expr>),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParseError { pub position: usize, pub message: String }

impl ParseError {
    pub(crate) fn new(position: usize, message: &str) -> Self {
        Self { position, message: message.into() }
    }
}
