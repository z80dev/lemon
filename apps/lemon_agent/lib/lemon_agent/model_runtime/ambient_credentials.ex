defmodule LemonAgent.ModelRuntime.AmbientCredentials do
  @moduledoc """
  Credentials Lemon discovers outside its own secret store: other tools' login
  files and environment tokens, plus Lemon deployment state under the user's
  home directory. `LemonAi` receives only the resulting values.

    * Claude Code: `anthropic_access_token/1` reads `CLAUDE_CODE_OAUTH_TOKEN`
      or `ANTHROPIC_TOKEN` and `<home>/.claude/.credentials.json`. A refreshable
      file login is refreshed through `LemonAi.Auth.AnthropicOAuth` and written
      back, because Claude Code rotates the same refresh token. The write goes
      through `LemonCore.ConfinedFS.replace/5`: a `0600` temporary file in a
      private staging directory is renamed over the original, so the file is
      never more widely readable and a crash leaves the previous file intact.
      It is bound to the bytes the refresh started from: when Claude Code
      changed the file meanwhile, nothing is written and the newer login wins.
    * Codex CLI: `import_codex_cli_login/1` and `codex_cli_login_status/1` read
      `:path`, `CODEX_HOME/auth.json` or `<home>/.codex/auth.json` and decode it
      with `LemonAi.Auth.OpenAICodexOAuth.decode_codex_cli_login/1`. They never
      contact the network or write the file.
    * Kimi Code: `kimi_device_id/1` persists the `x-msh-device-id` Lemon sends
      in `<home>/.lemon/kimi-device-id`.

  Failures are credential-free: they return `nil` or a bare atom.
  """

  require Logger

  alias LemonAi.Auth.{AnthropicOAuth, KimiCodeOAuth, OAuthSecretResolver, OpenAICodexOAuth}
  alias LemonCore.ConfinedFS

  @claude_env_vars ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_TOKEN"]
  @claude_file ".credentials.json"
  @claude_secret_name "claude_code_credentials_file"
  @max_file_bytes 1_048_576
  @kimi_device_id_file "kimi-device-id"

  @codex_unusable [
    :not_chatgpt_oauth,
    :invalid_access_token,
    :missing_refresh_token,
    :invalid_expiry,
    :missing_account_id,
    :invalid_codex_cli_login
  ]

  # ── Claude Code ────────────────────────────────────────────────────────────

  @doc """
  An ambient Claude Code access token, or `nil`.

  A refreshable login from the credentials file wins over a different static
  `CLAUDE_CODE_OAUTH_TOKEN`/`ANTHROPIC_TOKEN` value; otherwise the environment
  token wins over the file. Options: `:home` (defaults to `$HOME`).
  """
  @spec anthropic_access_token(keyword()) :: String.t() | nil
  def anthropic_access_token(opts \\ []) do
    env_token = claude_env_token()

    case claude_code_login(opts) do
      {%{"refresh_token" => refresh}, token} when is_binary(refresh) and token != env_token ->
        token

      {_secret, token} ->
        env_token || token

      nil ->
        env_token
    end
  end

  @doc "Whether an ambient Claude Code login is present, without refreshing it."
  @spec anthropic_login_present?(keyword()) :: boolean()
  def anthropic_login_present?(opts \\ []) do
    is_binary(claude_env_token()) or
      with home when is_binary(home) <- home(opts),
           {:ok, raw} <- read_bounded(Path.join([home, ".claude", @claude_file])),
           {:ok, _secret} <- claude_secret(raw) do
        true
      else
        _ -> false
      end
  end

  defp claude_env_token do
    Enum.find_value(@claude_env_vars, fn name ->
      value = System.get_env(name)
      if present?(value) and AnthropicOAuth.oauth_token?(value), do: value
    end)
  end

  defp claude_code_login(opts) do
    with home when is_binary(home) <- home(opts),
         dir = Path.join(home, ".claude"),
         {:ok, raw} <- read_bounded(Path.join(dir, @claude_file)),
         {:ok, secret} <- claude_secret(raw) do
      resolve_opts = [
        reload_secret: fn _name -> reload_claude_code_login(dir) end,
        persist_secret: fn _name, encoded, revision ->
          persist_claude_code_login(dir, encoded, revision)
        end
      ]

      case OAuthSecretResolver.resolve_with(
             AnthropicOAuth,
             @claude_secret_name,
             AnthropicOAuth.encode_secret(secret),
             resolve_opts
           ) do
        {:ok, token} when is_binary(token) and token != "" -> {secret, token}
        _ -> nil
      end
    else
      _ -> nil
    end
  end

  defp reload_claude_code_login(dir) do
    with {:ok, raw} <- read_bounded(Path.join(dir, @claude_file)),
         {:ok, secret} <- claude_secret(raw) do
      {:ok, AnthropicOAuth.encode_secret(secret), revision(raw)}
    else
      {:error, :enoent} -> {:error, :not_found}
      _ -> {:error, :unreadable}
    end
  end

  defp claude_secret(raw) do
    with {:ok, %{"claudeAiOauth" => %{} = oauth}} <- Jason.decode(raw),
         token when is_binary(token) and token != "" <- oauth["accessToken"] do
      now = System.system_time(:millisecond)

      {:ok,
       %{
         "type" => "anthropic_oauth",
         "access_token" => token,
         "refresh_token" => non_empty(oauth["refreshToken"]),
         "expires_at_ms" => integer(oauth["expiresAt"]),
         "source" => "claude_code_credentials_file",
         "created_at_ms" => now,
         "updated_at_ms" => now
       }}
    else
      _ -> {:error, :invalid_claude_code_credentials}
    end
  end

  # Writes the refreshed tokens into Claude Code's own file, keeping its other
  # fields. The read, comparison and atomic replace run in one confined
  # session on the directory; `expect: stat` refuses an entry replaced since.
  @doc false
  def persist_claude_code_login(dir, encoded, revision) do
    with {:ok, refreshed} <- AnthropicOAuth.decode_secret(encoded),
         {:ok, fs} <- ConfinedFS.open(dir) do
      try do
        with {:ok, raw, stat} <- ConfinedFS.read(fs, :root, @claude_file, @max_file_bytes),
             :ok <- same_revision(raw, revision),
             {:ok, %{} = existing} <- Jason.decode(raw),
             {:ok, _stat} <-
               ConfinedFS.replace(fs, :root, @claude_file, merge_claude(existing, refreshed),
                 mode: 0o600,
                 exact_mode: true,
                 expect: stat,
                 sync: true
               ) do
          :ok
        end
      after
        ConfinedFS.close(fs)
      end
    end
    |> case do
      :ok ->
        :ok

      {:error, reason} when reason in [:stale_revision, :changed] ->
        {:error, :stale_revision}

      other ->
        Logger.warning(
          "Failed to persist Claude Code credentials: #{inspect(safe_reason(other))}"
        )

        {:error, :oauth_secret_persistence_failed}
    end
  end

  defp same_revision(raw, revision),
    do: if(revision(raw) == revision, do: :ok, else: {:error, :stale_revision})

  defp merge_claude(existing, refreshed) do
    oauth =
      existing
      |> Map.get("claudeAiOauth", %{})
      |> Map.merge(%{
        "accessToken" => refreshed["access_token"],
        "refreshToken" => refreshed["refresh_token"],
        "expiresAt" => refreshed["expires_at_ms"]
      })

    Jason.encode!(Map.put(existing, "claudeAiOauth", oauth))
  end

  defp revision(raw), do: :crypto.hash(:sha256, raw)

  # ── Codex CLI ──────────────────────────────────────────────────────────────

  @doc """
  Import an existing Codex CLI ChatGPT login without refreshing or writing it.

  Reads only `:path`, or `CODEX_HOME/auth.json`, or `<home>/.codex/auth.json`
  (in that order) and returns the canonical refreshable OAuth secret (see
  `LemonAi.Auth.OpenAICodexOAuth.decode_codex_cli_login/1`). Errors are atoms.
  """
  @spec import_codex_cli_login(keyword()) :: {:ok, map()} | {:error, atom()}
  def import_codex_cli_login(opts \\ []) do
    with {:ok, path} <- codex_auth_path(opts),
         {:ok, contents} <- read_bounded(path) do
      OpenAICodexOAuth.decode_codex_cli_login(contents)
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_codex_cli_login}
    end
  end

  @doc """
  Whether a refreshable Codex CLI ChatGPT login is present, without returning
  credentials, refreshing tokens or changing the source file.
  """
  @spec codex_cli_login_status(keyword()) :: :present | :absent | {:unusable, atom()}
  def codex_cli_login_status(opts \\ []) do
    case import_codex_cli_login(opts) do
      {:ok, _secret} -> :present
      {:error, :enoent} -> :absent
      {:error, reason} when reason in @codex_unusable -> {:unusable, reason}
      {:error, _reason} -> {:unusable, :invalid_codex_cli_login}
    end
  end

  defp codex_auth_path(opts) do
    case Keyword.get(opts, :path) do
      nil ->
        cond do
          codex_home = non_empty(System.get_env("CODEX_HOME")) ->
            {:ok, Path.join(codex_home, "auth.json")}

          home = non_empty(System.get_env("HOME")) ->
            {:ok, Path.join([home, ".codex", "auth.json"])}

          true ->
            {:error, :missing_home}
        end

      path when is_binary(path) and path != "" ->
        {:ok, path}

      _ ->
        {:error, :invalid_codex_auth_path}
    end
  end

  # ── Kimi Code device id ────────────────────────────────────────────────────

  @doc """
  The Kimi Code device id, persisted at `<home>/.lemon/kimi-device-id`.

  A missing or empty file is seeded with
  `LemonAi.Auth.KimiCodeOAuth.derived_device_id/1`, the id Lemon used before it
  persisted one, so existing logins keep the identity they were minted under
  and later host renames no longer change it. The seed is a private file
  renamed into place, so a concurrent reader never sees a partial id. If the
  file cannot be read or written, the derived id is used. Never raises.

  Options: `:home` (defaults to `$HOME`), `:hostname`.
  """
  @spec kimi_device_id(keyword()) :: String.t()
  def kimi_device_id(opts \\ []) do
    home = home(opts)

    derived =
      KimiCodeOAuth.derived_device_id(Keyword.put(Keyword.take(opts, [:hostname]), :home, home))

    if is_binary(home) do
      path = Path.join([home, ".lemon", @kimi_device_id_file])

      case File.read(path) do
        {:ok, content} -> printable(content) || seed_device_id(path, derived)
        {:error, :enoent} -> seed_device_id(path, derived)
        {:error, _} -> derived
      end
    else
      derived
    end
  rescue
    _ -> KimiCodeOAuth.derived_device_id()
  end

  defp seed_device_id(path, derived) do
    tmp = "#{path}.#{System.pid()}.#{System.unique_integer([:positive])}.tmp"

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, "", [:exclusive]),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.write(tmp, derived <> "\n"),
         :ok <- File.rename(tmp, path) do
      derived
    else
      _ ->
        _ = File.rm(tmp)
        derived
    end
  end

  defp printable(content) do
    case content |> String.replace(~r/[^\x20-\x7E]/, "") |> String.trim() do
      "" -> nil
      id -> id
    end
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp home(opts) do
    case Keyword.fetch(opts, :home) do
      {:ok, home} -> non_empty(home)
      :error -> non_empty(System.get_env("HOME")) || non_empty(System.user_home())
    end
  end

  defp read_bounded(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_file_bytes ->
        File.read(path)

      {:ok, %File.Stat{type: :regular}} ->
        {:error, :too_large}

      {:ok, _stat} ->
        {:error, :not_regular}

      {:error, _} = error ->
        error
    end
  end

  defp safe_reason({:error, reason}) when is_atom(reason), do: reason
  defp safe_reason(_other), do: :unknown

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp non_empty(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp non_empty(_value), do: nil

  defp integer(value) when is_integer(value), do: value
  defp integer(value) when is_float(value), do: trunc(value)

  defp integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp integer(_value), do: nil
end
