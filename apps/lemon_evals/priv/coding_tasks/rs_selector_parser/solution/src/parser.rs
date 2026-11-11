use crate::{tokenize, Expr, Operator, ParseError, Token, TokenKind};

pub fn parse(input: &str) -> Result<Expr, ParseError> {
    let mut parser = Parser { tokens: tokenize(input)?, cursor: 0, end: input.len() };
    let expr = parser.disjunction()?;
    if parser.cursor != parser.tokens.len() {
        return Err(parser.error("unexpected trailing token"));
    }
    Ok(expr)
}
struct Parser { tokens: Vec<Token>, cursor: usize, end: usize }
impl Parser {
    fn peek(&self) -> Option<&TokenKind> { self.tokens.get(self.cursor).map(|t| &t.kind) }
    fn error(&self, message: &str) -> ParseError {
        ParseError::new(self.tokens.get(self.cursor).map_or(self.end, |t| t.start), message)
    }
    fn word(&self, word: &str) -> bool {
        matches!(self.peek(), Some(TokenKind::Word(value)) if value == word)
    }
    fn disjunction(&mut self) -> Result<Expr, ParseError> {
        let mut left = self.conjunction()?;
        while self.word("or") {
            self.cursor += 1;
            left = Expr::Or(Box::new(left), Box::new(self.conjunction()?));
        }
        Ok(left)
    }
    fn conjunction(&mut self) -> Result<Expr, ParseError> {
        let mut left = self.unary()?;
        while self.word("and") {
            self.cursor += 1;
            left = Expr::And(Box::new(left), Box::new(self.unary()?));
        }
        Ok(left)
    }
    fn unary(&mut self) -> Result<Expr, ParseError> {
        if self.word("not") {
            self.cursor += 1;
            return Ok(Expr::Not(Box::new(self.unary()?)));
        }
        if self.peek() == Some(&TokenKind::LParen) {
            self.cursor += 1;
            let value = self.disjunction()?;
            self.expect(TokenKind::RParen, "expected ')'")?;
            return Ok(value);
        }
        if self.word("exists") {
            self.cursor += 1;
            self.expect(TokenKind::LParen, "expected '('")?;
            let key = self.key()?;
            self.expect(TokenKind::RParen, "expected ')'")?;
            return Ok(Expr::Exists(key));
        }
        let key = self.key()?;
        let op = match self.peek() {
            Some(TokenKind::Eq) => Operator::Eq,
            Some(TokenKind::Ne) => Operator::Ne,
            Some(TokenKind::Prefix) => Operator::Prefix,
            Some(TokenKind::Suffix) => Operator::Suffix,
            Some(TokenKind::Contains) => Operator::Contains,
            _ => return Err(self.error("expected operator")),
        };
        self.cursor += 1;
        let value = match self.peek() {
            Some(TokenKind::Word(s) | TokenKind::String(s)) => s.clone(),
            _ => return Err(self.error("expected value")),
        };
        self.cursor += 1;
        Ok(Expr::Compare { key, op, value })
    }
    fn key(&mut self) -> Result<String, ParseError> {
        let key = match self.peek() {
            Some(TokenKind::Word(s)) if valid_key(s) => s.clone(),
            _ => return Err(self.error("expected key")),
        };
        self.cursor += 1;
        Ok(key)
    }
    fn expect(&mut self, kind: TokenKind, message: &str) -> Result<(), ParseError> {
        if self.peek() != Some(&kind) { return Err(self.error(message)); }
        self.cursor += 1;
        Ok(())
    }
}
fn valid_key(key: &str) -> bool {
    !matches!(key, "and" | "or" | "not" | "exists")
        && key.as_bytes().first().map_or(false, |b| b.is_ascii_alphabetic() || *b == b'_')
        && key.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'-'))
}
