defmodule LemonChannels.Adapters.XAPI.TokenManager do
  @moduledoc """
  Manages OAuth 2.0 tokens for X API.

  Handles:
  - Token storage and retrieval
  - Automatic refresh before expiry
  - Token rotation on refresh

  Persists refreshed tokens to runtime config/env and Lemon secrets store
  (when available) so token rotation survives restarts.
  """

  use GenServer

  require Logger

  # Refresh 5 minutes before expiry
  @refresh_buffer_seconds 300
  @default_expires_in 7200
  @default_refresh_retry_ms 60_000
  @invalid_refresh_retry_ms 15 * 60_000
  @x_api_app LemonChannels.Adapters.XAPI
  @name __MODULE__
  @x_api_token_keys [
    access_token: "X_API_ACCESS_TOKEN",
    refresh_token: "X_API_REFRESH_TOKEN",
    token_expires_at: "X_API_TOKEN_EXPIRES_AT"
  ]

  # Token structure
  defstruct [
    :access_token,
    :refresh_token,
    :expires_at,
    :token_type,
    :secrets_module,
    :persist_secrets?
  ]

  @type t :: %__MODULE__{
          access_token: binary() | nil,
          refresh_token: binary() | nil,
          expires_at: DateTime.t() | nil,
          token_type: binary(),
          secrets_module: module(),
          persist_secrets?: boolean()
        }

  ## Client API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Get the current valid access token.
  Automatically refreshes if expired or about to expire.
  """
  def get_access_token do
    get_access_token(@name)
  end

  def get_access_token(server) do
    GenServer.call(server, :get_access_token)
  end

  @doc """
  Get the full token state.
  """
  def get_state do
    get_state(@name)
  end

  def get_state(server) do
    GenServer.call(server, :get_state)
  end

  @doc """
  Manually update tokens (e.g., after initial OAuth flow).
  """
  def update_tokens(attrs) do
    update_tokens(@name, attrs)
  end

  def update_tokens(server, attrs) do
    GenServer.call(server, {:update_tokens, attrs})
  end

  @doc """
  Persist OAuth token attributes without requiring a running TokenManager process.

  This is useful immediately after OAuth callback exchange when the GenServer
  might not be started yet.
  """
  def persist_tokens(attrs, opts \\ []) do
    state = build_state_from_attrs(attrs, opts)
    persist_runtime_tokens(state)
  end

  ## Server Callbacks

  @impl true
  def init(opts) do
    # Load tokens from config/env
    config = LemonChannels.Adapters.XAPI.config()

    state = %__MODULE__{
      access_token: config[:access_token],
      refresh_token: config[:refresh_token],
      expires_at: parse_expires_at(config[:token_expires_at]),
      token_type: "Bearer",
      secrets_module: Keyword.get(opts, :secrets_module, default_secrets_module()),
      persist_secrets?: Keyword.get(opts, :persist_secrets?, true)
    }

    # Schedule refresh if we have tokens
    if state.access_token do
      schedule_refresh(state)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:get_access_token, _from, state) do
    case ensure_valid(state) do
      {:ok, new_state} ->
        {:reply, {:ok, new_state.access_token}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_call({:update_tokens, attrs}, _from, state) do
    new_state = build_state_from_attrs(attrs, state)
    persist_runtime_tokens(new_state)
    schedule_refresh(new_state)
    {:reply, {:ok, new_state}, new_state}
  end

  @impl true
  def handle_info(:refresh_token, state) do
    case do_refresh(state) do
      {:ok, new_state} ->
        Logger.info("[XAPI] Token refreshed successfully")
        {:noreply, new_state}

      {:error, reason} ->
        retry_ms = refresh_retry_delay_ms(reason)

        if retry_ms == @invalid_refresh_retry_ms do
          Logger.error(
            "[XAPI] Token refresh failed with non-recoverable auth error #{inspect(reason)}; " <>
              "retrying in #{div(retry_ms, 1000)}s. Re-auth may be required."
          )
        else
          Logger.error("[XAPI] Token refresh failed: #{inspect(reason)}")
        end

        Process.send_after(self(), :refresh_token, retry_ms)
        {:noreply, state}
    end
  end

  ## Private Functions

  defp ensure_valid(%__MODULE__{access_token: nil} = state) do
    # Try to refresh if we have a refresh token
    if state.refresh_token do
      do_refresh(state)
    else
      {:error, :no_token}
    end
  end

  defp ensure_valid(%__MODULE__{} = state) do
    if needs_refresh?(state) do
      do_refresh(state)
    else
      {:ok, state}
    end
  end

  defp needs_refresh?(%__MODULE__{expires_at: nil}), do: true

  defp needs_refresh?(%__MODULE__{expires_at: expires_at}) do
    now = DateTime.utc_now()
    refresh_at = DateTime.add(expires_at, -@refresh_buffer_seconds, :second)
    DateTime.compare(now, refresh_at) == :gt
  end

  defp do_refresh(%__MODULE__{refresh_token: nil}) do
    {:error, :no_refresh_token}
  end

  defp do_refresh(%__MODULE__{} = state) do
    config = LemonChannels.Adapters.XAPI.config()

    with {:ok, client_id, _client_secret} <- refresh_credentials(config) do
      body =
        URI.encode_query(%{
          "grant_type" => "refresh_token",
          "refresh_token" => state.refresh_token,
          "client_id" => client_id
        })

      headers = [
        {"Content-Type", "application/x-www-form-urlencoded"},
        {"Authorization", "Basic #{encode_credentials(config)}"}
      ]

      case Req.post("https://api.x.com/2/oauth2/token",
             body: body,
             headers: headers
           ) do
        {:ok, %{status: 200, body: response}} ->
          new_state = parse_token_response(response, state)
          persist_runtime_tokens(new_state)
          schedule_refresh(new_state)
          {:ok, new_state}

        {:ok, %{status: status, body: body}} ->
          Logger.error("[XAPI] Refresh failed: HTTP #{status} - #{inspect(body)}")
          {:error, {:refresh_failed, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp parse_token_response(response, %__MODULE__{} = state) do
    expires_in = parse_expires_in(response["expires_in"])
    expires_at = DateTime.add(DateTime.utc_now(), expires_in, :second)

    %__MODULE__{
      state
      | access_token: response["access_token"],
        refresh_token: response["refresh_token"] || state.refresh_token,
        expires_at: expires_at,
        token_type: response["token_type"] || "Bearer"
    }
  end

  defp schedule_refresh(%__MODULE__{expires_at: nil}), do: :ok

  defp schedule_refresh(%__MODULE__{expires_at: expires_at}) do
    now = DateTime.utc_now()
    refresh_at = DateTime.add(expires_at, -@refresh_buffer_seconds, :second)

    case DateTime.diff(refresh_at, now, :millisecond) do
      delay when delay > 0 ->
        Logger.info("[XAPI] Scheduling token refresh in #{div(delay, 1000)}s")
        Process.send_after(self(), :refresh_token, delay)

      _ ->
        # Already expired or close to it, refresh soon
        Process.send_after(self(), :refresh_token, 5000)
    end
  end

  defp encode_credentials(config) do
    credentials = "#{config[:client_id]}:#{config[:client_secret]}"
    Base.encode64(credentials)
  end

  defp refresh_credentials(config) do
    client_id = normalize_optional_string(config[:client_id])
    client_secret = normalize_optional_string(config[:client_secret])

    cond do
      is_nil(client_id) -> {:error, :missing_client_id}
      is_nil(client_secret) -> {:error, :missing_client_secret}
      true -> {:ok, client_id, client_secret}
    end
  end

  defp refresh_retry_delay_ms(reason) do
    if non_recoverable_refresh_error?(reason) do
      @invalid_refresh_retry_ms
    else
      @default_refresh_retry_ms
    end
  end

  defp non_recoverable_refresh_error?({:refresh_failed, status, body})
       when status in [400, 401] do
    text =
      body
      |> refresh_error_text()
      |> String.downcase()

    String.contains?(text, "invalid_request") or
      String.contains?(text, "invalid_grant") or
      String.contains?(text, "token was invalid") or
      String.contains?(text, "token is invalid")
  rescue
    _ -> false
  end

  defp non_recoverable_refresh_error?(_), do: false

  defp refresh_error_text(%{} = body) do
    [Map.get(body, "error"), Map.get(body, "error_description"), inspect(body)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp refresh_error_text(body) when is_binary(body), do: body
  defp refresh_error_text(body), do: inspect(body)

  defp persist_runtime_tokens(%__MODULE__{} = state) do
    persist_app_config(state)
    persist_process_env(state)
    persist_secrets(state)
    :ok
  end

  defp persist_app_config(%__MODULE__{} = state) do
    current =
      :lemon_channels
      |> Application.get_env(@x_api_app, [])
      |> normalize_app_config()

    updated =
      current
      |> put_optional(:access_token, normalize_optional_string(state.access_token))
      |> put_optional(:refresh_token, normalize_optional_string(state.refresh_token))
      |> put_optional(:token_expires_at, format_expires_at(state.expires_at))

    Application.put_env(:lemon_channels, @x_api_app, updated)
  end

  defp persist_process_env(%__MODULE__{} = state) do
    put_env_optional(
      @x_api_token_keys[:access_token],
      normalize_optional_string(state.access_token)
    )

    put_env_optional(
      @x_api_token_keys[:refresh_token],
      normalize_optional_string(state.refresh_token)
    )

    put_env_optional(@x_api_token_keys[:token_expires_at], format_expires_at(state.expires_at))
  end

  defp persist_secrets(%__MODULE__{persist_secrets?: false}), do: :ok

  defp persist_secrets(%__MODULE__{} = state) do
    module = state.secrets_module

    if is_atom(module) and Code.ensure_loaded?(module) do
      persist_secret_value(module, @x_api_token_keys[:access_token], state.access_token)
      persist_secret_value(module, @x_api_token_keys[:refresh_token], state.refresh_token)

      persist_secret_value(
        module,
        @x_api_token_keys[:token_expires_at],
        format_expires_at(state.expires_at)
      )
    end
  rescue
    reason ->
      Logger.warning("[XAPI] Failed to persist tokens to secrets store: #{inspect(reason)}")
      :ok
  catch
    :exit, reason ->
      Logger.warning("[XAPI] Failed to persist tokens to secrets store: #{inspect(reason)}")
      :ok
  end

  defp persist_secret_value(_module, _name, nil), do: :ok

  defp persist_secret_value(module, name, value) do
    value = normalize_optional_string(value)

    if is_binary(value) do
      result =
        cond do
          function_exported?(module, :set, 3) -> module.set(name, value, [])
          function_exported?(module, :set, 2) -> module.set(name, value)
          true -> {:error, :unsupported}
        end

      case result do
        {:ok, _} ->
          :ok

        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("[XAPI] Failed to persist #{name} in secrets store: #{inspect(reason)}")
          :ok

        other ->
          Logger.warning(
            "[XAPI] Unexpected secrets persistence result for #{name}: #{inspect(other)}"
          )

          :ok
      end
    else
      :ok
    end
  end

  defp put_env_optional(key, nil), do: System.delete_env(key)
  defp put_env_optional(key, value), do: System.put_env(key, value)

  defp put_optional(config, _key, nil), do: config
  defp put_optional(config, key, value), do: Keyword.put(config, key, value)

  defp normalize_app_config(config) when is_list(config), do: config
  defp normalize_app_config(config) when is_map(config), do: Enum.into(config, [])
  defp normalize_app_config(_), do: []

  defp build_state_from_attrs(attrs, opts) when is_list(opts) do
    %__MODULE__{
      access_token: fetch_attr(attrs, :access_token),
      refresh_token: fetch_attr(attrs, :refresh_token),
      expires_at:
        parse_expires_at(fetch_attr(attrs, :expires_at) || fetch_attr(attrs, :token_expires_at)),
      token_type: fetch_attr(attrs, :token_type) || "Bearer",
      secrets_module: Keyword.get(opts, :secrets_module, default_secrets_module()),
      persist_secrets?: Keyword.get(opts, :persist_secrets?, true)
    }
  end

  defp build_state_from_attrs(attrs, %__MODULE__{} = state) do
    updates = %{
      access_token: fetch_attr(attrs, :access_token),
      refresh_token: fetch_attr(attrs, :refresh_token),
      expires_at:
        parse_expires_at(fetch_attr(attrs, :expires_at) || fetch_attr(attrs, :token_expires_at)),
      token_type: fetch_attr(attrs, :token_type)
    }

    state
    |> maybe_put(:access_token, updates.access_token)
    |> maybe_put(:refresh_token, updates.refresh_token)
    |> maybe_put(:expires_at, updates.expires_at)
    |> maybe_put(:token_type, updates.token_type)
  end

  defp maybe_put(state, _key, nil), do: state
  defp maybe_put(state, key, value), do: Map.put(state, key, value)

  defp fetch_attr(attrs, key) when is_map(attrs),
    do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp fetch_attr(_attrs, _key), do: nil

  defp parse_expires_in(nil), do: @default_expires_in
  defp parse_expires_in(value) when is_integer(value) and value > 0, do: value

  defp parse_expires_in(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {seconds, ""} when seconds > 0 -> seconds
      _ -> @default_expires_in
    end
  end

  defp parse_expires_in(_), do: @default_expires_in

  defp format_expires_at(nil), do: nil
  defp format_expires_at(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp parse_expires_at(nil), do: nil

  defp parse_expires_at(string) when is_binary(string) do
    case DateTime.from_iso8601(string) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_expires_at(%DateTime{} = dt), do: dt

  defp default_secrets_module do
    Application.get_env(:lemon_channels, :x_api_secrets_module, LemonCore.Secrets)
  end

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      _ -> value
    end
  end

  defp normalize_optional_string(_), do: nil
end
