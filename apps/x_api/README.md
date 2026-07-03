# X API Client

Reusable Elixir client for X (Twitter) API v2 with OAuth 2.0 and OAuth 1.0a authentication.

## Features

- **OAuth 2.0 with auto-refresh**: Tokens automatically refresh before expiry
- **Pay-per-use pricing**: Only pay for what you use
- **Rate limit handling**: Exponential backoff on 429 errors
- **Tweet operations**: Post, reply, delete, get mentions
- **BEAM-native**: Built for fault-tolerance and concurrency

## Setup

### 1. X Developer Account

1. Go to https://developer.x.com
2. Create a new Project
3. Create an App within the project
4. Enable OAuth 2.0 (User authentication settings)
5. Set callback URL to your OAuth callback endpoint
6. Generate Client ID and Client Secret

### 2. OAuth Flow (One-time)

Run the OAuth flow to get initial tokens:

```elixir
# This will print setup instructions and the authorization URL
XApi.OAuth.print_setup_instructions()
```

Or manually:

1. Visit: `https://twitter.com/i/oauth2/authorize?...`
2. Authorize the app
3. Exchange code for tokens
4. Save the refresh token securely

### 3. Environment Variables

Add to your `.env` or runtime config:

```bash
# Required
export X_API_CLIENT_ID="your-client-id"
export X_API_CLIENT_SECRET="your-client-secret"
export X_API_ACCESS_TOKEN="initial-access-token"
export X_API_REFRESH_TOKEN="your-refresh-token"

# Optional
export X_API_BEARER_TOKEN="app-bearer-token"  # For some read operations
export X_DEFAULT_ACCOUNT_ID="your_account_id"   # Default posting account ID or username
export X_DEFAULT_ACCOUNT_USERNAME="your_handle" # Optional explicit account handle
```

### 4. Runtime Config

In `config/runtime.exs`:

```elixir
config :x_api, XApi,
  client_id: System.get_env("X_API_CLIENT_ID"),
  client_secret: System.get_env("X_API_CLIENT_SECRET"),
  access_token: System.get_env("X_API_ACCESS_TOKEN"),
  refresh_token: System.get_env("X_API_REFRESH_TOKEN"),
  default_account_id: System.get_env("X_DEFAULT_ACCOUNT_ID"),
  default_account_username: System.get_env("X_DEFAULT_ACCOUNT_USERNAME")
```

Existing `config :lemon_channels, LemonChannels.Adapters.XAPI` settings remain supported as a compatibility fallback.

## Usage

### Post a Tweet

```elixir
XApi.Client.post_text("Hello from Lemon!")
```

### Reply to a Tweet

```elixir
XApi.Client.reply("1234567890", "Thanks for reaching out!")
```

### Get Mentions

```elixir
XApi.Client.get_mentions(limit: 10)
```

## Architecture

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────┐
│   Callers       │────▶│   XApi.Client    │────▶│   X API     │
│                 │     │                  │     │   (Twitter) │
└─────────────────┘     ├──────────────────┤     └─────────────┘
                        │  TokenManager    │            ▲
                        │  (auto-refresh)  │            │
                        └──────────────────┘            │
                               │                        │
                               ▼                        │
                        ┌──────────────────┐            │
                        │  Config/Secrets  │────────────┘
                        └──────────────────┘
```

## Rate Limits

- **Posting**: 2,400 tweets per day (resets every 24 hours)
- **Reading**: Varies by endpoint
- **Pay-per-use**: Credits deducted per API request

## Cost Estimation

Based on X's pay-per-use pricing:

| Usage Level | Tweets/Day | Est. Monthly Cost |
|-------------|-----------|-------------------|
| Low         | 5-10      | $5-15             |
| Medium      | 20-30     | $20-40            |
| High        | 50+       | $50-100+          |

Much cheaper than the $200/mo Basic plan for low-volume bots.

## Automated Account Label

To show "Automated" badge on your profile:

1. Go to X Settings → Your account → Account info → Automation
2. Select "Managing account"
3. Choose your main account (@0xz80)
4. Confirm with password

This builds trust by showing who runs the bot.

## Troubleshooting

### Token Refresh Failing

Check that `X_API_REFRESH_TOKEN` is set and valid. Refresh tokens can expire if unused for 6+ months.

### Rate Limited

The client automatically retries with exponential backoff. If consistently hitting limits, consider:
- Reducing post frequency
- Upgrading to higher rate limits
- Using the Basic plan ($200/mo) for higher quotas

### Authentication Errors

Ensure your app has "Read and Write" permissions enabled in the X Developer Portal.

## Backlog

Tracked items with owners and target phases. Each item should be
linked to a GitHub issue when work begins.

| Item | Owner | Target Phase | Status | Notes |
|------|-------|-------------|--------|-------|
| Poll creation | @platform-team | Phase 15 | Planned | Low priority; X API v2 polls require elevated access |
| Thread posting helper | @platform-team | Phase 12 | Planned | Build on existing `Client.reply/2`; auto-split long text into threads |
| Webhook handling for mentions/DMs | @platform-team | Phase 12 | Planned | Needed for real-time inbound; currently relies on polling via `get_mentions` |
| Metrics/usage tracking integration | @platform-team | Phase 14 | Planned | Track API credit usage, rate limit headroom, post engagement |

## References

- [X API Documentation](https://docs.x.com/x-api)
- [OAuth 2.0 Guide](https://docs.x.com/x-api/authentication/oauth-2-0)
- [Rate Limits](https://docs.x.com/x-api/fundamentals/rate-limits)
- [Pay-per-use Pricing](https://docs.x.com/x-api/getting-started/pricing)
