use selector_parser::{parse, tokenize, Expr, Operator, TokenKind};
#[test]
fn comparisons_and_tokens() {
    assert_eq!(parse("name=west"), Ok(Expr::Compare { key: "name".into(), op: Operator::Eq, value: "west".into() }));
    let tokens = tokenize(" x != 'blue' ").unwrap();
    assert_eq!((tokens[0].start, tokens[0].end), (1, 2));
    assert_eq!(tokens[1].kind, TokenKind::Ne);
    assert_eq!(tokens[2].kind, TokenKind::String("blue".into()));
}
#[test]
fn existence_and_empty_errors() {
    assert_eq!(parse("exists(region)"), Ok(Expr::Exists("region".into())));
    assert!(parse("").is_err());
    assert!(parse("name=").is_err());
}
