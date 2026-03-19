# Setup Guide

Full walkthrough for getting Lemon running on your machine.

---

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| Elixir | 1.19+ | See below for install |
| Erlang/OTP | 27+ | Bundled with asdf/Elixir install |
| Node.js | 20+ | TUI and Web clients only |
| Python | 3.10+ | Debug CLI only (optional) |
| Rust/Cargo | stable | WASM tool auto-build (optional) |

### Installing Elixir

**macOS (Homebrew):**

```bash
brew install elixir
elixir -v
```

**Linux (recommended — asdf for consistent versions):**

```bash
# Install asdf, then:
asdf plugin add erlang
asdf plugin add elixir
asdf install erlang 27.2
asdf install elixir 1.19.0-otp-27
asdf global erlang 27.2
asdf global elixir 1.19.0-otp-27
elixir -v
```

<details>
<summary>Linux OS packages (faster, version varies)</summary>

**Arch Linux:**
```bash
sudo pacman -S elixir erlang
```

**Ubuntu/Debian:**
```bash
sudo apt-get install -y elixir erlang
```

**Fedora:**
```bash
sudo dnf install -y elixir erlang
```
</details>

**Node.js (TUI/Web clients only):**
```bash
# macOS
brew install node@20
# Linux (nvm)
nvm install 20
```

---

## Clone and Build

```bash
git clone https://github.com/z80dev/lemon.git
cd lemon
mix deps.get
mix compile
```

**Optional — build the TUI client:**
```bash
cd clients/lemon-tui
npm install
npm run build
cd ../..
```

---

## Automated Setup

`mix lemon.setup` walks through the full setup interactively:

```bash
mix lemon.setup
```

Runs: dependency check → config scaffolding → secrets setup → gateway config → health check.

Individual sub-commands:

```bash
mix lemon.setup config      # Scaffold ~/.lemon/config.toml
mix lemon.setup secrets     # Configure encrypted secrets keychain
mix lemon.setup gateway     # Configure Telegram/Discord gateway adapters
```

---

## Configuration

Create `~/.lemon/config.toml` (or run `mix lemon.setup config`):

```toml
# Provider keys (pick one or more)
[providers.anthropic]
api_key_secret = "llm_anthropic_api_key"

[providers.openai]
api_key_secret = "llm_openai_api_key"

# Other API-key onboarding targets include:
# [providers.zai]
# api_key_secret = "llm_zai_api_key"
#
# [providers.minimax]
# api_key_secret = "llm_minimax_api_key"

# Runtime defaults
[defaults]
provider = "anthropic"
model    = "anthropic:claude-sonnet-4-20250514"
engine   = "lemon"

# Telegram gateway
[gateway]
enable_telegram = true
auto_resume     = true
default_engine  = "lemon"
default_cwd     = "~/"

[gateway.telegram]
bot_token        = "123456:your-bot-token"
allowed_chat_ids = [123456789]
deny_unbound_chats = true

[[gateway.bindings]]
transport = "telegram"
chat_id   = 123456789
agent_id  = "default"

# Default assistant profile
[profiles.default]
name          = "Lemon"
system_prompt = "You are my general assistant."

[profiles.default.tool_policy]
allow            = "all"
deny             = []
require_approval = ["bash", "write", "edit"]
```

See [`docs/config.md`](../config.md) for the full configuration reference.

---

## Telegram Setup

### 1. Create a bot token

1. Message `@BotFather` in Telegram
2. Run `/newbot` and follow the prompts
3. Copy the bot token

### 2. Find your chat ID

Send any message to your bot, then fetch updates:

```bash
export TOKEN="123456:your-bot-token"
curl -s "https://api.telegram.org/bot${TOKEN}/getUpdates" | python3 -m json.tool
```

Look for `message.chat.id`.

### 3. Update config

Set `gateway.telegram.bot_token` and `allowed_chat_ids` in `~/.lemon/config.toml`.

---

## Running Lemon

### Telegram gateway

```bash
./bin/lemon-gateway
```

Prints the distributed node name on boot. Use it to attach a remote shell:

```bash
./bin/lemon-gateway-remsh
```

### Development / TUI

```bash
# Starts Elixir backend + TUI
./bin/lemon-dev /path/to/your/project

# Custom model
./bin/lemon-dev /path/to/project --model anthropic:claude-sonnet-4-20250514

# Local model via OpenAI-compat API
./bin/lemon-dev /path --model openai:llama3.1:8b --base-url http://localhost:11434/v1
```

---

## Health Check

After setup, verify everything is working:

```bash
mix lemon.doctor
```

Checks: config file, secrets, provider connectivity, gateway adapter, runtime deps.

Fix individual issues:

```bash
mix lemon.doctor --fix
```

---

## Secrets Store

API keys are stored in an encrypted keychain, not in `config.toml` in plaintext.

```bash
# Write a secret
mix lemon.setup secrets set llm_anthropic_api_key "sk-ant-..."

# List stored secrets
mix lemon.setup secrets list
```

Config references secrets by name via `api_key_secret = "key_name"`.

---

## Next Steps

| Topic | Where to look |
|---|---|
| Using skills | [`docs/user-guide/skills.md`](skills.md) |
| Memory & search | [`docs/user-guide/memory.md`](memory.md) |
| Adaptive routing | [`docs/user-guide/adaptive.md`](adaptive.md) |
| Full config reference | [`docs/config.md`](../config.md) |
| Architecture | [`docs/architecture/overview.md`](../architecture/overview.md) |

*Last reviewed: 2026-03-16*
