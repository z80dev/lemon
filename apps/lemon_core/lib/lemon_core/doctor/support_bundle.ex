defmodule LemonCore.Doctor.SupportBundle do
  @moduledoc """
  Builds sanitized support bundle archives from doctor reports, runtime
  diagnostics, and selected configuration files.

  The diagnostic sections describe a runtime, so they must be collected in the
  runtime they describe. `collect/1` builds them in the calling VM; the
  daemon exposes it through the `doctor.bundle` control-plane method, and a
  one-shot CLI that found a running daemon passes that reply to `write/2` as
  `:daemon_sections` instead of probing its own empty VM.

  Every entry passes through `LemonCore.Doctor.Redaction` when it is written,
  including sections received from a daemon, so the archive holds no
  absolute paths, chat/guild ids, credentials or inspected exception terms.
  """
  alias LemonCore.Config.Modular
  alias LemonCore.Doctor.{Redaction, Report}

  @env_allowlist ~w(
    LANG
    LEMON_CONTROL_PLANE_PORT
    LEMON_PATH
    LEMON_STORE_PATH
    LEMON_WEB_HOST
    LEMON_WEB_PORT
    MIX_ENV
    PHX_HOST
    TERM
  )

  @section_names ~w(
    environment.json
    browser_diagnostics.json
    channel_diagnostics.json
    checkpoint_diagnostics.json
    cron_diagnostics.json
    extension_diagnostics.json
    goal_diagnostics.json
    kanban_diagnostics.json
    lsp_diagnostics.json
    media_diagnostics.json
    memory_diagnostics.json
    provider_diagnostics.json
    terminal_diagnostics.json
    usage_diagnostics.json
    config/global_config.json
    config/project_config.json
  )

  @doc "Entry names of the diagnostic sections `collect/1` returns."
  @spec section_names() :: [String.t()]
  def section_names, do: @section_names

  @doc """
  Writes the bundle zip and returns its path.

  Options: `:bundle_path` or `:bundle_dir`, `:project_dir`, and
  `:daemon_sections` — the `entries` map from a daemon's `doctor.bundle`
  reply. With `:daemon_sections` only the known section names are taken from
  it and missing ones are marked unreported; without it the sections are
  collected in this VM.
  """
  @spec write(Report.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def write(%Report{} = report, opts \\ []) do
    path = bundle_path(opts)
    File.mkdir_p!(Path.dirname(path))

    {sections, source} =
      case Keyword.fetch(opts, :daemon_sections) do
        {:ok, sections} when is_map(sections) -> {daemon_sections(sections), "daemon"}
        _ -> {collect(opts), "local"}
      end

    entries =
      [
        {~c"README.txt", readme()},
        {~c"manifest.json", json(manifest(opts, source))},
        {~c"doctor_report.json", Report.to_json(report)}
      ] ++
        Enum.map(@section_names, fn name ->
          {String.to_charlist(name), json(Map.fetch!(sections, name))}
        end)

    case :zip.create(String.to_charlist(path), entries, []) do
      {:ok, _zip_path} -> {:ok, path}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Collects every diagnostic section in this VM, redacted, keyed by entry name.

  Only `:project_dir` (default: the current directory) and the per-section
  limits are read from `opts`.
  """
  @spec collect(keyword()) :: %{String.t() => term()}
  def collect(opts \\ []) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    opts = Keyword.put(opts, :project_dir, project_dir)

    %{
      "environment.json" => environment(),
      "browser_diagnostics.json" => browser_diagnostics(opts),
      "channel_diagnostics.json" => channel_diagnostics(opts),
      "checkpoint_diagnostics.json" => checkpoint_diagnostics(opts),
      "cron_diagnostics.json" => cron_diagnostics(opts),
      "extension_diagnostics.json" => extension_diagnostics(opts),
      "goal_diagnostics.json" => goal_diagnostics(opts),
      "kanban_diagnostics.json" => kanban_diagnostics(opts),
      "lsp_diagnostics.json" => lsp_diagnostics(),
      "media_diagnostics.json" => media_diagnostics(opts),
      "memory_diagnostics.json" => memory_diagnostics(),
      "provider_diagnostics.json" => provider_diagnostics(opts),
      "terminal_diagnostics.json" => terminal_diagnostics(),
      "usage_diagnostics.json" => usage_diagnostics(),
      "config/global_config.json" => config_section(Modular.global_path()),
      "config/project_config.json" => config_section(Modular.project_path(project_dir))
    }
    |> Map.new(fn {name, section} -> {name, Redaction.data(section)} end)
  end

  defp daemon_sections(sections) do
    Map.new(@section_names, fn name ->
      section =
        case Map.fetch(sections, name) do
          {:ok, section} -> Redaction.data(section)
          :error -> %{"available" => false, "error" => "not reported by the running daemon"}
        end

      {name, section}
    end)
  end

  defp bundle_path(opts) do
    case Keyword.get(opts, :bundle_path) do
      nil ->
        bundle_dir = Keyword.get(opts, :bundle_dir, "tmp/lemon-support-bundles")
        timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S")
        Path.expand(Path.join(bundle_dir, "lemon-doctor-bundle-#{timestamp}.zip"))

      path ->
        Path.expand(path)
    end
  end

  # Build and host metadata only: the project and working directories are
  # deliberately absent.
  defp manifest(opts, source) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())

    LemonCore.BuildInfo.current(cwd: project_dir)
    |> Map.merge(%{
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      bundle_version: 2,
      runtime_source: source
    })
    |> Redaction.data()
  end

  defp environment do
    @env_allowlist
    |> Enum.sort()
    |> Map.new(fn name ->
      value = System.get_env(name)
      {name, env_value(name, value)}
    end)
  end

  defp env_value(_name, nil), do: %{present: false, value: nil}

  defp env_value(name, value) do
    cond do
      LemonCore.Redact.sensitive_key?(name) -> %{present: true, value: "[redacted]"}
      String.ends_with?(name, "_PATH") -> %{present: true, value: Redaction.path_ref(value)}
      String.ends_with?(name, "_HOST") -> %{present: true, value_hash: Redaction.hash(value)}
      true -> %{present: true, value: value}
    end
  end

  defp browser_diagnostics(opts) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())

    %{
      local_server:
        probe(runtime_module(:browser_server), :status, [], %{
          available: false,
          running: false,
          error: "browser runtime not available",
          pending_requests: 0
        }),
      artifacts_dir: probe(runtime_module(:browser_artifacts), :default_dir, [project_dir], nil),
      artifact_summary:
        probe(runtime_module(:browser_artifacts), :summary, [[project_dir: project_dir]], %{
          available: false,
          error: "browser runtime not available"
        }),
      recent_artifacts:
        probe(
          runtime_module(:browser_artifacts),
          :recent,
          [[project_dir: project_dir, limit: 20]],
          []
        )
    }
  end

  defp channel_diagnostics(opts) do
    probe(
      runtime_module(:channel_diagnostics),
      :status,
      [[project_dir: Keyword.get(opts, :project_dir, File.cwd!())]],
      %{
        transports: [],
        registered_transports: [],
        binding_count: 0,
        unsupported_binding_count: 0,
        cleanup: %{
          includes_raw_bot_tokens: false,
          includes_secret_names: false,
          includes_chat_ids: false,
          includes_channel_ids: false,
          includes_guild_ids: false,
          includes_message_bodies: false
        }
      }
    )
  end

  defp checkpoint_diagnostics(opts) do
    LemonCore.Doctor.CheckpointDiagnostics.summary(:operator,
      checkpoint_dir: Keyword.get(opts, :checkpoint_dir),
      limit: Keyword.get(opts, :checkpoint_limit, 20)
    )
  end

  defp cron_diagnostics(opts) do
    LemonCore.Doctor.CronDiagnostics.status(limit: Keyword.get(opts, :cron_limit, 20))
  end

  defp extension_diagnostics(opts) do
    LemonCore.Doctor.ExtensionDiagnostics.status(
      project_dir: Keyword.get(opts, :project_dir, File.cwd!())
    )
  end

  defp goal_diagnostics(opts) do
    workspace_diagnostics(:goal, limit: Keyword.get(opts, :goal_limit, 20))
    |> Map.put_new(:cleanup, %{includes_objectives: false, includes_raw_session_ids: false})
  end

  defp kanban_diagnostics(opts) do
    workspace_diagnostics(:kanban, limit: Keyword.get(opts, :kanban_limit, 20))
    |> Map.put_new(:cleanup, %{
      includes_titles: false,
      includes_descriptions: false,
      includes_comments: false,
      includes_raw_session_ids: false
    })
  end

  # The workspace stores live in the agent runtime, which core must not depend
  # on; the reference runtime injects them via config.
  defp workspace_diagnostics(kind, args) do
    mod = Application.get_env(:lemon_core, :workspace_diagnostics, [])[kind]

    probe(mod, :diagnostics, [args], %{
      available: false,
      error: "agent workspace runtime not available"
    })
  end

  defp lsp_diagnostics do
    LemonCore.Doctor.LspDiagnostics.status()
  end

  defp media_diagnostics(opts) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())

    %{
      jobs_dir: probe(runtime_module(:media_jobs), :default_dir, [project_dir], nil),
      artifacts_dir:
        probe(runtime_module(:media_jobs), :default_artifacts_dir, [project_dir], nil),
      worker_status:
        probe(runtime_module(:media_supervisor), :status, [], %{
          running: false,
          active_jobs: 0,
          error: "media runtime not available"
        }),
      summary:
        probe(runtime_module(:media_jobs), :summary, [[project_dir: project_dir]], %{
          available: false,
          error: "media runtime not available"
        }),
      recent_jobs:
        probe(runtime_module(:media_jobs), :recent, [[project_dir: project_dir, limit: 20]], [])
    }
  end

  defp memory_diagnostics do
    probe(runtime_module(:memory_providers), :status, [], %{
      available: false,
      error: "memory runtime not available"
    })
  end

  defp terminal_diagnostics do
    LemonCore.TerminalBackends.diagnostics()
  end

  # Provider configuration shape plus the runtime's presence-mode credential
  # readiness (`LemonCore.CredentialReadiness`). Comparisons use raw names;
  # every rendered provider name goes through `ProviderIdentity.public_name/1`.
  @provider_secret_fields ~w(
    access_key_id_secret api_key_secret location_secret oauth_secret project_secret
    secret_access_key_secret service_account_json_secret session_token_secret
  )a
  @provider_inline_fields ~w(api_key service_account_json)a
  @provider_endpoint_fields ~w(
    api_version base_url deployment_name_map location project project_id region resource_name
  )a

  defp provider_diagnostics(opts) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())
    config = LemonCore.Config.load(project_dir, cache: false)
    agent = config.agent || %{}
    providers = config.providers || %{}
    routing = map_value(agent, :provider_routing) || %{}
    default_provider = map_value(agent, :default_provider)

    statuses =
      (Map.keys(providers) ++ [default_provider])
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
      |> Enum.uniq_by(&provider_key/1)
      |> Enum.sort()
      |> Enum.map(&provider_status(&1, providers, routing, project_dir))

    references = Enum.flat_map(statuses, & &1.secret_references)

    %{
      default_provider: LemonCore.ProviderIdentity.public_name(default_provider),
      default_model_configured: present_string?(map_value(agent, :default_model)),
      providers: Enum.map(statuses, &Map.delete(&1, :raw)),
      count: length(statuses),
      configured_count: Enum.count(statuses, & &1.configured),
      ready_count: Enum.count(statuses, & &1.credential_ready),
      credential_reference_count: length(references),
      credential_reference_present_count: Enum.count(references, & &1.present),
      routing: provider_routing_status(routing, statuses),
      cleanup: %{
        includes_raw_api_keys: false,
        includes_secret_names: false,
        includes_raw_base_urls: false,
        includes_env_var_names: false,
        includes_provider_responses: false,
        includes_model_prompts: false
      }
    }
  end

  defp provider_status(provider, providers, routing, project_dir) do
    cfg =
      Enum.find_value(providers, %{}, fn {name, cfg} ->
        if provider_key(name) == provider_key(provider) and is_map(cfg), do: cfg
      end)

    auth_source =
      case LemonCore.Config.Providers.normalize_auth_source(map_value(cfg, :auth_source)) do
        value when value in ["api_key", "oauth", "omp", "omp_broker"] -> value
        _ -> nil
      end

    %{
      raw: provider_key(provider),
      provider: LemonCore.ProviderIdentity.public_name(provider),
      configured: map_size(cfg) > 0,
      credential_ready:
        LemonCore.CredentialReadiness.ready?(provider, providers,
          provider_routing: routing,
          cwd: project_dir
        ),
      auth_source: auth_source,
      inline_credentials: configured_fields(cfg, @provider_inline_fields),
      endpoint_shape: configured_fields(cfg, @provider_endpoint_fields),
      secret_references:
        for field <- @provider_secret_fields, present_string?(map_value(cfg, field)) do
          %{
            field: Atom.to_string(field),
            configured: true,
            present:
              LemonCore.Secrets.presence(map_value(cfg, field),
                env_fallback: false,
                external_fallback: false
              ) == :present
          }
        end
    }
  end

  defp configured_fields(cfg, fields) do
    for field <- fields, map_value(cfg, field) not in [nil, ""] do
      %{field: Atom.to_string(field), configured: true}
    end
  end

  defp provider_routing_status(routing, statuses) do
    named = fn key ->
      case map_value(routing, key) do
        configs when is_map(configs) -> Enum.sort_by(configs, fn {name, _} -> label(name) end)
        _ -> []
      end
    end

    public = fn providers -> Enum.map(providers, &LemonCore.ProviderIdentity.public_name/1) end
    pools = named.(:credential_pools)
    profiles = named.(:profiles)

    %{
      enabled: map_value(routing, :enabled) != false,
      require_credentials: map_value(routing, :require_credentials) != false,
      fallback_providers: routing |> map_value(:fallback_providers) |> string_list() |> public.(),
      default_pool_configured: present_string?(map_value(routing, :default_pool)),
      default_profile_configured: present_string?(map_value(routing, :default_profile)),
      credential_pool_count: length(pools),
      profile_count: length(profiles),
      credential_pools:
        Enum.map(pools, fn {name, pool} ->
          providers = pool |> map_value(:providers) |> string_list()

          %{
            name_hash: label(name),
            provider_count: length(providers),
            providers: public.(providers),
            strategy:
              if(map_value(pool, :strategy) in [nil, "priority", "round_robin"],
                do: map_value(pool, :strategy) || "priority",
                else: "other"
              ),
            credential_reference_count:
              Enum.sum_by(providers, fn provider ->
                statuses
                |> Enum.find(%{secret_references: []}, &(&1.raw == provider_key(provider)))
                |> Map.fetch!(:secret_references)
                |> length()
              end)
          }
        end),
      profiles:
        Enum.map(profiles, fn {name, profile} ->
          distribution =
            case map_value(profile, :distribution) do
              weights when is_map(weights) ->
                weights
                |> Enum.map(fn {provider, weight} ->
                  %{provider: LemonCore.ProviderIdentity.public_name(provider), weight: weight}
                end)
                |> Enum.sort_by(& &1.provider)

              _ ->
                []
            end

          %{
            name_hash: label(name),
            fallback_providers:
              profile |> map_value(:fallback_providers) |> string_list() |> public.(),
            credential_pool_configured: present_string?(map_value(profile, :credential_pool)),
            distribution: distribution,
            distribution_count: length(distribution)
          }
        end)
    }
  end

  defp provider_key(name),
    do: name |> to_string() |> String.trim() |> String.downcase() |> String.replace("-", "_")

  defp string_list(values) when is_list(values),
    do: values |> Enum.map(&String.trim(to_string(&1))) |> Enum.reject(&(&1 == ""))

  defp string_list(value) when is_binary(value), do: value |> String.split(",") |> string_list()
  defp string_list(_), do: []

  defp map_value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp map_value(_, _), do: nil

  defp present_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp usage_diagnostics do
    LemonCore.UsageDiagnostics.status()
    |> Map.update(:providers, [], fn providers ->
      Enum.map(providers, &Map.update!(&1, :provider, fn p -> public_provider(p) end))
    end)
  end

  defp public_provider(name), do: LemonCore.ProviderIdentity.public_name(name)

  # The config is reported as a diagnostic projection, never its values:
  # booleans and small numbers keep their value; a string keeps its value only
  # when it is a member of that field's explicit enum set (otherwise "other");
  # provider names use `ProviderIdentity.public_name/1` (custom names
  # hashed); pool/profile/server/binding names and every reference to them
  # become the same "label:<hash>"; other strings become a presence flag,
  # lists counts, and credential-named fields and header/env containers
  # presence plus count. Keys outside the snake_case schema form are hashed.
  @config_enums %{
    "auth_source" => ~w(api_key oauth omp omp_broker env),
    "strategy" => ~w(priority round_robin),
    "thinking_level" => ~w(off minimal low medium high xhigh),
    "default_thinking_level" => ~w(off minimal low medium high xhigh),
    "level" => ~w(debug info notice warning error),
    "pull_policy" => ~w(never missing always),
    "network" => ~w(none bridge host),
    "isolation" => ~w(container process)
  }
  @config_provider_keys ~w(provider default_provider)
  @config_label_refs ~w(default_pool default_profile credential_pool profile pool)
  @config_secret_containers ~w(headers extra_headers http_headers env env_vars environment)
  @config_label_containers ~w(profiles agents mcp_servers servers bindings credential_pools accounts)
  @config_key ~r/\A[a-z][a-z0-9_]{0,63}\z/

  defp config_section(path) do
    case File.read(Path.expand(path)) do
      {:ok, content} ->
        case Toml.decode(content) do
          {:ok, config} -> %{present: true, settings: project_config(config)}
          {:error, _reason} -> %{present: true, parse_error: true}
        end

      {:error, :enoent} ->
        %{present: false}

      {:error, _reason} ->
        %{present: true, readable: false}
    end
  end

  defp project_config(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      key = to_string(key)

      cond do
        LemonCore.Redact.sensitive_key?(key) or key in @config_secret_containers ->
          {config_key(key), presence(value)}

        key == "providers" and is_map(value) ->
          {key,
           Map.new(value, fn {name, entry} ->
             {public_provider(name), project_value(nil, entry)}
           end)}

        key in @config_label_containers and is_map(value) ->
          {key, Map.new(value, fn {name, entry} -> {label(name), project_value(nil, entry)} end)}

        true ->
          {config_key(key), project_value(key, value)}
      end
    end)
  end

  defp project_value(_key, value) when is_boolean(value), do: value
  defp project_value(_key, value) when is_float(value), do: value
  defp project_value(_key, value) when is_integer(value) and abs(value) < 100_000, do: value
  defp project_value(_key, value) when is_integer(value), do: %{set: true}
  defp project_value(_key, value) when is_map(value), do: project_config(value)
  defp project_value(_key, value) when is_list(value), do: %{count: length(value)}

  defp project_value(key, value) when is_binary(value) and key in @config_provider_keys,
    do: public_provider(value)

  defp project_value(key, value) when is_binary(value) and key in @config_label_refs,
    do: label(value)

  defp project_value(key, value) when is_binary(value) and is_map_key(@config_enums, key),
    do: if(value in Map.fetch!(@config_enums, key), do: value, else: "other")

  defp project_value(_key, value) when is_binary(value), do: %{set: value != ""}
  defp project_value(_key, _value), do: %{set: true}

  defp label(name), do: "label:" <> Redaction.hash(to_string(name))

  defp config_key(key),
    do: if(Regex.match?(@config_key, key), do: key, else: "key:" <> Redaction.hash(key))

  defp presence(value) when is_map(value) or is_list(value),
    do: %{set: not Enum.empty?(value), count: Enum.count(value)}

  defp presence(value), do: %{set: value not in [nil, "", false]}

  defp json(data), do: Jason.encode!(data, pretty: true)

  defp readme do
    """
    Lemon doctor support bundle

    Generated by `lemon doctor --bundle` or `mix lemon.doctor --bundle`. When
    `lemon doctor` finds a running daemon, the diagnostic sections are collected
    by that daemon (manifest.json `runtime_source: "daemon"`); otherwise they
    describe the VM that wrote the bundle (`runtime_source: "local"`).

    Entries:

    - manifest.json: Lemon version, release name/version/channel, runtime mode,
      git commit/branch state, Elixir/OTP, OS, architecture, bundle version,
      runtime_source. No project or working directory.
    - doctor_report.json: the doctor checks (name, status, message,
      remediation) after the free-text policy below.
    - environment.json: presence of selected LEMON_* and host variables;
      *_PATH variables as a path hash and existence flag, *_HOST variables as a
      hash.
    - browser_diagnostics.json, channel_diagnostics.json,
      checkpoint_diagnostics.json, cron_diagnostics.json,
      extension_diagnostics.json, goal_diagnostics.json,
      kanban_diagnostics.json, lsp_diagnostics.json, media_diagnostics.json,
      memory_diagnostics.json, provider_diagnostics.json,
      terminal_diagnostics.json, usage_diagnostics.json: redacted runtime
      diagnostics (counts, statuses, cleanup flags, hashes).
    - config/global_config.json, config/project_config.json: a settings
      projection of the Lemon config files: booleans and small numbers;
      strings only when they belong to the field's enum set (auth_source,
      strategy, thinking_level, level, …), otherwise "other" or {"set"};
      built-in provider ids as is and custom provider names as
      "custom:<hash>"; profile, MCP server, binding and pool names and every
      reference to them as "label:<hash>"; lists as {"count"}; credential
      fields and header/env tables as presence and count; non-schema keys as
      "key:<hash>". Or whether the file is present.

    Every entry passes one redaction pass: directories and files appear only as
    {"path_hash", "exists"} or [path]; chat, guild, channel, thread, peer, user
    and session id fields are removed; owners, columns, accounts, names, file
    names, emails, phone numbers, senders and hosts become "sha:<hash>" or a
    count; credential fields read [redacted]; error terms read [term]. Free
    text has every URL collapsed to its scheme and a host hash, and emails,
    phone numbers and long digit runs replaced by [email], [phone] and [id].
    Browser driver errors appear only as a failure category and hash.

    Review before sharing. It should not contain provider keys, tokens, passwords,
    secret names, chat/channel/guild ids, absolute paths, private prompts,
    message bodies, memory contents, media bytes, or tool outputs.
    """
  end

  # Media, browser and LSP diagnostics are owned by other apps; core looks their
  # modules up through config rather than naming them.
  defp runtime_module(key), do: LemonCore.Doctor.RuntimeModules.fetch(key)

  defp probe(nil, _fun, _args, fallback), do: fallback

  defp probe(mod, fun, args, fallback) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, length(args)) do
      apply(mod, fun, args)
    else
      fallback
    end
  end
end
