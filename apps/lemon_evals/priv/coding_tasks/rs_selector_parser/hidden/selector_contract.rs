use selector_parser::{parse, tokenize, Expr, Operator, ParseError, TokenKind};
fn cmp(key: &str, op: Operator, value: &str) -> Expr {
    Expr::Compare { key: key.into(), op, value: value.into() }
}
fn eq(key: &str) -> Expr { cmp(key, Operator::Eq, "1") }
fn and(a: Expr, b: Expr) -> Expr { Expr::And(Box::new(a), Box::new(b)) }
fn or(a: Expr, b: Expr) -> Expr { Expr::Or(Box::new(a), Box::new(b)) }
fn not(a: Expr) -> Expr { Expr::Not(Box::new(a)) }
fn error(text: &str, position: usize, message: &str) {
    assert_eq!(parse(text), Err(ParseError { position, message: message.into() }), "input {text:?}");
}
#[test]
fn precedence_associativity_and_groups() {
    assert_eq!(parse("a=1 or b=1 and not not c=1"), Ok(or(eq("a"), and(eq("b"), not(not(eq("c")))))));
    assert_eq!(parse("a=1 or b=1 or c=1"), Ok(or(or(eq("a"), eq("b")), eq("c"))));
    assert_eq!(parse("a=1 and b=1 and c=1"), Ok(and(and(eq("a"), eq("b")), eq("c"))));
    assert_eq!(parse("not(a=1 or b=1) and exists(_x.y-z)"),
        Ok(and(not(or(eq("a"), eq("b"))), Expr::Exists("_x.y-z".into()))));
}
#[test]
fn operators_values_and_keyword_boundaries() {
    for (symbol, op) in [("=", Operator::Eq), ("!=", Operator::Ne), ("^=", Operator::Prefix), ("$=", Operator::Suffix), ("*=", Operator::Contains)] {
        assert_eq!(parse(&format!("_a.b-c{symbol}https://a-b/x:9")), Ok(cmp("_a.b-c", op, "https://a-b/x:9")));
    }
    for word in ["and", "or", "not", "exists", "android", "north", "OR", "0"] {
        assert_eq!(parse(&format!("name={word}")), Ok(cmp("name", Operator::Eq, word)));
    }
    assert_eq!(parse("android=1"), Ok(eq("android")));
    assert_eq!(parse("\t\r\nname = ''\x0c"), Ok(cmp("name", Operator::Eq, "")));
}
#[test]
fn escaped_unicode_strings_and_byte_spans() {
    let text = r#"name="é\n\r\t\\\'\"雪""#;
    assert_eq!(parse(text), Ok(cmp("name", Operator::Eq, "é\n\r\t\\'\"雪")));
    let tokens = tokenize(text).unwrap();
    assert_eq!(tokens[2].start, 5);
    assert_eq!(tokens[2].end, text.len());
    assert_eq!(tokenize("'é' x").unwrap()[1].start, 5);
    assert_eq!(tokenize("'a\nb'").unwrap()[0].kind, TokenKind::String("a\nb".into()));
    assert_eq!(tokenize("'\\\"\\\''").unwrap()[0].kind, TokenKind::String("\"'".into()));
    assert!(tokenize(" \t\n").unwrap().is_empty());
    assert_eq!(tokenize("(x!=a)").unwrap().iter().map(|t| (t.start,t.end)).collect::<Vec<_>>(), vec![(0,1),(1,2),(2,4),(4,5),(5,6)]);
}
#[test]
fn precise_lexical_diagnostics() {
    for (text, pos, message) in [
        ("a=é",2,"unexpected character"), ("a='é' !",7,"unexpected character"),
        ("a='é\\q'",5,"invalid escape"), ("a='abc",2,"unterminated string"),
        ("a='abc\\",2,"unterminated string"), ("a=1 ^",4,"unexpected character"),
        ("a=1 $",4,"unexpected character"), ("a=1 *",4,"unexpected character"),
        ("a=1 &",4,"unexpected character"), ("a=1\u{a0}",3,"unexpected character"),
        ("= '\\z'",3,"invalid escape"), ("a='\\q' @",3,"invalid escape"),
    ] { error(text,pos,message); }
}
#[test]
fn precise_syntax_diagnostics() {
    for (text, pos, message) in [
        ("",0,"expected key"), ("  ",2,"expected key"), ("()",1,"expected key"),
        ("a",1,"expected operator"), ("a b",2,"expected operator"),
        ("a=",2,"expected value"), ("a=)",2,"expected value"),
        ("1a=x",0,"expected key"), ("a/b=x",0,"expected key"),
        ("'a'=x",0,"expected key"), ("and=x",0,"expected key"),
        ("exists x",7,"expected '('"), ("exists",6,"expected '('"),
        ("exists()",7,"expected key"), ("exists(and)",7,"expected key"),
        ("exists(a",8,"expected ')'"), ("exists(a b)",9,"expected ')'"),
        ("(a=1",4,"expected ')'"), ("(a=1 b=2)",5,"expected ')'"),
        ("a=1 and",7,"expected key"), ("not",3,"expected key"),
        ("a=1 or )",7,"expected key"), ("a=1 b=2",4,"unexpected trailing token"),
        ("a=b=c",3,"unexpected trailing token"), ("a=1)",3,"unexpected trailing token"),
        ("a='é' x",7,"unexpected trailing token"),
    ] { error(text,pos,message); }
}
