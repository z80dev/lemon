# Selector expressions

Repair the dependency-free `selector_parser` library. Preserve the public API below and separate lexer, syntax tree, and parser modules. The current implementation mishandles valid selectors and diagnostics.

## Public API (all re-exported at crate root)
```rust
pub enum Operator { Eq, Ne, Prefix, Suffix, Contains }
pub enum Expr {
    Compare { key: String, op: Operator, value: String },
    Exists(String), Not(Box<Expr>), And(Box<Expr>, Box<Expr>), Or(Box<Expr>, Box<Expr>),
}
pub enum TokenKind {
    Word(String), String(String), Eq, Ne, Prefix, Suffix, Contains, LParen, RParen,
}
pub struct Token { pub kind: TokenKind, pub start: usize, pub end: usize }
pub struct ParseError { pub position: usize, pub message: String }
pub fn tokenize(input: &str) -> Result<Vec<Token>, ParseError>;
pub fn parse(input: &str) -> Result<Expr, ParseError>;
```
All public structs/enums derive `Debug, Clone, PartialEq, Eq`. No evaluation API is required.

## Language
Whitespace is ASCII whitespace and is ignored between tokens. A word is a nonempty run of ASCII letters, digits, `_`, `.`, `/`, `:`, or `-`. Words are not split at keyword substrings. Token spans are half-open UTF-8 byte offsets in the original input; there is no EOF token. Operators are `=`, `!=`, `^=`, `$=`, `*=`. Parentheses are tokens.

Single- and double-quoted strings decode `\\`, `\'`, `\"`, `\n`, `\r`, and `\t` (either quote escape is legal in either string). All other escapes are invalid. Unicode and literal newlines inside strings are preserved. Empty quoted strings are legal. Quotes are not included in the decoded value, but are included in the token span. Unquoted Unicode is not a word character.

Grammar (keywords are exact, case-sensitive words):
```
expression = disjunction
 disjunction = conjunction ("or" conjunction)*
 conjunction = unary ("and" unary)*
 unary = "not" unary | "(" expression ")" | "exists" "(" key ")" | key operator value
 operator = "=" | "!=" | "^=" | "$=" | "*="
 value = word | quoted-string
```
`not` binds strongest, then `and`, then `or`; binary trees associate left. `key` must be an unquoted ASCII identifier `[A-Za-z_][A-Za-z0-9_.-]*` and cannot be `and`, `or`, `not`, or `exists`. Keywords are permitted as comparison values. There are no implicit conjunctions or chained comparisons. The entire input must be consumed. A bare key is not an existence test.

## Exact errors
`tokenize` and `parse` report lexical failures before parsing, even if an earlier token would cause a syntax error. Lexing reports `unexpected character` at the offending byte (including a lone `!`, `^`, `$`, or `*`); `invalid escape` at the backslash; `unterminated string` at the opening quote (including a dangling backslash). First lexical failure wins.

Syntax errors point at the start of the unexpected token, or `input.len()` at EOF. Messages are: `expected key` for an invalid key or an absent expression; `expected operator` after a key; `expected value` after an operator; `expected '('` after `exists`; `expected ')'` after a grouped expression or an existence key; `unexpected trailing token` after a complete expression. Dispatch recognizes `not` and `exists` before attempting a key. Empty input/groups, missing operands, extra tokens, and malformed existence calls must fail without panicking. No external crates.

Run `cargo test --offline`.
