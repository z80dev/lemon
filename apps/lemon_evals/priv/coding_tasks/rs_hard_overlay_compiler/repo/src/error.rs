use std::fmt;
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Error {
    pub code: String,
    pub subject: String,
}
impl Error {
    pub fn new(code: &str, subject: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            subject: subject.into(),
        }
    }
}
impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}:{}", self.code, self.subject)
    }
}
impl std::error::Error for Error {}
