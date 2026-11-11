package app

import (
	"bytes"
	"encoding/csv"
	"errors"
	"flag"
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"
)

func Run(args []string, input io.Reader, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("stocksum", flag.ContinueOnError)
	fs.SetOutput(stderr)
	sku := fs.String("sku", "", "only this SKU")
	min := fs.Int64("min", 0, "minimum total")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		return 2
	}
	if fs.NArg() != 0 {
		fmt.Fprintln(stderr, "unexpected positional arguments")
		return 2
	}
	fail := func(err error) int { fmt.Fprintln(stderr, err); return 1 }
	reader := csv.NewReader(input)
	header, err := reader.Read()
	if err != nil {
		return fail(fmt.Errorf("header: %w", err))
	}
	if len(header) != 2 || header[0] != "sku" || header[1] != "quantity" {
		return fail(errors.New("expected sku,quantity header"))
	}
	totals := map[string]int64{}
	for {
		row, err := reader.Read()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return fail(err)
		}
		if len(row) != 2 {
			return fail(errors.New("expected two fields"))
		}
		key := strings.TrimSpace(row[0])
		n, err := strconv.ParseInt(strings.TrimSpace(row[1]), 10, 64)
		if key == "" || err != nil {
			return fail(errors.New("invalid stock movement"))
		}
		totals[key] += n
	}
	keys := make([]string, 0, len(totals))
	for key, n := range totals {
		if (*sku == "" || key == *sku) && n >= *min {
			keys = append(keys, key)
		}
	}
	sort.Strings(keys)
	var buf bytes.Buffer
	writer := csv.NewWriter(&buf)
	_ = writer.Write([]string{"sku", "total"})
	for _, key := range keys {
		_ = writer.Write([]string{key, strconv.FormatInt(totals[key], 10)})
	}
	writer.Flush()
	if _, err := io.Copy(stdout, &buf); err != nil {
		return fail(err)
	}
	return 0
}
