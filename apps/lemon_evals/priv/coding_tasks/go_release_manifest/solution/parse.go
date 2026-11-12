package manifest

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"strings"
	"unicode/utf8"
)

func keyOK(s string) bool {
	if len(s) == 0 || s[0] < 'a' || s[0] > 'z' {
		return false
	}
	for i := 1; i < len(s); i++ {
		c := s[i]
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_' || c == '.' || c == '-') {
			return false
		}
	}
	return true
}
func bareOK(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || strings.ContainsRune("_./:-", rune(c))
}
func parseLine(line string) (Entry, bool, error) {
	bad := func() (Entry, bool, error) { return Entry{}, false, errors.New("invalid assignment") }
	if !utf8.ValidString(line) {
		return bad()
	}
	line = strings.Trim(line, " \t")
	if line == "" || line[0] == '#' {
		return Entry{}, false, nil
	}
	pos := strings.IndexByte(line, '=')
	if pos < 0 {
		return bad()
	}
	key := strings.Trim(line[:pos], " \t")
	if !keyOK(key) {
		return bad()
	}
	rest := strings.TrimLeft(line[pos+1:], " \t")
	if rest == "" {
		return bad()
	}
	var value strings.Builder
	if rest[0] == '"' {
		i := 1
		closed := false
		for i < len(rest) {
			c := rest[i]
			i++
			if c == '"' {
				closed = true
				break
			}
			if c == '\\' {
				if i >= len(rest) {
					return bad()
				}
				c = rest[i]
				i++
				switch c {
				case '\\', '"':
					value.WriteByte(c)
				case 'n':
					value.WriteByte('\n')
				case 't':
					value.WriteByte('\t')
				default:
					return bad()
				}
			} else {
				if c < 32 || c == 127 {
					return bad()
				}
				value.WriteByte(c)
			}
		}
		if !closed {
			return bad()
		}
		rest = rest[i:]
	} else {
		i := 0
		for i < len(rest) && bareOK(rest[i]) {
			i++
		}
		if i == 0 {
			return bad()
		}
		value.WriteString(rest[:i])
		rest = rest[i:]
	}
	rest = strings.TrimLeft(rest, " \t")
	if rest != "" && rest[0] != '#' {
		return bad()
	}
	return Entry{Key: key, Value: value.String()}, true, nil
}
func Parse(input io.Reader) ([]Entry, error) {
	r := bufio.NewReader(input)
	var out []Entry
	seen := map[string]bool{}
	for n := 1; ; n++ {
		line, err := r.ReadString('\n')
		if err != nil && !errors.Is(err, io.EOF) {
			return nil, fmt.Errorf("read manifest: %w", err)
		}
		if len(line) > 0 {
			if strings.HasSuffix(line, "\n") {
				line = strings.TrimSuffix(line, "\n")
				line = strings.TrimSuffix(line, "\r")
			}
			entry, ok, e := parseLine(line)
			if e != nil {
				return nil, &ParseError{Line: n, Message: e.Error()}
			}
			if ok {
				if seen[entry.Key] {
					return nil, &ParseError{Line: n, Message: "duplicate key"}
				}
				seen[entry.Key] = true
				out = append(out, entry)
			}
		}
		if errors.Is(err, io.EOF) {
			return out, nil
		}
	}
}
