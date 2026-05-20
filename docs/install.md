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
./bin/lemon setup
./bin/lemon channels
./bin/lemon config validate
./bin/lemon doctor
./bin/lemon media --limit 5
./bin/lemon models --provider anthropic
./bin/lemon providers --provider openai
./bin/lemon policy list
./bin/lemon proofs --limit 5
./bin/lemon readiness --limit 5
./bin/lemon secrets status
./bin/lemon skill list
./bin/lemon usage
```

Start Lemon locally:

```bash
./bin/lemon-dev /path/to/your/project
```

If you want a repeatable local proof of the source path after building, run:

```bash
scripts/verify_source_install --skip-compile
```

Without `--skip-compile`, the verifier also runs `MIX_ENV=test mix compile --warnings-as-errors`.
It checks the BEAM toolchain, locked dependency resolution, non-interactive
setup dispatch, promoted Telegram/Discord channel readiness, stage-1 local
update dry-run dispatch, doctor JSON diagnostics, model catalog listing,
provider readiness listing, model policy listing, redacted proof artifact
listing, media diagnostics, readiness summary, secrets status, skill listing,
usage diagnostics, plus redacted support-bundle generation.

For source-checkout maintenance outside the verifier:

```bash
./bin/lemon update --check
```

This delegates to `mix lemon.update --check`. It is a local maintenance check,
not a remote binary updater.

For route-specific model defaults, use the source wrapper:

```bash
./bin/lemon models --provider anthropic
./bin/lemon providers --provider openai
./bin/lemon policy list
./bin/lemon proofs --limit 5
./bin/lemon media --limit 5
./bin/lemon readiness --limit 5
./bin/lemon channels
./bin/lemon secrets status
./bin/lemon skill list
./bin/lemon usage
./bin/lemon policy set telegram --account default --model anthropic:claude-sonnet-4-20250514
```

Use `./bin/lemon readiness --strict` when a script should fail unless all compact
launch-readiness gates are ready.

## Configure One Provider

Use the setup wizard when possible:

```bash
./bin/lemon setup provider
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
./bin/lemon secrets set llm_anthropic_api_key_raw "sk-ant-..."
```

## Verify the Install

Run doctor after setup:

```bash
./bin/lemon doctor
```

Generate a redacted support bundle if you need help:

```bash
./bin/lemon doctor --bundle
```

The bundle is designed to exclude provider keys, tokens, passwords, private
prompts, memory contents, and tool outputs. Review it before sharing.

For release-candidate source installs, use the full source verifier:

```bash
scripts/verify_source_install
```

## Release Artifacts

Linux release profiles exist in the repository build system, but source install
remains the primary supported path today. The product ledger tracks artifact and
setup proof under [Hermes-on-BEAM Readiness](plans/lemon-1.0-mainstream-readiness.md).

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
