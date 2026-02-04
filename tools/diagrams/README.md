# Lemon Diagram Generator

Generates SVG diagrams from Mermaid syntax for the Lemon documentation.

## Prerequisites

- Node.js 18+

## Setup

```bash
cd tools/diagrams
npm install
```

## Usage

```bash
# Generate all diagrams
node generate.js

# Generate a specific diagram
node generate.js architecture

# List available diagrams
node generate.js --list

# Show help
node generate.js --help
```

## Adding New Diagrams

1. Create a `.mmd` file in `tools/diagrams/mermaid/`:

```mermaid
flowchart TB
    A[Start] --> B[Process]
    B --> C[End]
```

2. Run the generator:

```bash
node generate.js
```

3. The SVG will be output to:
   - `tools/diagrams/output/svg/<name>.svg` (working copy)
   - `docs/diagrams/<name>.svg` (for README embedding)

## Embedding in README

Use standard markdown image syntax:

```markdown
![Diagram Name](docs/diagrams/diagram-name.svg)
```

## Current Diagrams

| Diagram | Description |
|---------|-------------|
| `architecture` | Overall system architecture |
| `data-flow` | Data flow paths through the system |
| `supervision-tree` | OTP supervision hierarchy |
| `orchestration` | Orchestration runtime components |
| `tool-execution` | Tool execution with approval gating |
| `event-bus` | Event-driven pub/sub architecture |

## Mermaid Syntax Reference

See [Mermaid documentation](https://mermaid.js.org/syntax/flowchart.html) for syntax reference.

Common patterns used:

```mermaid
flowchart TB           # Top to bottom
flowchart LR           # Left to right

subgraph Name["Label"]
    A --> B
end

A["Multi-line<br/>text"]
A{{"Decision"}}
A[["Subprocess"]]
```

## Configuration

The diagram style is configured in `generate.js`:

- Theme: default with lemon-yellow primary color
- Font size: 14px
- Transparent background
- Basis curve for connections
