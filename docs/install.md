# Install Lemon

Last reviewed: 2026-05-12

This page is the short install landing page for the public docs site. For the
full setup walkthrough, including provider details and Telegram configuration,
use the [Setup Guide](user-guide/setup.md).

## Supported Path Today

The verified path today is a source install on a developer machine with Elixir,
Erlang/OTP, and a model provider key.

Requirements:

- Elixir 1.19.5+
- Erlang/OTP 28.5+
- Node.js 24 LTS+ if you want TUI or web client work
- An Anthropic, OpenAI, or compatible provider credential

```bash
git clone https://github.com/z80dev/lemon.git
cd lemon
mix local.hex --force
mix deps.get
mix compile
mix lemon.setup
mix lemon.doctor
```

Start Lemon locally:

```bash
./bin/lemon-dev /path/to/your/project
```

## Configure One Provider

Use the setup wizard when possible:

```bash
mix lemon.setup provider
```

For manual setup, create `~/.lemon/config.toml` and reference secrets by name:

```toml
[providers.anthropic]
api_key_secret = "llm_anthropic_api_key_raw"

[defaults]
provider = "anthropic"
model    = "anthropic:claude-sonnet-4-20250514"
engine   = "lemon"
```

Store the secret:

```bash
mix lemon.secrets.set llm_anthropic_api_key_raw "sk-ant-..."
```

## Verify the Install

Run doctor after setup:

```bash
mix lemon.doctor
```

Generate a redacted support bundle if you need help:

```bash
mix lemon.doctor --bundle
```

The bundle is designed to exclude provider keys, tokens, passwords, private
prompts, memory contents, and tool outputs. Review it before sharing.

## Release Artifacts

Linux release profiles exist in the repository build system, but public 1.0
release artifact installation is not the primary supported path yet. The launch
ledger tracks this under [Lemon 1.0 Mainstream Readiness](plans/lemon-1.0-mainstream-readiness.md).

Stable 1.0 is scoped to source install plus Linux `x86_64` release tarballs. A
one-line remote install script is not part of the initial support promise; add
one only after it has the same artifact verification, rollback, and support
bundle coverage as the tarball path.

Current release profiles:

- `lemon_runtime_min`
- `lemon_runtime_full`

Build locally:

```bash
MIX_ENV=prod mix release lemon_runtime_full
```

## Next Pages

| Next step | Page |
| --- | --- |
| Full setup details | [Setup Guide](user-guide/setup.md) |
| Configuration reference | [Config Reference](config.md) |
| Runtime and release behavior | [Versioning and Channels](release/versioning_and_channels.md) |
| Troubleshooting and quality gates | [Testing](testing.md) |
