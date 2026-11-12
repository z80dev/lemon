package releasegraph

type Version struct {
	Major int `json:"major"`
	Minor int `json:"minor"`
	Patch int `json:"patch"`
}
type Dependency struct {
	Name   string `json:"name"`
	Kind   string `json:"kind"`
	Policy string `json:"policy"`
}
type Package struct {
	Name         string       `json:"name"`
	Version      Version      `json:"version"`
	Group        string       `json:"group"`
	Private      bool         `json:"private"`
	Dependencies []Dependency `json:"dependencies"`
}
type Change struct {
	Name  string `json:"name"`
	Level string `json:"level"`
}
type Request struct {
	Changes        []Change `json:"changes"`
	IncludePrivate bool     `json:"include_private"`
}
type Release struct {
	Name    string   `json:"name"`
	Before  Version  `json:"before"`
	After   Version  `json:"after"`
	Level   string   `json:"level"`
	Reasons []string `json:"reasons"`
}
type Plan struct {
	Revision    uint64     `json:"revision"`
	Releases    []Release  `json:"releases"`
	Waves       [][]string `json:"waves"`
	Fingerprint string     `json:"fingerprint"`
}
type Edit struct {
	Remove string   `json:"remove,omitempty"`
	Upsert *Package `json:"upsert,omitempty"`
}
type Update struct {
	Expected uint64 `json:"expected"`
	Edits    []Edit `json:"edits"`
}
type Snapshot struct {
	Revision uint64    `json:"revision"`
	Packages []Package `json:"packages"`
}
