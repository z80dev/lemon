defmodule LemonSimUi.PhilosopherChat.Auth do
  @moduledoc """
  Password login and signed bearer tokens for the PhilosopherChat API.

  The password lives in `:lemon_sim_ui, :philosopher_chat_password`
  (env `LEMON_PHILOSOPHER_CHAT_PASSWORD`). Tokens are Phoenix tokens signed
  with the endpoint's `secret_key_base`, valid for 30 days.

  Dev convenience: when no password is configured and the env is not prod,
  `login/1` succeeds with a fixed `"dev-token"` and `verify/1` accepts it,
  so local development stays passwordless.
  """

  @salt "philosopher_chat_session"
  @max_age_seconds 2_592_000
  @dev_token "dev-token"
  @stream_salt "philosopher_chat_stream"
  @stream_max_age_seconds 60
  @login_bucket_table :philosopher_chat_login_buckets
  @login_max_attempts 5
  @login_window_ms 15 * 60 * 1_000

  # Compile-time: :mix is not loaded in releases, so Mix.env() cannot be
  # called at request time.
  @env Mix.env()

  @doc "True when a non-empty password is configured."
  @spec configured?() :: boolean()
  def configured? do
    case Application.get_env(:lemon_sim_ui, :philosopher_chat_password) do
      password when is_binary(password) -> String.trim(password) != ""
      _ -> false
    end
  end

  @doc """
  True when requests may pass without a token: no password configured and
  the app was not compiled for prod.
  """
  @spec dev_bypass?() :: boolean()
  def dev_bypass?, do: not configured?() and @env != :prod

  @doc "Exchanges the configured password for a signed bearer token."
  @spec login(term()) :: {:ok, String.t()} | {:error, :unauthorized}
  def login(password) do
    cond do
      dev_bypass?() ->
        {:ok, @dev_token}

      is_binary(password) and secure_equal?(password, configured_password()) ->
        {:ok, Phoenix.Token.sign(secret_key_base(), @salt, "user")}

      true ->
        {:error, :unauthorized}
    end
  end

  @doc "Verifies a bearer token, returning the user id on success."
  @spec verify(term()) :: {:ok, String.t()} | {:error, term()}
  def verify(@dev_token) do
    if dev_bypass?() do
      {:ok, "user"}
    else
      {:error, :invalid}
    end
  end

  def verify(token) when is_binary(token) do
    Phoenix.Token.verify(secret_key_base(), @salt, token, max_age: @max_age_seconds)
  end

  def verify(_token), do: {:error, :invalid}

  @doc "Seconds a token stays valid (30 days)."
  @spec max_age_seconds() :: pos_integer()
  def max_age_seconds, do: @max_age_seconds

  # -- stream tickets --

  @doc """
  Issues a short-lived ticket for the SSE stream.

  `EventSource` cannot set headers, so the browser exchanges its bearer
  token (via `POST /api/chat/stream-ticket`) for this ticket and passes it
  as `?ticket=` — keeping the long-lived bearer token out of URLs and logs.
  """
  @spec issue_stream_ticket() :: String.t()
  def issue_stream_ticket do
    Phoenix.Token.sign(secret_key_base(), @stream_salt, "user")
  end

  @doc "Verifies a stream ticket (max age #{@stream_max_age_seconds}s)."
  @spec verify_stream_ticket(term()) :: {:ok, String.t()} | {:error, term()}
  def verify_stream_ticket(ticket) when is_binary(ticket) do
    Phoenix.Token.verify(secret_key_base(), @stream_salt, ticket,
      max_age: @stream_max_age_seconds
    )
  end

  def verify_stream_ticket(_ticket), do: {:error, :invalid}

  # -- login rate limiting --

  @doc """
  Records a login attempt for `remote_ip`.

  Returns `{:error, :rate_limited}` once more than #{@login_max_attempts}
  attempts happened within a #{div(@login_window_ms, 60_000)}-minute window.
  Successful logins call `reset_login_attempts/1`, which clears the bucket.
  """
  @spec record_login_attempt(tuple()) :: :ok | {:error, :rate_limited}
  def record_login_attempt(remote_ip) do
    create_login_bucket_table()
    now = System.system_time(:millisecond)

    case :ets.lookup(@login_bucket_table, remote_ip) do
      [{^remote_ip, window_start, count}] when now - window_start < @login_window_ms ->
        if count + 1 > @login_max_attempts do
          {:error, :rate_limited}
        else
          :ets.insert(@login_bucket_table, {remote_ip, window_start, count + 1})
          :ok
        end

      _ ->
        :ets.insert(@login_bucket_table, {remote_ip, now, 1})
        :ok
    end
  end

  @doc "Clears the login-attempt bucket for `remote_ip` (on successful login)."
  @spec reset_login_attempts(tuple()) :: :ok
  def reset_login_attempts(remote_ip) do
    create_login_bucket_table()
    :ets.delete(@login_bucket_table, remote_ip)
    :ok
  end

  @doc """
  Creates the login rate-limit ETS table.

  Called by `LemonSimUi.PhilosopherChat.Supervisor` at boot so the table is
  owned by a long-lived process; also invoked lazily by the rate-limit
  functions as a fallback (tests that don't boot the supervision tree).
  """
  @spec create_login_bucket_table() :: :ok
  def create_login_bucket_table do
    case :ets.whereis(@login_bucket_table) do
      :undefined ->
        # Race-safe: a concurrent creator makes :ets.new raise ArgumentError.
        try do
          :ets.new(@login_bucket_table, [:set, :public, :named_table, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

        :ok

      _tid ->
        :ok
    end
  end

  defp configured_password do
    Application.get_env(:lemon_sim_ui, :philosopher_chat_password)
  end

  defp secret_key_base do
    :lemon_sim_ui
    |> Application.fetch_env!(LemonSimUi.Endpoint)
    |> Keyword.fetch!(:secret_key_base)
  end

  # Comparing SHA-256 digests avoids the length pre-check leaking the
  # configured password's length (and keeps secure_compare constant-time
  # regardless of input size).
  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) do
    Plug.Crypto.secure_compare(:crypto.hash(:sha256, left), :crypto.hash(:sha256, right))
  end

  defp secure_equal?(_left, _right), do: false
end
