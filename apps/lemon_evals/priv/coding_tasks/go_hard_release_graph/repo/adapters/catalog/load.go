package catalog

import (
	rg "arena/releasegraph"
	"encoding/json"
	"io/fs"
	"path"
)

func Load(fsys fs.FS, dir string) ([]rg.Package, error) {
	entries, err := fs.ReadDir(fsys, dir)
	if err != nil {
		return nil, err
	}
	out := []rg.Package{}
	for _, entry := range entries {
		if entry.IsDir() || path.Ext(entry.Name()) != ".json" {
			continue
		}
		data, err := fs.ReadFile(fsys, path.Join(dir, entry.Name()))
		if err != nil {
			return nil, err
		}
		var p rg.Package
		if err = json.Unmarshal(data, &p); err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, nil
}
