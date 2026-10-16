defmodule LemonCli.Doctor.Providers do
  @moduledoc """
  Provider live diagnostics using setup's credential resolution.

  `lemon doctor --live` checks only the default provider, reported as
  `providers.live`. `--live --provider NAME` checks one named provider and
  `--live --provider all` checks the default plus every configured provider,
  each as its own `providers.live.<id>` result. The selection arrives as
  `:live_provider`.

  Every probe is the same bounded, non-generating `GET {base_url}/models`
  request (five-second timeout, shared overall deadline); no completion is ever
  requested. A selection of `all` is capped at eight providers, and the surplus
  is reported as one skipped result rather than probed. Results carry fixed
  failure text only: credentials, URLs and transport errors never reach them.

  Options besides `:live_provider`: `:config` (resolved config; otherwise loaded
  from `:project_dir`), `:provider_live_input` and `:provider_live_check`
  (injectable resolver and probe, used by tests so no network is touched).
  """

  alias LemonAgent.ModelRuntime.{CustomProviders, ProviderNames}
  alias LemonCli.ProviderLiveCheck
  alias LemonCli.Setup.Verification
  alias LemonCore.Config
  alias LemonCore.Doctor.Check

  @default_name "providers.live"
  @max_providers 8
  @max_name 48

  @spec run(keyword()) :: [Check.t()]
  def run(_opts), do: []

  @spec live_checks(keyword()) :: [LemonCore.Doctor.LiveChecks.job()]
  def live_checks(opts) do
    case Keyword.get(opts, :live_provider) do
      nil -> [{@default_name, fn -> check(opts, nil) end}]
      selection -> selected_jobs(opts, selection)
    end
  end

  # ---- Selection ----

  defp selected_jobs(opts, selection) do
    config = load_config(opts)
    opts = Keyword.put(opts, :config, config)
    known = config |> known_providers() |> assign_display_ids()

    case resolve_selection(selection, known) do
      {:ok, entries, omitted} ->
        jobs =
          Enum.map(entries, fn {_key, display} = entry ->
            {job_name(display), fn -> check(opts, entry) end}
          end)

        jobs ++ omitted_job(omitted)

      :unknown ->
        [
          {@default_name,
           fn ->
             Check.fail(
               @default_name,
               "The named provider is not configured or recognized.",
               "Check the name against [providers.*] in your config, or run `lemon doctor --live --provider all`."
             )
           end}
        ]
    end
  rescue
    _ -> [{@default_name, fn -> Check.fail(@default_name, "Provider selection failed.") end}]
  end

  defp load_config(opts) do
    Keyword.get(opts, :config) ||
      Config.load(Keyword.get(opts, :project_dir, File.cwd!()), cache: false)
  end

  # Original configured keys, default provider first, then configured keys sorted.
  # Keys are never rewritten: they are what the resolver looks up. A configured
  # key repeating the default provider (by its actual key) is dropped.
  defp known_providers(config) do
    default = config |> agent_default_provider() |> raw_key()

    configured =
      config
      |> providers_map()
      |> Map.keys()
      |> Enum.map(&raw_key/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    case default do
      nil -> configured
      default -> [default | Enum.reject(configured, &(&1 == default))]
    end
  end

  # Pairs each key with a bounded display id used only for result names and
  # messages. Colliding display ids get a key-derived suffix, so distinct
  # providers never share a result name.
  defp assign_display_ids(keys) do
    {entries, _seen} =
      Enum.map_reduce(keys, MapSet.new(), fn key, seen ->
        display = unique_display(key, clean_id(key) || "provider", seen, 0)
        {{key, display}, MapSet.put(seen, display)}
      end)

    entries
  end

  defp unique_display(key, base, seen, attempt) do
    candidate = if attempt == 0, do: base, else: suffixed(key, base, attempt)

    if MapSet.member?(seen, candidate),
      do: unique_display(key, base, seen, attempt + 1),
      else: candidate
  end

  defp suffixed(key, base, attempt) do
    hash =
      :crypto.hash(:sha256, "#{attempt}:#{key}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 6)

    String.slice(base, 0, @max_name - 7) <> "_" <> hash
  end

  defp resolve_selection("all", known) do
    {entries, omitted} = Enum.split(known, @max_providers)
    {:ok, entries, length(omitted)}
  end

  defp resolve_selection(name, known) do
    wanted = identity(name)

    cond do
      entry = Enum.find(known, fn {key, _} -> key == name end) ->
        {:ok, [entry], 0}

      entry = Enum.find(known, fn {key, _} -> identity(key) == wanted end) ->
        {:ok, [entry], 0}

      CustomProviders.builtin?(name) ->
        {:ok, [{name, clean_id(name) || "provider"}], 0}

      true ->
        :unknown
    end
  end

  defp omitted_job(0), do: []

  defp omitted_job(count) do
    name = @default_name <> ".more"

    [
      {name,
       fn ->
         Check.skip(
           name,
           "#{count} more provider(s) not checked (limit #{@max_providers}); " <>
             "use `--provider NAME` to check one."
         )
       end}
    ]
  end

  defp job_name(id), do: "#{@default_name}.#{id}"

  defp agent_default_provider(%{agent: agent}) when is_map(agent),
    do: Map.get(agent, :default_provider)

  defp agent_default_provider(_), do: nil

  defp providers_map(%{providers: providers}) when is_map(providers), do: providers
  defp providers_map(_), do: %{}

  defp raw_key(value) when is_atom(value) and not is_nil(value),
    do: raw_key(Atom.to_string(value))

  defp raw_key(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp raw_key(_), do: nil

  # Display ids become check names: keep a conservative, bounded alphabet.
  defp clean_id(value) when is_binary(value) do
    case value
         |> LemonCore.Redact.text()
         |> String.trim()
         |> String.replace(~r/[^A-Za-z0-9._-]/u, "_") do
      "" -> nil
      cleaned -> String.slice(cleaned, 0, @max_name)
    end
  end

  defp identity(value) do
    ProviderNames.canonical_name(value) ||
      value |> to_string() |> String.trim() |> String.downcase() |> String.replace("-", "_")
  end

  # ---- Probe ----

  # `entry` is nil for the default-provider check (`providers.live`); otherwise
  # `{key, display}`: `key` is the configured provider key handed to the
  # resolver, `display` is the sanitized id used in result names and messages.
  defp check(opts, entry) do
    name = name_for(entry)
    config = load_config(opts)

    input_fn = Keyword.get(opts, :provider_live_input, &Verification.live_input/1)

    verifier =
      Keyword.get(
        opts,
        :provider_live_check,
        &ProviderLiveCheck.check(&1, Keyword.put(opts, :extended, true))
      )

    input_opts = [config: config, non_generating: true]

    input_opts =
      case entry do
        {key, _display} -> Keyword.put(input_opts, :provider, key)
        nil -> input_opts
      end

    with {:ok, input} <- input_fn.(input_opts),
         {:ok, _} <- verifier.(input) do
      Check.pass(name, label(entry) <> " accepted a non-generating models request.")
    else
      {:skip, {:unsupported_api, _}} ->
        Check.skip(name, "Skipped (no non-generating endpoint).")

      {:skip, _} ->
        Check.skip(name, skip_unresolvable(entry))

      {:error, :credential_not_usable} ->
        Check.skip(name, "Skipped (no usable provider credential).")

      {:error, reason} ->
        Check.fail(name, prefixed(entry, ProviderLiveCheck.doctor_failure_message(reason)))
    end
  rescue
    _ -> Check.fail(name_for(entry), "Provider live check could not complete.")
  end

  defp name_for(nil), do: @default_name
  defp name_for({_key, display}), do: job_name(display)

  defp label(nil), do: "Default provider"
  defp label({_key, display}), do: "Provider #{display}"

  defp prefixed(nil, message), do: message
  defp prefixed({_key, display}, message), do: "#{display}: #{message}"

  defp skip_unresolvable(nil),
    do: "Skipped (default provider or model is not configured/resolvable)."

  defp skip_unresolvable(_entry), do: "Skipped (provider or model is not resolvable)."
end
