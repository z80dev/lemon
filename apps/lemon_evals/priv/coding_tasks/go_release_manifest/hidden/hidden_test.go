package manifest

import (
	"errors"
	"io"
	"reflect"
	"strings"
	"testing"
)

var readFailure = errors.New("manifest device failed")

type failReader struct{}

func (failReader) Read([]byte) (int, error) { return 0, readFailure }
func TestManifestGrammar(t *testing.T) {
	text := "# release\r\n\t\r\nimage = registry/app:12 # ignored\r\nnote=\"snowman ☃ # yes \\n\\t\\\"\\\\\"#end\r\nempty=\"\"\r\nmode = fast"
	want := []Entry{{"image", "registry/app:12"}, {"note", "snowman ☃ # yes \n\t\"\\"}, {"empty", ""}, {"mode", "fast"}}
	got, err := Parse(strings.NewReader(text))
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("got %#v %v want %#v", got, err, want)
	}
	for _, text := range []string{"", " # note\n\t\n"} {
		got, err := Parse(strings.NewReader(text))
		if got != nil || err != nil {
			t.Fatalf("empty: %v %v", got, err)
		}
	}
	long := strings.Repeat("z", 140000)
	got, err = Parse(strings.NewReader("asset=\"" + long + "\""))
	if err != nil || len(got) != 1 || got[0].Value != long {
		t.Fatal("long line")
	}
	bad := []string{"a", "A=x", "1a=x", "a b=x", "a=", "a='x'", "a=x y", "a=\"x\"garbage", "a=\"no", "a=\"bad\\q\"", "a=\"bad\\", "a=\"raw\t\"", "a=\"raw\x7f\"", "a=\xff", "#\xff", "a=\"x\ny\"", "a=x\r"}
	for _, line := range bad {
		got, err := Parse(strings.NewReader("# header\n\n" + line))
		var pe *ParseError
		if got != nil || !errors.As(err, &pe) || pe.Line != 3 || pe.Message == "" {
			t.Fatalf("%q: %v %v", line, got, err)
		}
	}
	got, err = Parse(strings.NewReader("a=x\n# comment\na=y"))
	var pe *ParseError
	if got != nil || !errors.As(err, &pe) || pe.Line != 3 {
		t.Fatal("duplicate line")
	}
	got, err = Parse(io.MultiReader(strings.NewReader("a=ok\n"), failReader{}))
	if got != nil || !errors.Is(err, readFailure) {
		t.Fatalf("reader failure %v %v", got, err)
	}
}
