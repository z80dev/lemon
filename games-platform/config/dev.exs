import Config

# Persist Lemon state (including Telegram offsets) to disk in development.
# `LEMON_STORE_PATH` may be either a directory (store.sqlite3 is created inside)
# or a direct SQLite file path.
config :lemon_core, LemonCore.Store,
  backend: LemonCore.Store.SqliteBackend,
  backend_opts: [
    path: System.get_env("LEMON_STORE_PATH") || Path.expand("~/.lemon/store"),
    ephemeral_tables: [:runs]
  ]

# In dev, if no browser node is paired/online, allow browser.request to use the local driver.
config :lemon_control_plane, :browser_local_fallback, true

config :lemon_web, LemonWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4080],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base:
    "dev_secret_key_base_dev_secret_key_base_dev_secret_key_base_dev_secret_key_base",
  watchers: []

# Voice transport configuration - zeebot phone integration
config :lemon_gateway,
  voice_enabled: true,
  voice_websocket_port: 4047,
  voice_public_url: System.get_env("VOICE_PUBLIC_URL"),
  twilio_account_sid: System.get_env("TWILIO_ACCOUNT_SID"),
  twilio_auth_token: System.get_env("TWILIO_AUTH_TOKEN"),
  twilio_phone_number: System.get_env("TWILIO_PHONE_NUMBER"),
  deepgram_api_key: System.get_env("DEEPGRAM_API_KEY"),
  elevenlabs_api_key: System.get_env("ELEVENLABS_API_KEY"),
  elevenlabs_voice_id: System.get_env("ELEVENLABS_VOICE_ID") || "21m00Tcm4TlvDq8ikWAM",
  voice_llm_model: "gpt-4o-mini",
  voice_max_call_duration_seconds: 600,
  voice_silence_timeout_ms: 5000,
  openai_api_key: System.get_env("OPENAI_API_KEY")

# System prompt for voice conversations
config :lemon_gateway,
  voice_system_prompt: """
You are zeebot, a friendly AI assistant built on the Lemon framework. You're talking to someone on the phone.

Guidelines:
- Keep responses concise (1-3 sentences max) — this is a voice conversation
- Be warm, helpful, and occasionally witty
- If you need to perform actions, do so efficiently
- If you don't know something, say so honestly
- Remember: the user is listening, not reading

You can help with:
- Answering questions
- Performing tasks via tools
- Having casual conversation
- Crypto and Ethereum topics (you're crypto-native)

Your personality is: clever, compact, occasionally weird — like a "technical standup comedian who ships."
"""
