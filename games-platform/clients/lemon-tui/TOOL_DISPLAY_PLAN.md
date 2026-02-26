# Tool Display Improvement Plan for lemon-tui

## Overview

This plan outlines improvements to how tools are displayed in the lemon-tui terminal client.
Currently, most tools display raw JSON with basic truncation. This plan introduces tool-specific
formatters that provide semantic, readable output for each tool type.

## Architecture

### New File Structure

```
clients/lemon-tui/src/
├── index.ts                 # Main TUI (updated to use formatters)
├── state.ts                 # State management (unchanged)
├── types.ts                 # Protocol types (unchanged)
├── formatters/
│   ├── index.ts             # Formatter registry and main entry point
│   ├── types.ts             # Formatter interface definitions
│   ├── base.ts              # Base utilities (truncation, ANSI helpers)
│   ├── bash.ts              # bash/exec tool formatter
│   ├── read.ts              # read tool formatter
│   ├── write.ts             # write tool formatter
│   ├── edit.ts              # edit/multiedit tool formatter
│   ├── patch.ts             # patch tool formatter
│   ├── grep.ts              # grep tool formatter
│   ├── find.ts              # find/glob/ls tool formatters
│   ├── web.ts               # webfetch/websearch tool formatters
│   ├── todo.ts              # todoread/todowrite tool formatters
│   ├── task.ts              # task tool formatter
│   └── process.ts           # process tool formatter
```

## Part 1: Formatter Infrastructure

### 1.1 Formatter Types (`formatters/types.ts`)

```typescript
export interface ToolFormatter {
  /** Tool name(s) this formatter handles */
  tools: string[];

  /** Format tool arguments for display */
  formatArgs(args: Record<string, unknown>): FormattedOutput;

  /** Format tool result for display */
  formatResult(result: unknown, args?: Record<string, unknown>): FormattedOutput;

  /** Format partial/streaming result */
  formatPartial?(partial: unknown, args?: Record<string, unknown>): FormattedOutput;
}

export interface FormattedOutput {
  /** Single-line summary (for inline display) */
  summary: string;

  /** Multi-line detailed view (for expanded panel) */
  details: string[];

  /** Whether this output is considered an error */
  isError?: boolean;
}
```

### 1.2 Base Utilities (`formatters/base.ts`)

- `truncateText(text: string, maxLength: number): string`
- `truncateLines(lines: string[], maxLines: number): string[]`
- `formatPath(path: string): string` - Shorten paths relative to cwd
- `formatDuration(ms: number): string` - Human-readable duration
- `formatBytes(bytes: number): string` - Human-readable file size
- `wrapAnsi(text: string, width: number): string[]` - Word wrap with ANSI codes
- `highlightPattern(text: string, pattern: string): string` - Highlight matches

### 1.3 Formatter Registry (`formatters/index.ts`)

```typescript
export class FormatterRegistry {
  private formatters: Map<string, ToolFormatter> = new Map();

  register(formatter: ToolFormatter): void;
  getFormatter(toolName: string): ToolFormatter | undefined;
  formatArgs(toolName: string, args: Record<string, unknown>): FormattedOutput;
  formatResult(toolName: string, result: unknown, args?: Record<string, unknown>): FormattedOutput;
}

export const defaultRegistry: FormatterRegistry;
```

## Part 2: Tool-Specific Formatters

### 2.1 Bash Formatter (`formatters/bash.ts`)

**Args Display:**
- Show command with syntax highlighting (keywords, strings, pipes)
- Show timeout if specified
- Truncate long commands with "..."

**Result Display:**
- Show exit code as badge: `[0]` (green) or `[1]` (red)
- Show stdout with proper line handling
- Show stderr in red/warning color
- Truncate long output with line count

Example:
```
▶ bash: git status --short
  [0] M  src/index.ts
      ?? new-file.txt
      ... (3 more lines)
```

### 2.2 Read Formatter (`formatters/read.ts`)

**Args Display:**
- Show file path (shortened relative to cwd)
- Show offset/limit if specified

**Result Display:**
- Detect file type from extension
- Show line count and character count
- Preview first few lines with line numbers
- For images: show "[Image: 1920x1080 PNG]"

Example:
```
▶ read: ./src/index.ts (lines 1-50)
  1│ import { foo } from 'bar';
  2│ import { baz } from 'qux';
  3│ ...
  (248 lines, 8.2 KB)
```

### 2.3 Write Formatter (`formatters/write.ts`)

**Args Display:**
- Show file path
- Show content preview (first line + line count)

**Result Display:**
- Show success/failure status
- Show bytes written
- Show "Created" vs "Updated" indicator

Example:
```
▶ write: ./src/new-file.ts
  ✓ Created (42 lines, 1.2 KB)
```

### 2.4 Edit/MultiEdit Formatter (`formatters/edit.ts`)

**Args Display:**
- Show file path
- Show search text (truncated)
- For multiedit: show edit count

**Result Display:**
- Show unified diff with colors:
  - Red (`-`) for removed lines
  - Green (`+`) for added lines
  - Context lines in muted color
- Show line numbers where changes occurred
- For multiedit: show summary of all edits

Example:
```
▶ edit: ./src/config.ts
  @@ -10,3 +10,4 @@
     const foo = 1;
  -  const bar = 2;
  +  const bar = 3;
  +  const baz = 4;
```

### 2.5 Patch Formatter (`formatters/patch.ts`)

**Args Display:**
- Show "Applying patch" with file count

**Result Display:**
- Show list of affected files with operation (Add/Modify/Delete)
- Show diff statistics (+/- line counts)

Example:
```
▶ patch: 3 files
  + src/new.ts (created, 45 lines)
  M src/existing.ts (+12 -5)
  - src/deleted.ts (removed)
```

### 2.6 Grep Formatter (`formatters/grep.ts`)

**Args Display:**
- Show pattern (highlighted)
- Show path/glob filter if specified

**Result Display:**
- Group matches by file
- Show line numbers and matching content
- Highlight the matching text
- Show match count per file

Example:
```
▶ grep: "TODO" in ./src/**/*.ts
  src/index.ts (3 matches)
    42│ // TODO: implement this
    89│ // TODO: add error handling
   156│ // TODO: optimize
  src/utils.ts (1 match)
    12│ // TODO: refactor
```

### 2.7 Find/Glob/Ls Formatters (`formatters/find.ts`)

**Find/Glob Args Display:**
- Show pattern
- Show search path

**Find/Glob Result Display:**
- Show file list with type indicators (📁 for dirs, 📄 for files)
- Group by directory if many results
- Show total count

**Ls Args Display:**
- Show path
- Show flags (-a, -l, etc.)

**Ls Result Display:**
- Format as directory listing
- Show file sizes and dates if -l
- Use column layout if space permits

Example (find):
```
▶ find: "*.test.ts" in ./src
  📄 src/utils.test.ts
  📄 src/api/auth.test.ts
  📄 src/api/users.test.ts
  (3 files)
```

### 2.8 Web Formatters (`formatters/web.ts`)

**WebFetch Args Display:**
- Show URL (truncated domain + path)
- Show format (text/markdown/html)

**WebFetch Result Display:**
- Show HTTP status
- Show content type and size
- Preview content (first few lines of text)

**WebSearch Args Display:**
- Show query

**WebSearch Result Display:**
- Show result count
- List results as: Title (domain)
- Truncate to top N results

Example (websearch):
```
▶ websearch: "elixir genserver tutorial"
  3 results:
  1. GenServer Basics - elixir-lang.org
  2. Understanding GenServers - medium.com
  3. Elixir GenServer Guide - hexdocs.pm
```

### 2.9 Todo Formatters (`formatters/todo.ts`)

**TodoRead Result Display:**
- Show todo list with checkboxes
- Group by status (pending/done)
- Show count

**TodoWrite Args Display:**
- Show action (add/update/remove)
- Show item count

Example:
```
▶ todoread
  ☐ Implement user authentication
  ☐ Add error handling
  ☑ Set up project structure
  (2 pending, 1 done)
```

### 2.10 Task Formatter (`formatters/task.ts`)

**Args Display:**
- Show action (run/poll/join)
- Show task description/prompt preview

**Result/Partial Display:**
- Show engine type
- Show current action with phase indicator
- Show nested tool activity
- For completed: show summary

Example:
```
▶ task: "Implement login feature"
  engine: coding_agent
  ▶ Analyzing codebase...
  └─ ▶ grep: "auth" in ./src
```

### 2.11 Process Formatter (`formatters/process.ts`)

**Args Display:**
- Show action and process_id

**Result Display:**
- For list: show process table (id, status, command)
- For poll/log: show recent output lines
- For status changes: show new status

Example:
```
▶ process: list
  ID     STATUS   COMMAND
  p_001  running  npm run dev
  p_002  exited   npm test
```

## Part 3: Integration with TUI

### 3.1 Update `index.ts`

Replace the existing `formatToolArgs` and `formatToolResult` methods:

```typescript
import { defaultRegistry } from './formatters/index.js';

private formatToolArgs(toolName: string, args: Record<string, unknown>): string {
  const output = defaultRegistry.formatArgs(toolName, args);
  return output.summary;
}

private formatToolResult(toolName: string, result: unknown, args?: Record<string, unknown>): string {
  const output = defaultRegistry.formatResult(toolName, result, args);
  // For tool panel, use multi-line details
  return output.details.join('\n');
}

private formatToolResultInline(toolName: string, result: unknown, args?: Record<string, unknown>): string {
  const output = defaultRegistry.formatResult(toolName, result, args);
  // For inline display, use summary
  return output.summary;
}
```

### 3.2 Update `updateToolPanel` Method

Modify to use the new formatters:

```typescript
private updateToolPanel(): void {
  // ... existing setup ...

  for (const tool of sorted) {
    // ... existing status icon logic ...

    // Use formatter for args
    const argsOutput = defaultRegistry.formatArgs(tool.name, tool.args);
    if (argsOutput.summary) {
      this.toolPanel.addChild(new Text(ansi.muted(`  ${argsOutput.summary}`), 1, 0));
    }

    // Use formatter for result
    const resultPayload = tool.result ?? tool.partialResult;
    if (resultPayload !== undefined) {
      const resultOutput = tool.result
        ? defaultRegistry.formatResult(tool.name, resultPayload, tool.args)
        : defaultRegistry.formatPartial?.(tool.name, resultPayload, tool.args)
          ?? defaultRegistry.formatResult(tool.name, resultPayload, tool.args);

      for (const line of resultOutput.details.slice(0, 6)) {
        this.toolPanel.addChild(new Text(ansi.secondary(`  ${line}`), 1, 0));
      }
      if (resultOutput.details.length > 6) {
        this.toolPanel.addChild(new Text(ansi.muted(`  ... (${resultOutput.details.length - 6} more lines)`), 1, 0));
      }
    }
  }
}
```

## Part 4: Testing

### 4.1 Unit Tests for Each Formatter

Create `formatters/*.test.ts` files with test cases:
- Test args formatting with various inputs
- Test result formatting with success/error cases
- Test truncation behavior
- Test edge cases (empty input, malformed data)

### 4.2 Integration Tests

- Test FormatterRegistry with all registered formatters
- Test fallback behavior for unknown tools
- Test ANSI color output

## Implementation Order

1. **Phase 1: Infrastructure** (Part 1)
   - Create `formatters/types.ts`
   - Create `formatters/base.ts` with utilities
   - Create `formatters/index.ts` with registry

2. **Phase 2: Core Formatters** (Part 2)
   - bash.ts (most commonly used)
   - read.ts (frequently used)
   - edit.ts (high-value improvement with diff display)
   - grep.ts (commonly used, benefits from highlighting)

3. **Phase 3: Remaining Formatters**
   - write.ts, patch.ts
   - find.ts (find, glob, ls)
   - web.ts (webfetch, websearch)
   - todo.ts, task.ts, process.ts

4. **Phase 4: Integration**
   - Update index.ts to use formatters
   - Update tool panel rendering
   - Add tests

## Dependencies

- No new npm dependencies required
- Uses existing ANSI color utilities from the codebase
- Uses existing truncation utilities (can be moved to base.ts)

## Success Criteria

- All 19 tools have dedicated formatters
- Tool output is human-readable at a glance
- Diffs are displayed with proper coloring
- Long outputs are truncated sensibly
- No regression in existing functionality
- Tests cover main formatting scenarios
