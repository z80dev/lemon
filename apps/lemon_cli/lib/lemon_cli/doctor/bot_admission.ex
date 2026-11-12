defmodule LemonCli.Doctor.BotAdmission do
  @moduledoc """
  Offline Bot callback-origin checks for native follow-up and cron admission.

  Environment allowlists replace app configuration, including explicit empty
  values. Diagnostics contain variable names only, never configured URL values.
  """

  alias LemonCore.Doctor.Check
  alias LemonMCP.HTTP.OriginPolicy

  @name "bot.admission_origins"
  @allowlists [
    {"LEMON_NATIVE_FOLLOWUP_ALLOWED_ORIGINS", :lemon_router, :native_followup_allowed_origins},
    {"LEMON_CRON_ADMISSION_ALLOWED_ORIGINS", :lemon_automation, :cron_admission_allowed_origins}
  ]

  @spec run(keyword()) :: [Check.t()]
  def run(_opts \\ []) do
    case System.fetch_env("LEMON_BOT_PUBLIC_URL") do
      :error ->
        [Check.skip(@name, "LEMON_BOT_PUBLIC_URL is not set.")]

      {:ok, url} ->
        [check(url)]
    end
  end

  defp check(url) do
    case origin(url, true) do
      {:ok, bot_origin} ->
        missing =
          for {env_var, app, key} <- @allowlists,
              not allowed?(bot_origin, allowed_origins(env_var, app, key)),
              do: env_var

        case missing do
          [] ->
            Check.pass(
              @name,
              "The Bot public origin is allowed for native follow-up and cron admission."
            )

          names ->
            variables = Enum.join(names, ", ")

            Check.fail(
              @name,
              "The LEMON_BOT_PUBLIC_URL origin is missing from: #{variables}.",
              "Add the Bot public origin to #{variables}; allowlists contain exact origins, not callback paths."
            )
        end

      :error ->
        Check.fail(
          @name,
          "LEMON_BOT_PUBLIC_URL is not a valid admission callback URL.",
          "Use HTTPS or literal-loopback HTTP without credentials, a query, or a fragment."
        )
    end
  end

  defp allowed_origins(env_var, app, key) do
    case System.fetch_env(env_var) do
      :error -> Application.get_env(app, key, [])
      {:ok, value} -> value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
    end
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
      _ -> :error
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
