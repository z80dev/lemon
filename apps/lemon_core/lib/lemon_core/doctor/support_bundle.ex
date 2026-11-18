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
          supervised: false,
          running: false,
          active_jobs: 0,
          workers: 0,
          supervisors: 0,
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

  # Raw names stay inside the diagnostics; the shareable projection is
  # applied here, at the output boundary.
  defp provider_diagnostics(opts) do
    [project_dir: Keyword.get(opts, :project_dir, File.cwd!())]
    |> LemonCore.Doctor.ProviderDiagnostics.status()
    |> LemonCore.Doctor.ProviderDiagnostics.public_status()
  end

  defp usage_diagnostics do
    LemonCore.UsageDiagnostics.status()
    |> Map.update(:providers, [], fn providers ->
      Enum.map(
        providers,
        &Map.update!(&1, :provider, fn p ->
          LemonCore.Doctor.ProviderDiagnostics.public_provider(p)
        end)
      )
    end)
  end

  # The config is reported as a diagnostic projection, never its values:
  # booleans and small numbers keep their value; a string keeps its value only
  # when it is a member of that field's explicit enum set (otherwise "other");
  # provider names use `ProviderDiagnostics.public_provider/1` (custom names
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
             {LemonCore.Doctor.ProviderDiagnostics.public_provider(name),
              project_value(nil, entry)}
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
    do: LemonCore.Doctor.ProviderDiagnostics.public_provider(value)

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
