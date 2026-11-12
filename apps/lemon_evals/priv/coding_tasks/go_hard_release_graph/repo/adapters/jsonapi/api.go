package jsonapi

import (
	rg "arena/releasegraph"
	"io"
)

func ReadPackages(r io.Reader) ([]rg.Package, error) {
	var p []rg.Package
	err := decode(r, &p)
	return p, err
}
func ReadRequest(r io.Reader) (rg.Request, error) {
	var req rg.Request
	err := decode(r, &req)
	return req, err
}
func ReadUpdate(r io.Reader) (rg.Update, error) { var u rg.Update; err := decode(r, &u); return u, err }
func ReadSnapshot(r io.Reader) (rg.Snapshot, error) {
	var s rg.Snapshot
	err := decode(r, &s)
	return s, err
}
func WritePlan(w io.Writer, p rg.Plan) error         { return encode(w, p) }
func WriteSnapshot(w io.Writer, s rg.Snapshot) error { return encode(w, s) }
