use crate::ParseError;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TokenKind {
    Word(String), String(String), Eq, Ne, Prefix, Suffix, Contains, LParen, RParen,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Token { pub kind: TokenKind, pub start: usize, pub end: usize }

pub fn tokenize(input: &str) -> Result<Vec<Token>, ParseError> {
    let mut tokens = Vec::new();
    let mut cursor = 0;
    let bytes = input.as_bytes();
    while cursor < bytes.len() {
        let start = cursor;
        let byte = bytes[cursor];
        if byte.is_ascii_whitespace() { cursor += 1; continue; }
        let kind = match byte {
            b'(' => { cursor += 1; TokenKind::LParen }
            b')' => { cursor += 1; TokenKind::RParen }
            b'=' => { cursor += 1; TokenKind::Eq }
            b'!' | b'^' | b'$' | b'*' if bytes.get(cursor + 1) == Some(&b'=') => {
                cursor += 2;
                match byte { b'!' => TokenKind::Ne, b'^' => TokenKind::Prefix,
                    b'$' => TokenKind::Suffix, _ => TokenKind::Contains }
            }
            b'\'' | b'"' => {
                cursor += 1;
                let mut value = String::new();
                let mut closed = false;
                while cursor < bytes.len() {
                    let ch = input[cursor..].chars().next().unwrap();
                    if ch as u32 == byte as u32 {
                        cursor += 1; closed = true; break;
                    }
                    value.push(ch);
                    cursor += ch.len_utf8();
                }
                if !closed { return Err(ParseError::new(start, "unterminated string")); }
                TokenKind::String(value)
            }
            b if word_byte(b) => {
                cursor += 1;
                while cursor < bytes.len() && word_byte(bytes[cursor]) { cursor += 1; }
                TokenKind::Word(input[start..cursor].into())
            }
            _ => return Err(ParseError::new(cursor, "unexpected character")),
        };
        tokens.push(Token { kind, start, end: cursor });
    }
    Ok(tokens)
}
fn word_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b'/' | b':' | b'-')
}
