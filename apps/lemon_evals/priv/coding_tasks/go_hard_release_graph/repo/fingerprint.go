package releasegraph

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strings"
)

func fingerprint(releases []Release) string {
	var b strings.Builder
	for _, r := range releases {
		fmt.Fprintf(&b, "%s=%d.%d.%d:%s\n", r.Name, r.After.Major, r.After.Minor, r.After.Patch, strings.Join(r.Reasons, ","))
	}
	sum := sha256.Sum256([]byte(b.String()))
	return hex.EncodeToString(sum[:])
}
