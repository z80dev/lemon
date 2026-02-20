# X API Adapter for Lemon Channels

Elixir adapter for X (Twitter) API v2 with OAuth 2.0 authentication.

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
# This will open a browser for authorization
LemonChannels.Adapters.XAPI.OAuth.initiate_flow()
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
config :lemon_channels, LemonChannels.Adapters.XAPI,
  client_id: System.get_env("X_API_CLIENT_ID"),
  client_secret: System.get_env("X_API_CLIENT_SECRET"),
  access_token: System.get_env("X_API_ACCESS_TOKEN"),
  refresh_token: System.get_env("X_API_REFRESH_TOKEN"),
  default_account_id: System.get_env("X_DEFAULT_ACCOUNT_ID"),
  default_account_username: System.get_env("X_DEFAULT_ACCOUNT_USERNAME")
```

### 5. Register the Adapter

In your application supervisor:

```elixir
children = [
  # ... other children
  LemonChannels.Adapters.XAPI
]
```

Or dynamically:

```elixir
LemonChannels.Registry.register(LemonChannels.Adapters.XAPI)
```

## Usage

### Post a Tweet

```elixir
payload = LemonChannels.OutboundPayload.text(
  "x_api",
  "your_bot_account",
  %{kind: :channel, id: "public", thread_id: nil},
  "Hello from Lemon! 🤖🍋"
)

LemonChannels.enqueue(payload)
```

### Reply to a Tweet

```elixir
LemonChannels.Adapters.XAPI.Client.reply("1234567890", "Thanks for reaching out!")
```

### Get Mentions

```elixir
LemonChannels.Adapters.XAPI.GatewayMethods.get_mentions(%{"limit" => 10})
```

### Via Gateway (for Agents)

```elixir
# Post tweet
LemonControlPlane.call("x_api.post_tweet", %{"text" => "Hello world"})

# Get mentions
LemonControlPlane.call("x_api.get_mentions", %{"limit" => 5})

# Reply
LemonControlPlane.call("x_api.reply_to_tweet", %{
  "tweet_id" => "1234567890",
  "text" => "My reply"
})
```

## Architecture

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────┐
│   Outbox        │────▶│   XAPI Adapter   │────▶│   X API     │
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

## TODO

- [ ] Media upload (images) support
- [ ] Poll creation
- [ ] Thread posting helper
- [ ] Webhook handling for mentions/DMs
- [ ] Metrics/usage tracking integration

## References

- [X API Documentation](https://docs.x.com/x-api)
- [OAuth 2.0 Guide](https://docs.x.com/x-api/authentication/oauth-2-0)
- [Rate Limits](https://docs.x.com/x-api/fundamentals/rate-limits)
- [Pay-per-use Pricing](https://docs.x.com/x-api/getting-started/pricing)
