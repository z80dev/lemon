# Lemon 1.0 Fresh Install Proof - 2026-05-11

This records the first 1.0 source-dev install proofs for the launch readiness
goal: one clean source tree copy on the maintainer machine with isolated Lemon,
Mix, and Hex state, and one clean Docker proof on the current supported
Elixir/OTP toolchain.

## Scope

- Source tree copied to `/tmp/lemon-fresh-install-smoke`.
- Excluded existing `_build/`, `deps/`, `node_modules/`, docs build output,
  and temp directories.
- Used isolated:
  - `HOME=/tmp/lemon-fresh-install-home`
  - `MIX_HOME=/tmp/lemon-fresh-install-mix`
  - `HEX_HOME=/tmp/lemon-fresh-install-hex`
- Used the host's already-installed Erlang/Elixir binaries:
  - Erlang/OTP 28.5, ERTS 16.4
  - Elixir 1.19.5

This host proof verifies source-install behavior on the maintainer machine at
the current supported launch pair: Elixir 1.19.5 and Erlang/OTP 28.5. The clean
container proof below verifies the same toolchain pair in an isolated OS image.

## Commands

```bash
mix local.hex --force
mix deps.get
mix compile
mix lemon.doctor --json --bundle --bundle-path tmp/fresh-install-doctor.zip
```

The first two attempts also proved a setup caveat: when using asdf-backed
Elixir, changing `HOME` can prevent the asdf shim from resolving the selected
Elixir/Erlang version. The successful run put concrete Erlang and Elixir install
directories first on `PATH`. Normal users do not need this if `elixir -v` and
`mix --version` already work in their shell.

## Result

- `mix deps.get` downloaded dependencies into the isolated Mix/Hex dirs.
- `mix compile` compiled all umbrella apps from scratch.
- `mix lemon.doctor --json --bundle` exited `0`.
- The doctor report had no failures:
  - pass: 6
  - warn: 2
  - skip: 4
  - fail: 0
- `tmp/fresh-install-doctor.zip` was created successfully.

Expected warnings/skips for an unconfigured fresh home:

- Global config is not present yet.
- Provider credentials are not configured yet.
- Control plane is not running yet.
- Skills directory is created on first install/use.

## Follow-Up

- Add a release-artifact install proof after the public artifact naming and
  support matrix are finalized.
- Keep `docs/user-guide/setup.md` aligned with real `mix lemon.setup` and
  `mix lemon.secrets.*` commands.

## Setup Command Proof

The non-interactive setup path was verified with isolated state so it did not
mutate the maintainer's real Lemon config:

```bash
HOME="$(mktemp -d)/home" \
MIX_HOME="$(mktemp -d)/mix_home" \
HEX_HOME="$(mktemp -d)/hex_home" \
LEMON_STORE_PATH="$(mktemp -d)/store" \
LEMON_SECRETS_MASTER_KEY="test-key-32-chars-exactly-here!!" \
mix lemon.setup --non-interactive --config-path /tmp/lemon-setup-proof/config.toml
```

Result:

- command exited `0`
- a minimal config was created at the requested `--config-path`
- provider setup and runtime configuration were explicitly skipped because the
  command was non-interactive
- setup printed the expected next steps for config validation, provider setup,
  runtime setup, and doctor

The runtime setup subcommand was also verified:

```bash
mix lemon.setup runtime \
  --profile runtime_min \
  --control-port 5050 \
  --web-port 5080 \
  --sim-port 5090 \
  --non-interactive
```

This initially exposed a launch-doc bug: the summary told users to run
`MIX_ENV=prod mix release runtime_min`, but the actual release profile is
`lemon_runtime_min`. The setup output was fixed and covered by
`apps/lemon_core/test/lemon_core/setup/setup_task_test.exs`; the verified output
now says:

```bash
MIX_ENV=prod mix release lemon_runtime_min
```

The provider setup subcommand was verified with isolated state and fake API
tokens, so no live provider call was made:

```bash
mix lemon.setup provider anthropic \
  --token anthropic-token-123 \
  --config-path /tmp/lemon-provider-proof/anthropic.toml \
  --set-default \
  --model claude-sonnet-4-20250514

mix lemon.setup provider openai \
  --token openai-token-123 \
  --config-path /tmp/lemon-provider-proof/openai.toml \
  --set-default \
  --model gpt-5
```

Result:

- Anthropic onboarding exited `0`, wrote `api_key_secret =
  "llm_anthropic_api_key_raw"`, and set default model
  `anthropic:claude-sonnet-4-20250514`.
- OpenAI onboarding exited `0`, wrote `api_key_secret =
  "llm_openai_api_key"`, and set default model `openai:gpt-5`.
- Both checks used isolated `HOME`, `MIX_HOME`, `HEX_HOME`,
  `LEMON_STORE_PATH`, and `LEMON_SECRETS_MASTER_KEY`.
- The asdf/mise caveat above still applies when overriding `HOME`; the verified
  provider run put concrete Erlang and Elixir install directories first on
  `PATH`.

## Clean Container Proof

After updating the supported toolchain to Elixir 1.19.5 and Erlang/OTP 28.5,
the same source-install path was rerun in Docker:

- Image: `elixir:1.19.5-otp-28`
- Reported runtime:
  - Erlang/OTP 28.5, ERTS 16.4
  - Elixir 1.19.5, compiled with Erlang/OTP 28
- Source tree copied to `/tmp/lemon-toolchain-proof-src`.
- Excluded existing `_build/`, `deps/`, `node_modules/`, docs build output,
  temp directories, git data, and worktrees.
- Used isolated:
  - `HOME=/tmp/lemon-toolchain-proof-home`
  - `MIX_HOME=/tmp/lemon-toolchain-proof-mix`
  - `HEX_HOME=/tmp/lemon-toolchain-proof-hex`
  - `LEMON_STORE_PATH=/tmp/lemon-toolchain-proof-store`

Commands:

```bash
mix local.hex --force
mix deps.get
mix compile
mix lemon.doctor --json --bundle --bundle-path tmp/toolchain-doctor.zip
```

Result:

- `mix deps.get` downloaded dependencies into the isolated Mix/Hex dirs.
- `mix compile` compiled all umbrella apps from scratch.
- `mix lemon.doctor --json --bundle` exited `0`.
- The doctor report had no failures:
  - pass: 3
  - warn: 5
  - skip: 4
  - fail: 0
- `tmp/toolchain-doctor.zip` was created successfully.

Expected warnings/skips for the minimal container:

- Global config is not present yet.
- Provider credentials are not configured yet.
- Control plane is not running yet.
- Skills directory is created on first install/use.
- The container does not include Node/npm, so TUI/Web client tooling is reported
  unavailable.
- The container does not include `inotify-tools`, so config watching falls back
  to polling.
