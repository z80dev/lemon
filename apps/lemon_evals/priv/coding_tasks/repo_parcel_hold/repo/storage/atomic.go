package storage

import (
    "encoding/json"
    "os"
    "path/filepath"
)
func save(path string, records map[string]record) error {
    file,err := os.CreateTemp(filepath.Dir(path),".parcels-*")
    if err != nil { return err }
    name := file.Name()
    defer os.Remove(name)
    if err := json.NewEncoder(file).Encode(snapshot{Records:records}); err != nil { _ = file.Close(); return err }
    if err := file.Close(); err != nil { return err }
    return os.Rename(name,path)
}
