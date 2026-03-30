defmodule Ai.Auth.AnthropicOAuth do
  @moduledoc """
  Anthropic OAuth helpers for Claude subscription-backed access.
  """

  require Logger

  alias LemonCore.Secrets

  @secret_type "anthropic_oauth"
  @legacy_secret_types ["onboarding_anthropic_oauth"]
  @default_secret_names ["llm_anthropic_api_key"]
  @near_expiry_ms 60_000
  @oauth_client_id "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  @oauth_token_urls [
    "https://platform.claude.com/v1/oauth/token",
    "https://console.anthropic.com/v1/oauth/token"
  ]
  @oauth_env_vars ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_TOKEN"]
  @oauth_beta_features ["claude-code-20250219", "oauth-2025-04-20"]
  @claude_code_version_fallback "2.1.74"

  @type oauth_secret :: %{required(String.t()) => String.t() | integer() | nil}
  @type login_opt ::
          {:on_progress, (String.t() -> any())}
          | {:on_prompt, (String.t() | map() -> String.t() | charlist() | nil)}

  @spec encode_secret(oauth_secret()) :: String.t()
  def encode_secret(secret) when is_map(secret), do: Jason.encode!(secret)

  @spec login_device_flow([login_opt()]) :: {:ok, oauth_secret()} | {:error, term()}
  def login_device_flow(opts \\ []) when is_list(opts) do
    with :missing <- existing_login_secret(),
         :ok <- notify_progress(opts, "Running `claude setup-token`..."),
         result <- run_setup_token_command(),
         :ok <- handle_setup_token_result(result, opts),
         secret when is_map(secret) <- existing_login_secret() do
      {:ok, secret}
    else
      %{} = secret ->
        {:ok, secret}

      {:error, :claude_cli_not_found} ->
        notify_progress(opts, "Claude Code CLI not found. Falling back to manual token paste.")
        prompt_for_manual_token(opts)

      {:error, :setup_token_cancelled} ->
        prompt_for_manual_token(opts)

      {:error, reason} ->
        prompt_for_manual_token(opts, reason)

      :missing ->
        prompt_for_manual_token(opts)
    end
  end

  @spec decode_secret(String.t()) :: {:ok, oauth_secret()} | :not_oauth
  def decode_secret(secret_value) when is_binary(secret_value) do
    case Jason.decode(secret_value) do
      {:ok, decoded} when is_map(decoded) ->
        if oauth_secret_type?(decoded["type"]) do
          {:ok, decoded}
        else
          :not_oauth
        end

      _ ->
        :not_oauth
    end
  end

  def decode_secret(_), do: :not_oauth

  @spec resolve_api_key_from_secret(String.t(), String.t()) ::
          {:ok, String.t()} | :ignore | {:error, term()}
  def resolve_api_key_from_secret(secret_name, secret_value)
      when is_binary(secret_name) and is_binary(secret_value) do
    with {:ok, secret} <- decode_secret(secret_value),
         {:ok, refreshed_secret, changed?} <- ensure_fresh_secret(secret),
         access_token when is_binary(access_token) and access_token != "" <-
           non_empty_binary(refreshed_secret["access_token"]) do
      if changed? do
        persist_secret(secret_name, refreshed_secret)
      end

      {:ok, access_token}
    else
      :not_oauth -> :ignore
      nil -> {:error, :missing_access_token}
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve_api_key_from_secret(_, _), do: {:error, :invalid_secret_value}

  @spec resolve_access_token() :: String.t() | nil
  def resolve_access_token do
    resolve_env_token() ||
      resolve_default_secret_token() ||
      resolve_claude_code_credentials_token()
  end

  @spec oauth_token?(String.t() | nil) :: boolean()
  def oauth_token?(token) when is_binary(token) do
    trimmed = String.trim(token)

    trimmed != "" and
      (String.starts_with?(trimmed, "sk-ant-oat") or jwt_like?(trimmed))
  end

  def oauth_token?(_), do: false

  @spec oauth_beta_features() :: [String.t()]
  def oauth_beta_features, do: @oauth_beta_features

  @spec oauth_headers() :: [{String.t(), String.t()}]
  def oauth_headers do
    [
      {"user-agent", "claude-cli/#{claude_code_version()} (external, cli)"},
      {"x-app", "cli"}
    ]
  end

  defp ensure_fresh_secret(secret) when is_map(secret) do
    access_token = non_empty_binary(secret["access_token"])
    refresh_token = non_empty_binary(secret["refresh_token"])
    expires_at_ms = parse_integer(secret["expires_at_ms"])

    should_refresh? =
      cond do
        is_nil(refresh_token) -> false
        is_nil(access_token) -> true
        is_nil(expires_at_ms) -> false
        expires_at_ms - System.system_time(:millisecond) <= @near_expiry_ms -> true
        true -> false
      end

    cond do
      should_refresh? ->
        refresh_secret(secret)

      is_binary(access_token) and access_token != "" ->
        {:ok, secret, false}

      true ->
        {:error, :missing_access_token}
    end
  end

  defp refresh_secret(secret) do
    refresh_token = non_empty_binary(secret["refresh_token"])

    if is_nil(refresh_token) do
      {:error, :missing_refresh_token}
    else
      body = %{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token,
        "client_id" => @oauth_client_id
      }

      Enum.reduce_while(@oauth_token_urls, {:error, :refresh_failed}, fn url, _acc ->
        case Req.post(url,
               json: body,
               headers: %{
                 "content-type" => "application/json",
                 "user-agent" => "claude-cli/#{claude_code_version()} (external, cli)"
               }
             ) do
          {:ok, %Req.Response{status: 200, body: response_body}} ->
            case parse_refresh_response(response_body) do
              {:ok, token_data} ->
                now = System.system_time(:millisecond)

                refreshed =
                  secret
                  |> Map.put("type", @secret_type)
                  |> Map.put("access_token", token_data.access_token)
                  |> Map.put("refresh_token", token_data.refresh_token || refresh_token)
                  |> Map.put("expires_at_ms", token_data.expires_at_ms)
                  |> Map.put("updated_at_ms", now)
                  |> Map.put_new("created_at_ms", now)

                {:halt, {:ok, refreshed, true}}

              {:error, reason} ->
                {:halt, {:error, reason}}
            end

          {:ok, %Req.Response{status: status, body: response_body}} ->
            Logger.debug(
              "Anthropic OAuth refresh failed at #{url}: status=#{status} body=#{inspect(response_body)}"
            )

            {:cont, {:error, {:refresh_http_error, status}}}

          {:error, reason} ->
            Logger.debug("Anthropic OAuth refresh failed at #{url}: #{inspect(reason)}")
            {:cont, {:error, reason}}
        end
      end)
    end
  end

  defp parse_refresh_response(body) when is_map(body) do
    access_token = non_empty_binary(body["access_token"])
    refresh_token = non_empty_binary(body["refresh_token"])
    expires_in = parse_integer(body["expires_in"]) || 3600

    if is_binary(access_token) and access_token != "" do
      {:ok,
       %{
         access_token: access_token,
         refresh_token: refresh_token,
         expires_at_ms: System.system_time(:millisecond) + expires_in * 1000
       }}
    else
      {:error, :missing_access_token}
    end
  end

  defp parse_refresh_response(_), do: {:error, :invalid_refresh_response}

  defp persist_secret(secret_name, secret) do
    case Secrets.set(secret_name, encode_secret(secret), provider: "anthropic_oauth") do
      {:ok, _metadata} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to persist refreshed Anthropic OAuth secret #{secret_name}: #{inspect(reason)}"
        )
    end
  end

  defp resolve_env_token do
    Enum.find_value(@oauth_env_vars, fn env_var ->
      case System.get_env(env_var) do
        value when is_binary(value) and value != "" ->
          trimmed = String.trim(value)
          if oauth_token?(trimmed), do: trimmed, else: nil

        _ ->
          nil
      end
    end)
  end

  defp resolve_default_secret_token do
    Enum.find_value(@default_secret_names, fn secret_name ->
      case Secrets.resolve(secret_name, prefer_env: false, env_fallback: false) do
        {:ok, value, _source} ->
          case resolve_api_key_from_secret(secret_name, value) do
            {:ok, access_token} -> access_token
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end

  defp existing_login_secret do
    with {:ok, secret} <- read_claude_code_credentials(),
         {:ok, refreshed_secret, changed?} <- ensure_fresh_secret(secret) do
      if changed? do
        persist_claude_code_credentials(refreshed_secret)
      end

      refreshed_secret
    else
      _ ->
        case resolve_env_token() do
          token when is_binary(token) and token != "" -> build_secret(token)
          _ -> :missing
        end
    end
  end

  defp resolve_claude_code_credentials_token do
    with {:ok, secret} <- read_claude_code_credentials(),
         {:ok, refreshed_secret, changed?} <- ensure_fresh_secret(secret),
         access_token when is_binary(access_token) and access_token != "" <-
           non_empty_binary(refreshed_secret["access_token"]) do
      if changed? do
        persist_claude_code_credentials(refreshed_secret)
      end

      access_token
    else
      _ -> nil
    end
  end

  defp read_claude_code_credentials do
    path = claude_credentials_path()

    if File.exists?(path) do
      with {:ok, raw} <- File.read(path),
           {:ok, decoded} <- Jason.decode(raw),
           %{} = oauth <- decoded["claudeAiOauth"],
           access_token when is_binary(access_token) and access_token != "" <-
             non_empty_binary(oauth["accessToken"]) do
        {:ok,
         %{
           "type" => @secret_type,
           "access_token" => access_token,
           "refresh_token" => non_empty_binary(oauth["refreshToken"]),
           "expires_at_ms" => parse_integer(oauth["expiresAt"]),
           "source" => "claude_code_credentials_file",
           "created_at_ms" => System.system_time(:millisecond),
           "updated_at_ms" => System.system_time(:millisecond)
         }}
      else
        _ -> {:error, :missing_credentials}
      end
    else
      {:error, :missing_credentials}
    end
  end

  defp persist_claude_code_credentials(secret) do
    path = claude_credentials_path()

    existing =
      case File.read(path) do
        {:ok, raw} ->
          case Jason.decode(raw) do
            {:ok, decoded} when is_map(decoded) -> decoded
            _ -> %{}
          end

        _ ->
          %{}
      end

    updated =
      Map.put(existing, "claudeAiOauth", %{
        "accessToken" => secret["access_token"],
        "refreshToken" => secret["refresh_token"],
        "expiresAt" => secret["expires_at_ms"]
      })

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, Jason.encode!(updated)),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("Failed to persist Claude Code credentials: #{inspect(reason)}")
    end
  end

  defp build_secret(access_token, attrs \\ %{}) when is_binary(access_token) do
    now = System.system_time(:millisecond)

    %{
      "type" => @secret_type,
      "access_token" => access_token,
      "refresh_token" => Map.get(attrs, "refresh_token"),
      "expires_at_ms" => Map.get(attrs, "expires_at_ms"),
      "created_at_ms" => Map.get(attrs, "created_at_ms", now),
      "updated_at_ms" => now
    }
  end

  defp run_setup_token_command do
    case {System.get_env("LEMON_ANTHROPIC_CLAUDE_PATH"), claude_executable()} do
      {_override, nil} ->
        {:error, :claude_cli_not_found}

      {override, executable} when is_binary(override) and override != "" ->
        {_output, status} = System.cmd(executable, ["setup-token"])
        {:ok, status}

      {_override, executable} ->
        status =
          System.cmd("sh", [
            "-lc",
            "#{quote_shell(executable)} setup-token < /dev/tty > /dev/tty 2>&1"
          ])
          |> elem(1)

        {:ok, status}
    end
  rescue
    e in ErlangError ->
      if e.original == :enoent do
        {:error, :claude_cli_not_found}
      else
        {:error, e.original}
      end

    e ->
      {:error, e}
  end

  defp handle_setup_token_result({:ok, 0}, _opts), do: :ok

  defp handle_setup_token_result({:ok, _status}, opts) do
    notify_progress(
      opts,
      "Claude Code login did not yield credentials automatically. You can paste a setup token instead."
    )
  end

  defp handle_setup_token_result({:error, reason}, _opts), do: {:error, reason}

  defp prompt_for_manual_token(opts, reason \\ nil) do
    if reason do
      _ =
        notify_progress(
          opts,
          "Claude Code OAuth setup could not complete automatically: #{inspect(reason)}"
        )
    end

    prompt_callback = Keyword.get(opts, :on_prompt)

    value =
      cond do
        is_function(prompt_callback, 1) ->
          prompt_callback.(%{
            message: "Paste Anthropic setup-token (or press Enter to cancel):",
            placeholder: "sk-ant-oat..."
          })

        true ->
          nil
      end

    case normalize_prompt_input(value) do
      token when is_binary(token) and token != "" ->
        {:ok, build_secret(token)}

      _ ->
        {:error, :setup_token_cancelled}
    end
  end

  defp claude_credentials_path do
    Path.join([home_dir(), ".claude", ".credentials.json"])
  end

  defp home_dir do
    case System.get_env("HOME") do
      value when is_binary(value) and value != "" -> value
      _ -> System.user_home!()
    end
  end

  defp claude_executable do
    case System.get_env("LEMON_ANTHROPIC_CLAUDE_PATH") do
      value when is_binary(value) and value != "" -> value
      _ -> System.find_executable("claude") || System.find_executable("claude-code")
    end
  end

  defp quote_shell(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp oauth_secret_type?(type) when type == @secret_type, do: true
  defp oauth_secret_type?(type) when type in @legacy_secret_types, do: true
  defp oauth_secret_type?(_), do: false

  defp claude_code_version do
    case System.cmd("claude", ["--version"], stderr_to_stdout: true) do
      {output, 0} ->
        output
        |> String.trim()
        |> String.split()
        |> List.first()
        |> case do
          version when is_binary(version) and version != "" -> version
          _ -> @claude_code_version_fallback
        end

      _ ->
        @claude_code_version_fallback
    end
  rescue
    _ -> @claude_code_version_fallback
  end

  defp non_empty_binary(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp non_empty_binary(_), do: nil

  defp normalize_prompt_input(value) when is_binary(value), do: String.trim(value)

  defp normalize_prompt_input(value) when is_list(value),
    do: value |> List.to_string() |> String.trim()

  defp normalize_prompt_input(_), do: ""

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp parse_integer(_), do: nil

  defp jwt_like?(value) when is_binary(value) do
    case String.split(value, ".", parts: 3) do
      [_header, _payload, _signature] -> true
      _ -> false
    end
  end

  defp notify_progress(opts, message) when is_binary(message) do
    progress_callback = Keyword.get(opts, :on_progress)

    cond do
      is_function(progress_callback, 1) ->
        progress_callback.(message)
        :ok

      true ->
        :ok
    end
  rescue
    _ -> :ok
  end
end
