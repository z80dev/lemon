package manifest

import (
	"reflect"
	"strings"
	"testing"
)

func TestBasic(t *testing.T) {
	got, err := Parse(strings.NewReader("image = registry/app:12\n"))
	if err != nil || !reflect.DeepEqual(got, []Entry{{"image", "registry/app:12"}}) {
		t.Fatalf("%v %v", got, err)
	}
}
