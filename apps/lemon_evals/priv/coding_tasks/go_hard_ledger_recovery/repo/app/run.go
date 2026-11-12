package app

import (
	l "arena/ledger"
	"arena/ledger/adapters/files"
	"arena/ledger/adapters/jsonapi"
	"fmt"
	"io"
)

func Run(args []string, in io.Reader, out, stderr io.Writer) int {
	fail := func(err error) int { fmt.Fprintln(stderr, err); return 1 }
	if len(args) == 1 && args[0] == "encode" {
		records, err := jsonapi.ReadRecords(in)
		if err != nil {
			return fail(err)
		}
		data, err := l.EncodeRecords(records)
		if err != nil {
			return fail(err)
		}
		_, err = out.Write(data)
		if err != nil {
			return fail(err)
		}
		return 0
	}
	if len(args) == 1 && args[0] == "checkpoint" {
		s, err := jsonapi.ReadSnapshot(in)
		if err != nil {
			return fail(err)
		}
		if err = jsonapi.WriteSnapshot(out, s); err != nil {
			return fail(err)
		}
		return 0
	}
	if len(args) != 3 || (args[0] != "recover" && args[0] != "report") {
		fmt.Fprintln(stderr, "usage: ledger encode|checkpoint OR ledger recover|report snapshot.json journal.bin")
		return 2
	}
	result, err := files.Recover(args[1], args[2])
	if err != nil {
		return fail(err)
	}
	if args[0] == "recover" {
		err = jsonapi.WriteResult(out, result)
	} else {
		err = l.WriteReport(out, result)
	}
	if err != nil {
		return fail(err)
	}
	return 0
}
