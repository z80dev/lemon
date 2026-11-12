package app

import (
	rg "arena/releasegraph"
	"arena/releasegraph/adapters/jsonapi"
	"fmt"
	"io"
	"os"
)

func Run(args []string, in io.Reader, out, stderr io.Writer) int {
	if len(args) != 2 || (args[0] != "plan" && args[0] != "report") {
		fmt.Fprintln(stderr, "usage: releaseplan plan|report catalog.json")
		return 2
	}
	file, err := os.Open(args[1])
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	defer file.Close()
	packages, err := jsonapi.ReadPackages(file)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	g, err := rg.Build(packages)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	req, err := jsonapi.ReadRequest(in)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	p, err := g.Plan(req)
	if err == nil {
		if args[0] == "plan" {
			err = jsonapi.WritePlan(out, p)
		} else {
			err = rg.WriteReport(out, p)
		}
	}
	if err != nil {
		fmt.Fprintln(stderr, err)
		return 1
	}
	return 0
}
