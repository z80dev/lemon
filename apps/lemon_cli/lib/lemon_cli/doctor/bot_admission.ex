defmodule LemonCli.Doctor.BotAdmission do
  @moduledoc """
  Read-only check that the controller admits the Bot's published callback origin.

  The Bot origin is the explicit `:bot_public_url` option (the `doctor.run`
  `botPublicUrl` parameter), else `LEMON_BOT_PUBLIC_URL`, else the origin
  `lemon-bot https enable` published in `~/.lemon/bot-https.json`. The
  allowlists are the effective ones enforced by native follow-up and cron
  admission, read from their owners through `:doctor_runtime`
  (`:native_followup_admission`, `:cron_admission`), never from another app's
  configuration. The check never writes. Diagnostics name variables only, never
  configured URL values.
  """

  alias LemonCore.Doctor.{Check, RuntimeModules}
  alias LemonMCP.HTTP.OriginPolicy

  @name "bot.admission_origins"
  @receipt_bytes 65_536
  @allowlists [
    {"LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS", :native_followup_admission},
    {"LEMON_CRON_ADMISSION_ALLOWED_ORIGINS", :cron_admission}
  ]

  @spec run(keyword()) :: [Check.t()]
  def run(opts \\ []) do
    case public_url(opts) do
      :none ->
        [
          Check.skip(
            @name,
            "No Bot public origin is published (LEMON_BOT_PUBLIC_URL or lemon-bot https)."
          )
        ]

      :invalid_receipt ->
        [
          Check.fail(
            @name,
            "The published Bot HTTPS receipt is unreadable.",
            "Run `lemon-bot https status` on the Bot host; never edit the receipt by hand."
          )
        ]

      {:ok, url} ->
        [check(url)]
    end
  end

  defp public_url(opts) do
    case Keyword.fetch(opts, :bot_public_url) do
      {:ok, url} ->
        case OriginPolicy.canonical_https_origin(url) do
          {:ok, canonical} -> {:ok, canonical}
          _ -> {:ok, nil}
        end

      :error ->
        case System.fetch_env("LEMON_BOT_PUBLIC_URL") do
          {:ok, url} -> {:ok, url}
          :error -> published_origin(opts)
        end
    end
  end

  defp published_origin(opts) do
    path =
      Path.join([Keyword.get_lazy(opts, :home, &System.user_home!/0), ".lemon", "bot-https.json"])

    case File.lstat(path) do
      {:error, :enoent} ->
        :none

      {:ok, %File.Stat{type: :regular, size: size}} when size <= @receipt_bytes ->
        with {:ok, contents} <- File.read(path),
             {:ok, %{"origin" => origin}} when is_binary(origin) <- Jason.decode(contents),
             {:ok, ^origin} <- OriginPolicy.canonical_https_origin(origin) do
          {:ok, origin}
        else
          _ -> :invalid_receipt
        end

      _ ->
        :invalid_receipt
    end
  end

  defp check(url) do
    with {:ok, bot_origin} <- origin(url, true),
         {:ok, allowlists} <- allowlists() do
      case for({env_var, origins} <- allowlists, not allowed?(bot_origin, origins), do: env_var) do
        [] ->
          Check.pass(
            @name,
            "The Bot public origin is allowed for native follow-up and cron admission."
          )

        names ->
          variables = Enum.join(names, ", ")

          Check.fail(
            @name,
            "The Bot public origin is missing from: #{variables}.",
            "Add the Bot public origin to #{variables}; allowlists contain exact origins, not callback paths."
          )
      end
    else
      :invalid ->
        Check.fail(
          @name,
          "LEMON_BOT_PUBLIC_URL is not a valid admission callback URL.",
          "Use HTTPS or literal-loopback HTTP without credentials, a query, or a fragment."
        )

      :unavailable ->
        Check.skip(@name, "Callback admission is not part of this runtime.")
    end
  end

  defp allowlists do
    Enum.reduce_while(@allowlists, {:ok, []}, fn {env_var, key}, {:ok, acc} ->
      with module when is_atom(module) and not is_nil(module) <- RuntimeModules.fetch(key),
           true <- Code.ensure_loaded?(module) and function_exported?(module, :allowed_origins, 0) do
        {:cont, {:ok, acc ++ [{env_var, module.allowed_origins()}]}}
      else
        _ -> {:halt, :unavailable}
      end
    end)
  end

  defp allowed?(bot_origin, origins) when is_list(origins) do
    Enum.any?(origins, &(origin(&1, false) == {:ok, bot_origin}))
  end

  defp allowed?(_bot_origin, _origins), do: false

  # Use execution's origin canonicalization without resolving DNS.
  # Allowlist entries must be origins, while the public URL can include a path.
  defp origin(value, allow_path?) do
    with true <- is_binary(value) and byte_size(value) in 1..2048 and String.valid?(value),
         false <- Regex.match?(~r/[\s\\\x00-\x1F\x7F]|%(?![0-9a-fA-F]{2})/, value),
         false <- Regex.match?(~r/\Ahttps?:\/\/[^\/?#]*:(?:[\/?#]|\z)/i, value),
         {:ok, %URI{host: host} = uri} <- URI.new(value),
         true <- is_binary(host),
         scheme <- String.downcase(uri.scheme || ""),
         host <- String.downcase(host),
         true <- valid_host?(host),
         true <- scheme == "https" or (scheme == "http" and host in ["127.0.0.1", "::1"]),
         port <- uri.port || if(scheme == "https", do: 443, else: 80),
         true <- is_integer(port) and port in 1..65_535,
         true <- is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment),
         true <- allow_path? or is_nil(uri.path),
         {:ok, canonical} <- OriginPolicy.canonical_origin(value) do
      {:ok, canonical}
    else
      _ -> :invalid
    end
  end

  defp valid_host?(host) do
    if String.contains?(host, ":") do
      match?({:ok, _}, :inet.parse_strict_address(String.to_charlist(host)))
    else
      byte_size(host) <= 253 and
        Enum.all?(String.split(host, "."), fn label ->
          byte_size(label) in 1..63 and
            Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/, label)
        end)
    end
  end
end
