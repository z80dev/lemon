# debug_cli

Minimal REPL for `coding_agent` that prints all agent events.

Run with uv from the repo root:

```
uv run python tools/debug_cli/debug_cli.py --cwd . --model provider:model_id --base-url https://api.anthropic.com
```

If you have a default model configured in `~/.lemon/agent/settings.json`, you can omit `--model`.

Example settings:

```
{
  "provider": "anthropic",
  "model": "claude-sonnet-4-20250514",
  "providers": {
    "anthropic": {
      "apiKey": "sk-ant-...",
      "baseUrl": "https://api.anthropic.com"
    }
  }
}
```

Type a prompt and press enter. Use `:quit` to exit.

Useful commands:

```
:ping   # check input/output wiring
:stats  # print session stats
```

Enable verbose Elixir-side logging:

```
uv run python tools/debug_cli/debug_cli.py --cwd . --debug
```
