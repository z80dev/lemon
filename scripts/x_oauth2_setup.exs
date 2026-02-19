#!/usr/bin/env elixir
# OAuth 2.0 Setup Script for X API
#
# This script helps you complete the OAuth 2.0 flow to get access/refresh tokens.
#
# Prerequisites:
#   1. Set up a callback URL in X Developer Portal (can be http://localhost:4000/auth/x/callback)
#   2. Have your Client ID and Client Secret ready
#
# Usage:
#   export X_API_CLIENT_ID="RHozTWdxcjZoQ3E0em5JU0xYQTI6MTpjaQ"
#   export X_API_CLIENT_SECRET="IxhBE1Ssz5ADc9aPEL_j4i5BrNCBF5IufWjy5Mz_sNKb7_siku"
#   mix run scripts/x_oauth2_setup.exs

IO.puts("🐦 X API OAuth 2.0 Setup")
IO.puts("=" |> String.duplicate(50))

client_id = System.get_env("X_API_CLIENT_ID")
client_secret = System.get_env("X_API_CLIENT_SECRET")

unless client_id && client_secret do
  IO.puts("""
  ❌ Missing credentials!

  Please set:
    export X_API_CLIENT_ID="your-client-id"
    export X_API_CLIENT_SECRET="your-client-secret"

  Your Client ID is: RHozTWdxcjZoQ3E0em5JU0xYQTI6MTpjaQ
  """)
  System.halt(1)
end

IO.puts("""
📋 OAuth 2.0 Flow Steps:

1. First, you need to set a callback URL in the X Developer Portal:
   - Go to https://developer.x.com → Your Project → Your App → User authentication settings
   - Set Callback URI to: http://localhost:4000/auth/x/callback
   - Save changes

2. Visit this authorization URL in your browser:

   https://twitter.com/i/oauth2/authorize?response_type=code&client_id=#{URI.encode_www_form(client_id)}&redirect_uri=http%3A%2F%2Flocalhost%3A4000%2Fauth%2Fx%2Fcallback&scope=tweet.read%20tweet.write%20users.read%20offline.access&state=setup#{:rand.uniform(10000)}&code_challenge=challenge&code_challenge_method=plain

3. Authorize the app

4. You'll be redirected to localhost (it will show an error page - that's OK!)

5. Copy the 'code' parameter from the URL in your browser's address bar

6. Run this curl command to exchange the code for tokens:

   curl -X POST https://api.x.com/2/oauth2/token \\
     -H "Content-Type: application/x-www-form-urlencoded" \\
     -u "#{client_id}:#{client_secret}" \\
     -d "grant_type=authorization_code" \\
     -d "code=PASTE_CODE_HERE" \\
     -d "redirect_uri=http://localhost:4000/auth/x/callback" \\
     -d "code_verifier=challenge"

7. Save the refresh_token from the response!

""")

IO.puts("✅ Instructions printed above!")
