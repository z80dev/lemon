package app

import (
	"encoding/csv"
	"fmt"
	"io"
	"strconv"
)

func Run(args []string, input io.Reader, stdout, stderr io.Writer) int {
	rows, err := csv.NewReader(input).ReadAll()
	if err != nil || len(rows) == 0 {
		fmt.Fprintln(stderr, "invalid CSV")
		return 1
	}
	fmt.Fprintln(stdout, "sku,total")
	for _, r := range rows[1:] {
		if len(r) != 2 {
			return 1
		}
		n, e := strconv.ParseInt(r[1], 10, 64)
		if e != nil {
			return 1
		}
		fmt.Fprintf(stdout, "%s,%d\n", r[0], n)
	}
	return 0
}
