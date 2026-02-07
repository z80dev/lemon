defmodule Ai.Auth.OpenAICodexOAuth do
  @moduledoc """
  Helpers for using OpenAI Codex (ChatGPT OAuth) credentials.

  Lemon's `Ai.Providers.OpenAICodexResponses` provider needs a **ChatGPT JWT**
  (the OAuth `access_token`) plus a `refresh_token` to keep it fresh.

  This module can:
  - Read tokens from the Codex CLI store (`$CODEX_HOME/auth.json`, usually `~/.codex/auth.json`)
  - Optionally refresh them via `https://auth.openai.com/oauth/token`
  - Cache refreshed tokens in `~/.lemon/credentials/openai-codex.json`

  It intentionally does not try to run an interactive login flow. Use `codex login`
  (Codex CLI) to authenticate, then Lemon will pick up credentials automatically.
  """

  require Logger

  @token_url "https://auth.openai.com/oauth/token"

  # OpenAI Codex OAuth client id used by Codex CLI (see pi-ai / Codex CLI sources)
  @client_id "app_EMoamEEZ73f0CkXaXp7hrann"

  @lemon_rel_path [".lemon", "credentials", "openai-codex.json"]
  @codex_auth_filename "auth.json"

  # Try to refresh if the token is within 10 minutes of expiry.
  @near_expiry_ms 10 * 60 * 1000

  @type creds :: %{
          access: String.t(),
          refresh: String.t() | nil,
          expires_at_ms: non_neg_integer() | nil,
          source: :lemon_store | :codex_file | :codex_keychain
        }

  @doc """
  Resolve a fresh ChatGPT JWT access token to use for the Codex API.

  Returns `nil` if no credentials are available.
  """
  @spec resolve_access_token() :: String.t() | nil
  def resolve_access_token do
    with {:ok, creds} <- load_best_credentials(),
         {:ok, access} <- ensure_fresh_access_token(creds) do
      access
    else
      _ -> nil
    end
  end

  # ============================================================================
  # Loading
  # ============================================================================

  defp load_best_credentials do
    # Prefer Lemon cache if present, then Codex CLI file store, then Keychain (best-effort).
    load_lemon_store() || load_codex_auth_file() || load_codex_keychain()
  end

  defp load_lemon_store do
    path = lemon_cred_path()

    if File.exists?(path) do
      case File.read(path) do
        {:ok, raw} ->
          case Jason.decode(raw) do
            {:ok, data} when is_map(data) ->
              access =
                data["access_token"] || data["access"] || data["token"] || data["accessToken"]

              refresh =
                data["refresh_token"] || data["refresh"] || data["refreshToken"]

              expires_at =
                data["expires_at_ms"] || data["expires_at"] || data["expires"] ||
                  data["expiresAt"]

              cond do
                is_binary(access) and access != "" ->
                  {:ok,
                   %{
                     access: access,
                     refresh: if(is_binary(refresh) and refresh != "", do: refresh, else: nil),
                     expires_at_ms: normalize_expires_ms(expires_at, access),
                     source: :lemon_store
                   }}

                true ->
                  nil
              end

            _ ->
              nil
          end

        _ ->
          nil
      end
    else
      nil
    end
  end

  defp load_codex_auth_file do
    home = resolve_codex_home()
    path = Path.join(home, @codex_auth_filename)

    if File.exists?(path) do
      case File.read(path) do
        {:ok, raw} ->
          with {:ok, data} <- Jason.decode(raw),
               %{"tokens" => tokens} <- data,
               %{"access_token" => access, "refresh_token" => refresh} <- tokens,
               true <- is_binary(access) and access != "",
               true <- is_binary(refresh) and refresh != "" do
            {:ok,
             %{
               access: access,
               refresh: refresh,
               expires_at_ms: normalize_expires_ms(data["last_refresh"], access),
               source: :codex_file
             }}
          else
            _ -> nil
          end

        _ ->
          nil
      end
    else
      nil
    end
  end

  defp load_codex_keychain do
    # Avoid blocking/hanging on keychain prompts: best-effort, short timeout.
    if :os.type() == {:unix, :darwin} do
      case read_codex_keychain_secret(timeout_ms: 5_000) do
        {:ok, secret} ->
          with {:ok, data} <- Jason.decode(secret),
               %{"tokens" => tokens} <- data,
               %{"access_token" => access, "refresh_token" => refresh} <- tokens,
               true <- is_binary(access) and access != "",
               true <- is_binary(refresh) and refresh != "" do
            {:ok,
             %{
               access: access,
               refresh: refresh,
               expires_at_ms: normalize_expires_ms(data["last_refresh"], access),
               source: :codex_keychain
             }}
          else
            _ -> nil
          end

        _ ->
          nil
      end
    else
      nil
    end
  end

  defp resolve_codex_home do
    System.get_env("CODEX_HOME")
    |> case do
      v when is_binary(v) and v != "" -> Path.expand(v)
      _ -> Path.expand("~/.codex")
    end
  end

  defp lemon_cred_path do
    Path.join([System.user_home!() | @lemon_rel_path])
  end

  # ============================================================================
  # Freshness / Refresh
  # ============================================================================

  defp ensure_fresh_access_token(%{access: access, refresh: nil, expires_at_ms: expires_at})
       when is_integer(expires_at) do
    if near_expiry?(expires_at) do
      {:error, :expired_no_refresh}
    else
      {:ok, access}
    end
  end

  defp ensure_fresh_access_token(%{access: access, expires_at_ms: expires_at})
       when is_integer(expires_at) do
    if near_expiry?(expires_at) do
      refresh_and_cache(access)
    else
      {:ok, access}
    end
  end

  defp ensure_fresh_access_token(%{access: access}) do
    # No expiry info available: just return what we have.
    {:ok, access}
  end

  defp refresh_and_cache(_access) do
    # Re-load (in case Codex CLI refreshed it recently) then refresh if still near-expiry.
    with {:ok, creds} <- load_codex_auth_file() || load_codex_keychain() || {:error, :no_creds},
         {:ok, access} <- refresh_if_needed(creds) do
      {:ok, access}
    end
  end

  defp refresh_if_needed(%{access: access, refresh: refresh, expires_at_ms: expires_at})
       when is_binary(refresh) and refresh != "" and is_integer(expires_at) do
    if near_expiry?(expires_at) do
      case refresh_access_token(refresh) do
        {:ok, refreshed} ->
          _ = write_lemon_store(refreshed)
          {:ok, refreshed.access}

        {:error, reason} ->
          Logger.warning("OpenAI Codex token refresh failed: #{inspect(reason)}")
          {:error, :refresh_failed}
      end
    else
      {:ok, access}
    end
  end

  defp refresh_if_needed(%{access: access}), do: {:ok, access}

  defp near_expiry?(expires_at_ms) do
    now = System.system_time(:millisecond)
    now + @near_expiry_ms >= expires_at_ms
  end

  defp refresh_access_token(refresh_token) do
    # Use :httpc directly so unit tests that set Req.Test plugs don't accidentally
    # hijack this request (refresh should not depend on test stubs unless explicitly mocked).
    body =
      URI.encode_query(%{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token,
        "client_id" => @client_id
      })

    headers = [{~c"content-type", ~c"application/x-www-form-urlencoded"}]

    request =
      {String.to_charlist(@token_url), headers, ~c"application/x-www-form-urlencoded", body}

    http_opts = [timeout: 15_000, connect_timeout: 5_000]
    req_opts = [body_format: :binary]

    case LemonCore.Httpc.request(:post, request, http_opts, req_opts) do
      {:ok, {{_http, status, _reason}, _resp_headers, resp_body}} when status in 200..299 ->
        case Jason.decode(resp_body) do
          {:ok,
           %{
             "access_token" => access,
             "refresh_token" => refresh,
             "expires_in" => expires_in
           }}
          when is_binary(access) and is_binary(refresh) and is_number(expires_in) ->
            now = System.system_time(:millisecond)

            {:ok,
             %{
               access: access,
               refresh: refresh,
               expires_at_ms: now + trunc(expires_in * 1000),
               source: :lemon_store
             }}

          {:ok, other} ->
            {:error, {:invalid_response, other}}

          {:error, err} ->
            {:error, {:decode_error, err}}
        end

      {:ok, {{_http, status, _reason}, _resp_headers, resp_body}} ->
        {:error, {:http_error, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_lemon_store(%{access: access, refresh: refresh, expires_at_ms: expires_at_ms})
       when is_binary(access) and is_binary(refresh) and is_integer(expires_at_ms) do
    path = lemon_cred_path()
    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    payload =
      Jason.encode!(%{
        "access_token" => access,
        "refresh_token" => refresh,
        "expires_at_ms" => expires_at_ms,
        "updated_at_ms" => System.system_time(:millisecond)
      })

    # Best-effort; ignore write errors.
    File.write(path, payload)
  end

  # ============================================================================
  # JWT helpers
  # ============================================================================

  defp normalize_expires_ms(expires_raw, access_token) do
    # Prefer JWT exp if present; otherwise fall back to "last_refresh + 1h" like openclaw.
    jwt_exp_ms = jwt_exp_ms(access_token)

    cond do
      is_integer(jwt_exp_ms) and jwt_exp_ms > 0 ->
        jwt_exp_ms

      true ->
        last_refresh_ms = parse_last_refresh_ms(expires_raw) || System.system_time(:millisecond)
        last_refresh_ms + 60 * 60 * 1000
    end
  end

  defp jwt_exp_ms(token) when is_binary(token) do
    with [_h, payload, _s] <- String.split(token, ".", parts: 3),
         {:ok, decoded} <- decode_base64url(payload),
         {:ok, claims} <- Jason.decode(decoded),
         exp when is_number(exp) <- Map.get(claims, "exp"),
         true <- exp > 0 do
      trunc(exp * 1000)
    else
      _ -> nil
    end
  end

  defp decode_base64url(str) do
    normalized =
      str
      |> String.replace("-", "+")
      |> String.replace("_", "/")

    padded =
      case rem(String.length(normalized), 4) do
        0 -> normalized
        2 -> normalized <> "=="
        3 -> normalized <> "="
        _ -> normalized
      end

    Base.decode64(padded)
  end

  defp parse_last_refresh_ms(nil), do: nil

  defp parse_last_refresh_ms(value) when is_integer(value) do
    # Sometimes stored as seconds; treat values < year 2000 ms as seconds.
    if value < 946_684_800_000 do
      value * 1000
    else
      value
    end
  end

  defp parse_last_refresh_ms(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
      _ -> nil
    end
  end

  defp parse_last_refresh_ms(_), do: nil

  # ============================================================================
  # Keychain (macOS) helpers
  # ============================================================================

  defp read_codex_keychain_secret(opts) do
    codex_home = resolve_codex_home()
    account = codex_keychain_account(codex_home)

    args = ["find-generic-password", "-s", "Codex Auth", "-a", account, "-w"]
    cmd_with_timeout("security", args, opts[:timeout_ms] || 5_000)
  end

  defp codex_keychain_account(codex_home) do
    hash = :crypto.hash(:sha256, codex_home) |> Base.encode16(case: :lower)
    "cli|" <> String.slice(hash, 0, 16)
  end

  defp cmd_with_timeout(cmd, args, timeout_ms) do
    task =
      Task.async(fn ->
        try do
          System.cmd(cmd, args, stderr_to_stdout: true)
        rescue
          e -> {:error, Exception.message(e)}
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {out, 0} when is_binary(out) -> {:ok, String.trim(out)}
      {out, code} when is_binary(out) -> {:error, {:exit, code, out}}
      {:error, msg} -> {:error, msg}
      nil -> {:error, :timeout}
      other -> {:error, other}
    end
  end
end
