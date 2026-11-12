package manifest

import "fmt"

type Entry struct{ Key, Value string }
type ParseError struct {
	Line    int
	Message string
}

func (e *ParseError) Error() string { return fmt.Sprintf("line %d: %s", e.Line, e.Message) }
