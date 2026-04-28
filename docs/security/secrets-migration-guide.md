# Secrets Migration Guide

This guide helps you migrate from environment variable-based secrets to Lemon's encrypted secrets store.

## Why Migrate?

The encrypted secrets store provides:

- **Encryption at rest** - Secrets are encrypted with AES-256-GCM
- **No shell history leakage** - Secrets aren't in your shell history like `export` commands
- **No process environment exposure** - Secrets aren't visible in `/proc/<pid>/environ`
- **Keychain integration** - Master key can be stored in macOS Keychain
- **Fine-grained access** - Per-secret access control and audit logging

## Quick Migration

### 1. Check Your Current Secrets

See which secrets are currently resolved from environment vs the encrypted store:

```bash
mix lemon.secrets.check
```

Example output:

```
NAME                      SOURCE   VALUE
--------------------------------------------------
ANTHROPIC_API_KEY         env      sk-an...t-abc1
OPENAI_API_KEY            store    sk-...-xyz9
GITHUB_TOKEN              missing  ---

1 from store, 1 from env, 1 missing
```

### 2. Import Environment Secrets

Import all secrets that are currently set in your environment:

```bash
# Preview what would be imported (dry run)
mix lemon.secrets.import_env --dry-run

# Actually import (skips secrets already in store)
mix lemon.secrets.import_env

# Force import even if already in store
mix lemon.secrets.import_env --force
```

### 3. Verify Migration

Run the check again to confirm secrets are now in the store:

```bash
mix lemon.secrets.check
```

### 4. Clean Up Environment

Once you've verified everything works, remove secrets from your environment:

```bash
# Remove from shell profile (e.g., ~/.zshrc, ~/.bashrc)
unset ANTHROPIC_API_KEY
unset OPENAI_API_KEY
# etc.
```

## Manual Migration

If you prefer to migrate secrets one at a time:

```bash
# Set a secret manually
mix lemon.secrets.set ANTHROPIC_API_KEY "sk-ant-..."

# Verify it was stored
mix lemon.secrets.list

# Test resolution
mix lemon.secrets.check
```

## Supported Secret Names

The following secrets are recognized by the migration tooling:

### AI Providers
- `ANTHROPIC_API_KEY` - Anthropic Claude API
- `OPENAI_API_KEY` - OpenAI API
- `OPENAI_CODEX_API_KEY` - OpenAI Codex
- `CHATGPT_TOKEN` - ChatGPT OAuth
- `GOOGLE_GENERATIVE_AI_API_KEY` / `GOOGLE_API_KEY` / `GEMINI_API_KEY` - Google AI
- `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` - AWS Bedrock
- `AZURE_OPENAI_API_KEY` - Azure OpenAI
- `GROQ_API_KEY`, `MISTRAL_API_KEY`, `XAI_API_KEY`, `CEREBRAS_API_KEY`
- `KIMI_API_KEY`, `MOONSHOT_API_KEY`, `OPENCODE_API_KEY`

### Coding Agent Tools
- `PERPLEXITY_API_KEY` - Perplexity search
- `OPENROUTER_API_KEY` - OpenRouter API
- `FIRECRAWL_API_KEY` - Firecrawl web scraping
- `BRAVE_API_KEY` - Brave Search API
- `GITHUB_TOKEN` - GitHub API access

### X/Twitter API
- `X_API_CLIENT_ID`, `X_API_CLIENT_SECRET` - OAuth 2.0
- `X_API_BEARER_TOKEN` - App auth
- `X_API_ACCESS_TOKEN`, `X_API_REFRESH_TOKEN` - User auth
- `X_API_CONSUMER_KEY`, `X_API_CONSUMER_SECRET` - OAuth 1.0a
- `X_API_ACCESS_TOKEN_SECRET` - OAuth 1.0a

## Troubleshooting

### Secret not found after migration

If a secret resolves as `:missing` after migration:

1. Check the exact name matches (case-sensitive)
2. Verify the secret was actually imported: `mix lemon.secrets.list`
3. Check for typos in the secret name

### Import fails with "missing_master_key"

Initialize the secrets store first:

```bash
mix lemon.secrets.init
```

### Backward compatibility

If you need to temporarily fall back to environment variables:

```bash
# Secrets store will be skipped, env vars used directly
LEMON_SECRETS_MASTER_KEY=invalid mix lemon.secrets.check
```

Or disable secrets store in config:

```toml
[secrets]
use_store = false
```

## Verification

After migration, verify everything works:

```bash
# Run the full test suite
mix test

# Check specific provider connectivity
mix lemon.config --show-secrets-source
```

## Security Best Practices

1. **Never commit secrets** - The encrypted store keeps secrets out of your codebase
2. **Rotate imported secrets** - After migration, consider rotating API keys
3. **Use expiration** - Set expiration dates for temporary credentials:
   ```bash
   mix lemon.secrets.set TEMP_KEY "value" --expires-at 1735689600000
   ```
4. **Audit access** - Check which secrets are being used:
   ```bash
   mix lemon.secrets.list --with-usage
   ```

## See Also

- [`docs/security/secrets-keychain-audit-matrix.md`](secrets-keychain-audit-matrix.md) - Detailed security audit
- `mix help lemon.secrets.init` - Initialize secrets store
- `mix help lemon.secrets.set` - Store a secret
- `mix help lemon.secrets.check` - Check secret sources
- `mix help lemon.secrets.import_env` - Bulk import from environment
