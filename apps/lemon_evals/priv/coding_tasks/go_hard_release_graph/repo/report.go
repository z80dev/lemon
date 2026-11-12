package releasegraph

import (
	"fmt"
	"io"
	"strings"
)

func WriteReport(w io.Writer, p Plan) error {
	for i, wave := range p.Waves {
		if _, err := fmt.Fprintf(w, "wave %d: %s\n", i+1, strings.Join(wave, ",")); err != nil {
			return err
		}
	}
	for _, r := range p.Releases {
		if _, err := fmt.Fprintf(w, "%s %d.%d.%d -> %d.%d.%d [%s]\n", r.Name, r.Before.Major, r.Before.Minor, r.Before.Patch, r.After.Major, r.After.Minor, r.After.Patch, strings.Join(r.Reasons, ",")); err != nil {
			return err
		}
	}
	return nil
}
