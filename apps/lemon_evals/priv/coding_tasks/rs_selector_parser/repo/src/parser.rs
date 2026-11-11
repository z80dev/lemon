use crate::{tokenize, Expr, Operator, ParseError, Token, TokenKind};

pub fn parse(input: &str) -> Result<Expr, ParseError> {
    let mut parser = Parser { tokens: tokenize(input)?, cursor: 0, end: input.len() };
    let mut expression = parser.term()?;
    while parser.cursor < parser.tokens.len() {
        let is_and = match parser.peek() {
            Some(TokenKind::Word(word)) if word == "and" => true,
            Some(TokenKind::Word(word)) if word == "or" => false,
            _ => return Err(parser.error("unexpected trailing token")),
        };
        parser.cursor += 1;
        let right = parser.term()?;
        expression = if is_and {
            Expr::And(Box::new(expression), Box::new(right))
        } else {
            Expr::Or(Box::new(expression), Box::new(right))
        };
    }
    Ok(expression)
}
struct Parser { tokens: Vec<Token>, cursor: usize, end: usize }
impl Parser {
    fn peek(&self) -> Option<&TokenKind> { self.tokens.get(self.cursor).map(|t| &t.kind) }
    fn error(&self, message: &str) -> ParseError {
        ParseError::new(self.tokens.get(self.cursor).map_or(self.end, |t| t.start), message)
    }
    fn term(&mut self) -> Result<Expr, ParseError> {
        let key = self.key()?;
        if key == "exists" {
            self.expect(TokenKind::LParen, "expected '('")?;
            let name = self.key()?;
            self.expect(TokenKind::RParen, "expected ')'")?;
            return Ok(Expr::Exists(name));
        }
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
            Some(TokenKind::Word(s)) => s.clone(),
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
