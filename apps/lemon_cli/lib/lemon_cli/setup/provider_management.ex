defmodule LemonCli.Setup.ProviderManagement do
  @moduledoc """
  Destination-local, write-only provider configuration service.

  The authorized transport supplies `:target` (`id`, `nodeId`, `hostname`) and
  validates the caller's exact target identity before invoking a mutation. This
  module does not authorize callers or accept workspace/profile configuration.
  Provider operations return a bounded, credential-free projection; public device
  operations return only their eight-field login status. The internal challenge
  operation additionally returns the target-issued, nonsecret completion nonce.

  API keys are stored only in encrypted `LemonCore.Secrets`; config contains a
  target-config-specific reference. Disconnect removes local credentials, not
  upstream grants, environment variables, project settings or pool references.
  Shared secret references fail closed rather than breaking another consumer.
  Defaults change only through `set_default/3` (or explicit CLI onboarding).

  Listing is static: it never refreshes OAuth, reads ambient vendor logins or
  invokes external secret sources. `lastValidation` describes a local resolver
  observation, not provider acceptance. Project/pool precedence and environment
  overrides are reported separately and never attest the saved global key.

  Writes serialize per expanded config path on this execution machine. Config
  replacement is atomic in the same directory; secret changes and reload failures
  are compensated. This is not a crash-atomic transaction across TOML and the
  encrypted store. A failed compensation returns `:rollback_failed`, never a
  success acknowledgement. Config/credential sizes and lock retries are bounded.

  Terminal onboarding may write an explicit config file outside the runtime's
  global/project paths. Such files are validated and saved without reloading
  unrelated runtime configuration; setup verifies the selected file separately.

  Codex device login uses `device_start/2`, `device_poll/2` and
  `device_cancel/2` with the exact five-field transport binding. Successful OAuth
  waits in the sensitive worker until internal `device_challenge/2` issues a
  target-local nonce and `device_complete/2` supplies it with a durably single-use
  completion ID. The five-second monotonic deadline is rechecked inside the
  serialized persistence transaction; no remote wall clock authorizes a write.
  Revocation never waits for completion; `commit: false` reconciles without writing.
  Replacing/disconnecting credentials still serialize with completion and never
  select a new default.

  `:config_path`, `:cwd`, `:secrets`, `:write_fun` and `:reload_fun` are local test
  seams, never RPC parameters. Production uses the target machine's global config,
  encrypted store and runtime config reload.
  """

  alias LemonAgent.ModelRuntime.ProviderNames
  alias LemonCli.Onboarding.{Provider, Providers, Runner}
  alias LemonCli.Setup.{DeviceLogin, ProviderAuth}
  alias LemonCore.{Config, Secrets}
  alias LemonCore.Config.TomlPatch

  @max_config_bytes 1_048_576
  @max_key_bytes 16_384
  @credential_keys ~w(api_key api_key_env api_key_secret oauth_secret auth_source auth)

  def list(opts \\ []) do
    with {:ok, target} <- target(opts) do
      locked(path(opts), fn -> listing(target, opts) end)
    end
  end

  def device_start(params, opts \\ []), do: device_operation(:start, params, opts)
  def device_poll(params, opts \\ []), do: device_operation(:poll, params, opts)
  def device_challenge(params, opts \\ []), do: device_operation(:challenge, params, opts)
  def device_cancel(params, opts \\ []), do: device_operation(:cancel, params, opts)
  def device_complete(params, opts \\ []), do: device_operation(:complete, params, opts)

  defp device_operation(operation, params, opts) do
    with {:ok, _target} <- target(opts) do
      apply(DeviceLogin, operation, [params, opts])
    end
  end

  @doc false
  def persist_device_login(secret, opts) when is_map(secret) do
    encoded = LemonAi.Auth.OpenAICodexOAuth.encode_secret(secret)

    with true <- byte_size(encoded) <= 65_536,
         true <- secret["type"] == "openai_codex_oauth",
         true <- present?(secret["access_token"]) and present?(secret["refresh_token"]),
         {:ok, spec} <- provider("openai_codex") do
      locked(path(opts), fn ->
        with {:ok, content, config} <- read_config(path(opts)),
             {:ok, project} <- project_config(opts) do
          spec = configured_spec(spec, config)
          name = managed_secret_name("openai_codex", path(opts))

          with :ok <- unshared(config, project, spec, [name]) do
            persist_locked(
              path(opts),
              [{name, {:set, encoded, spec.oauth_secret_provider}}],
              &Runner.update_provider_auth_config(&1, spec, :device, name),
              content,
              opts
            )
          end
        end
      end)
    else
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  def set_api_key(provider_id, value, opts \\ []) do
    with {:ok, target} <- target(opts),
         {:ok, spec} <- provider(provider_id),
         true <- "api_key" in Providers.management_methods(provider_id),
         :ok <- valid_key(value) do
      credential_mutation(target, provider_id, opts, fn ->
        locked(path(opts), fn ->
          with {:ok, content, config} <- read_config(path(opts)) do
            spec = configured_spec(spec, config)
            name = managed_secret_name(provider_id, path(opts))

            with {:ok, project} <- project_config(opts),
                 :ok <- unshared(config, project, spec, [name]),
                 :ok <-
                   persist_locked(
                     path(opts),
                     [{name, {:set, String.trim(value), "provider_management"}}],
                     &Runner.update_provider_auth_config(&1, spec, :api_key, name),
                     content,
                     opts
                   ) do
              listing(target, opts)
            end
          end
        end)
      end)
    else
      false -> {:error, :unsupported_method}
      {:error, _} = error -> error
    end
  end

  def disconnect(provider_id, opts \\ []) do
    with {:ok, target} <- target(opts),
         {:ok, spec} <- provider(provider_id) do
      credential_mutation(target, provider_id, opts, fn ->
        locked(path(opts), fn ->
          with {:ok, content, config} <- read_config(path(opts)) do
            spec = configured_spec(spec, config)

            cfg =
              ProviderNames.provider_config(Map.get(config, "providers", %{}), provider_id) || %{}

            names =
              [
                cfg["api_key_secret"],
                cfg["oauth_secret"],
                ProviderNames.default_secret_name(provider_id),
                ProviderNames.oauth_default_secret_name(provider_id)
              ]
              |> Enum.filter(&present?/1)
              |> Enum.uniq()

            with {:ok, project} <- project_config(opts),
                 :ok <- unshared(config, project, spec, names),
                 :ok <-
                   persist_locked(
                     path(opts),
                     Enum.map(names, &{&1, :delete}),
                     &clear_credentials(&1, spec),
                     content,
                     opts
                   ) do
              listing(target, opts)
            end
          end
        end)
      end)
    end
  end

  def set_default(provider_id, model_id, opts \\ []) do
    with {:ok, target} <- target(opts),
         {:ok, spec} <- provider(provider_id),
         :ok <- valid_model(model_id) do
      locked(path(opts), fn ->
        with {:ok, content, _config} <- read_config(path(opts)),
             :ok <-
               persist_locked(
                 path(opts),
                 [],
                 &Runner.maybe_set_defaults(&1, model_id, spec),
                 content,
                 opts
               ) do
          listing(target, opts)
        end
      end)
    end
  end

  defp credential_mutation(target, "openai_codex", opts, fun),
    do: DeviceLogin.with_cancelled(target.id, "openai_codex", fun, opts)

  defp credential_mutation(_target, _provider_id, _opts, fun), do: fun.()

  @doc false
  # Shared by terminal onboarding and logout. The patch runs inside the same
  # config lock as the API; secret snapshots precede every mutation.
  def persist(config_path, changes, patch, opts \\ []) do
    locked(config_path, fn ->
      with {:ok, content, _config} <- read_config(config_path) do
        persist_locked(config_path, changes, patch, content, opts)
      end
    end)
  end

  defp persist_locked(config_path, changes, patch, original, opts) do
    secrets = Keyword.get(opts, :secrets, Secrets)
    updated = patch.(original)

    with true <- byte_size(updated) <= @max_config_bytes and length(changes) <= 8,
         {:ok, _} <- decode(updated),
         {:ok, snapshots} <- snapshots(changes, secrets),
         {:ok, existed?} <- config_exists(config_path),
         :ok <- authorization_current(opts) do
      case apply_changes(changes, secrets, []) do
        {:ok, applied} ->
          case write_config(config_path, updated, opts) do
            :ok ->
              case reload(config_path, opts) do
                :ok ->
                  :ok

                {:error, _} = error ->
                  compensate(
                    config_path,
                    original,
                    existed?,
                    applied,
                    snapshots,
                    secrets,
                    opts,
                    error,
                    true
                  )
              end

            {:error, _} = error ->
              compensate(
                config_path,
                original,
                existed?,
                applied,
                snapshots,
                secrets,
                opts,
                error,
                false
              )
          end

        {:error, error, applied} ->
          compensate(
            config_path,
            original,
            existed?,
            applied,
            snapshots,
            secrets,
            opts,
            error,
            false
          )
      end
    else
      false -> {:error, :invalid_config}
      {:error, _} = error -> error
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp authorization_current(opts) do
    case Keyword.get(opts, :authorization_deadline) do
      nil ->
        :ok

      deadline when is_integer(deadline) ->
        clock =
          Keyword.get(opts, :device_monotonic_time, fn -> System.monotonic_time(:millisecond) end)

        if deadline > clock.(),
          do: :ok,
          else: {:error, :authorization_expired}
    end
  end

  defp snapshots(changes, secrets) do
    Enum.reduce_while(changes, {:ok, %{}}, fn {name, _}, {:ok, acc} ->
      case safe_secret(secrets, :snapshot, [name]) do
        {:ok, snapshot} -> {:cont, {:ok, Map.put(acc, name, {:present, snapshot})}}
        {:error, :not_found} -> {:cont, {:ok, Map.put(acc, name, :missing)}}
        _ -> {:halt, {:error, :secret_read_failed}}
      end
    end)
  end

  defp apply_changes([], _secrets, applied), do: {:ok, applied}

  defp apply_changes([{name, change} | rest], secrets, applied) do
    case change do
      {:set, value, provider} ->
        case safe_secret(secrets, :set, [name, value, [provider: provider]]) do
          {:ok, _} -> apply_changes(rest, secrets, [name | applied])
          _ -> {:error, {:error, :secret_write_failed}, [name | applied]}
        end

      :delete ->
        case safe_secret(secrets, :delete, [name]) do
          :ok -> apply_changes(rest, secrets, [name | applied])
          _ -> {:error, {:error, :secret_delete_failed}, [name | applied]}
        end
    end
  end

  defp compensate(
         config_path,
         original,
         existed?,
         applied,
         snapshots,
         secrets,
         opts,
         error,
         config_changed?
       ) do
    config_ok? =
      if config_changed? do
        if existed?,
          do: atomic_write(config_path, original) == :ok,
          else: File.rm(config_path) in [:ok, {:error, :enoent}]
      else
        true
      end

    secrets_ok? =
      Enum.reduce(applied, true, fn name, ok? ->
        restored? =
          case Map.fetch!(snapshots, name) do
            :missing ->
              safe_secret(secrets, :delete, [name]) == :ok

            {:present, snapshot} ->
              match?({:ok, _}, safe_secret(secrets, :restore, [name, snapshot]))
          end

        restored? and ok?
      end)

    reload_ok? =
      if config_changed? and config_ok?, do: reload(config_path, opts) == :ok, else: true

    if config_ok? and secrets_ok? and reload_ok?, do: error, else: {:error, :rollback_failed}
  end

  defp listing(target, opts) do
    with {:ok, _content, config} <- read_config(path(opts)),
         {:ok, project} <- project_config(opts) do
      rows =
        Enum.reduce_while(ProviderNames.all_canonical_names(), {:ok, []}, fn id, {:ok, acc} ->
          cfg = ProviderNames.provider_config(Map.get(config, "providers", %{}), id) || %{}
          observation = ProviderAuth.static_status(id, cfg, Keyword.get(opts, :secrets, Secrets))

          if observation[:error] do
            {:halt, {:error, :secret_read_failed}}
          else
            case environment_overrides(id, cfg, Keyword.get(opts, :secrets, Secrets)) do
              {:ok, environment} ->
                spec = Providers.find(ProviderNames.config_name(id))
                external? = external_precedence?(config, project, id) and not oauth_selected?(cfg)

                overrides =
                  configuration_overrides(config, project, id) ++
                    if(external?, do: ["external_secret_source"], else: [])

                configured? =
                  cfg != %{} or observation.configured or environment != [] or overrides != []

                blocked? = overrides != [] or (environment != [] and not oauth_selected?(cfg))

                row = %{
                  id: id,
                  displayName: if(spec, do: spec.display_name, else: display_name(id)),
                  methods: Providers.management_methods(ProviderNames.config_name(id)),
                  configured: configured?,
                  status: if(blocked?, do: "configured", else: observation.status),
                  lastValidation: if(blocked?, do: nil, else: observation.last_validation),
                  environmentOverrides: environment,
                  configurationOverrides: overrides
                }

                {:cont, {:ok, [row | acc]}}

              {:error, _} = error ->
                {:halt, error}
            end
          end
        end)

      defaults = effective_default(config, project)

      with {:ok, rows} <- rows do
        {:ok,
         %{
           target: target,
           default: defaults,
           providers: Enum.reverse(rows)
         }}
      end
    end
  end

  defp effective_default(config, project) do
    resolved =
      config
      |> LemonCore.MapHelpers.deep_merge(project)
      |> LemonCore.Config.Agent.resolve()

    provider_id = ProviderNames.canonical_name(resolved.default_provider)
    %{providerId: provider_id, modelId: default_model(resolved.default_model, provider_id)}
  end

  defp external_precedence?(config, project, id) do
    ProviderNames.env_vars(id) != [] and
      Enum.any?([config, project], fn settings ->
        case get_in(settings, ["secrets", "sources"]) do
          sources when is_map(sources) ->
            Enum.any?(sources, fn {_name, source} ->
              is_map(source) and source["enabled"] == true
            end)

          _ ->
            false
        end
      end)
  end

  defp configuration_overrides(config, project, id) do
    project? =
      not is_nil(ProviderNames.provider_config(Map.get(project, "providers", %{}), id)) or
        Map.has_key?(project, "provider_routing") or
        Map.has_key?(Map.get(project, "runtime", %{}), "provider_routing")

    pool? = pool_references_provider?(routing(config), id)

    if(project?, do: ["project_configuration"], else: []) ++
      if(pool?, do: ["credential_pool"], else: [])
  end

  defp pool_references_provider?(routing, id) do
    routing
    |> Map.get("credential_pools", %{})
    |> Enum.any?(fn {_name, pool} ->
      credentials = if is_map(pool), do: pool["credentials"] || %{}, else: %{}

      Enum.any?(credentials, fn {provider, refs} ->
        ProviderNames.canonical_name(provider) == id and refs not in [nil, []]
      end)
    end)
  end

  defp routing(config),
    do: get_in(config, ["runtime", "provider_routing"]) || config["provider_routing"] || %{}

  defp environment_overrides(id, cfg, secrets) do
    names =
      (ProviderNames.env_vars(id) ++ [cfg["api_key_env"]])
      |> Enum.filter(fn name ->
        is_binary(name) and byte_size(name) <= 128 and
          String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
      end)
      |> Enum.uniq()

    result =
      Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
        if present?(System.get_env(name)) do
          {:cont, {:ok, [name | acc]}}
        else
          # import-env stores canonical environment names in the encrypted store.
          # Those entries participate in runtime env-first credential resolution.
          # Never invoke Secrets.resolve/2 or external fallback for this metadata.
          case safe_secret(secrets, :get, [name]) do
            {:ok, value} ->
              {:cont, {:ok, if(present?(value), do: [name | acc], else: acc)}}

            {:error, reason} when reason in [:not_found, :expired] ->
              {:cont, {:ok, acc}}

            _ ->
              {:halt, {:error, :secret_read_failed}}
          end
        end
      end)

    case result do
      {:ok, overrides} -> {:ok, Enum.reverse(overrides)}
      {:error, _} = error -> error
    end
  end

  defp project_config(opts) do
    project_path = Config.project_path(Keyword.get(opts, :cwd, File.cwd!()))

    if Path.expand(project_path) == path(opts) do
      {:ok, %{}}
    else
      case read_config(project_path) do
        {:ok, _content, config} -> {:ok, config}
        {:error, _} = error -> error
      end
    end
  end

  defp unshared(config, project, spec, names) do
    without_selected =
      Enum.reduce(@credential_keys, config, fn key, acc ->
        # Remove only the selected provider's credential fields from the scan.
        table = String.replace_prefix(spec.provider_table, "providers.", "")

        update_in(
          acc,
          [Access.key("providers", %{}), Access.key(table, %{})],
          &Map.delete(&1, key)
        )
      end)

    if references_any?(without_selected, names) or references_any?(project, names),
      do: {:error, :shared_credential},
      else: :ok
  end

  defp references_any?(value, names) when is_map(value),
    do: Enum.any?(value, fn {_key, nested} -> references_any?(nested, names) end)

  defp references_any?(value, names) when is_list(value),
    do: Enum.any?(value, &references_any?(&1, names))

  defp references_any?(value, names) when is_binary(value),
    do: value in names or Enum.any?(names, &(value == "secret:" <> &1))

  defp references_any?(_, _), do: false

  defp configured_spec(spec, config) do
    tables = Map.get(config, "providers", %{})

    key =
      Enum.find(
        Map.keys(tables),
        &(ProviderNames.canonical_name(&1) == ProviderNames.canonical_name(spec.id))
      )

    if key, do: %{spec | provider_table: "providers.#{key}"}, else: spec
  end

  defp clear_credentials(content, spec),
    do: Enum.reduce(@credential_keys, content, &TomlPatch.delete_key(&2, spec.provider_table, &1))

  defp provider(id) when is_binary(id) do
    if id in ProviderNames.all_canonical_names() do
      config_name = ProviderNames.config_name(id)

      spec =
        Providers.find(config_name) ||
          Provider.api_key(config_name, display_name(id), "Runtime provider")

      {:ok, spec}
    else
      {:error, :invalid_provider}
    end
  end

  defp provider(_), do: {:error, :invalid_provider}

  defp valid_key(value) when is_binary(value) do
    if byte_size(value) <= @max_key_bytes and String.valid?(value) and present?(value) and
         not String.contains?(value, <<0>>),
       do: :ok,
       else: {:error, :invalid_api_key}
  end

  defp valid_key(_), do: {:error, :invalid_api_key}

  defp valid_model(value) when is_binary(value) do
    if byte_size(value) <= 256 and String.valid?(value) and value != "" and
         not String.match?(value, ~r/[\s\x00-\x1f\x7f]/u),
       do: :ok,
       else: {:error, :invalid_model}
  end

  defp valid_model(_), do: {:error, :invalid_model}

  defp target(opts) do
    case Keyword.get(opts, :target) do
      %{id: id, nodeId: node_id, hostname: hostname} when is_binary(id) and is_binary(hostname) ->
        if byte_size(id) in 1..256 and byte_size(hostname) in 1..255 and
             (is_nil(node_id) or (is_binary(node_id) and byte_size(node_id) in 1..256)),
           do: {:ok, %{id: id, nodeId: node_id, hostname: hostname}},
           else: {:error, :invalid_target}

      _ ->
        {:error, :invalid_target}
    end
  end

  defp default_model(value, id) when is_binary(value) and is_binary(id) do
    prefix = ProviderNames.config_name(id) <> ":"
    canonical_prefix = id <> ":"

    model =
      cond do
        String.starts_with?(value, prefix) ->
          String.replace_prefix(value, prefix, "")

        String.starts_with?(value, canonical_prefix) ->
          String.replace_prefix(value, canonical_prefix, "")

        true ->
          value
      end

    if valid_model(model) == :ok, do: model, else: nil
  end

  defp default_model(_, _), do: nil
  defp display_name(id), do: id |> String.replace("_", " ") |> String.capitalize()
  defp oauth_selected?(cfg), do: String.downcase(to_string(cfg["auth_source"] || "")) == "oauth"
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp path(opts), do: Path.expand(Keyword.get(opts, :config_path, Config.global_path()))

  defp managed_secret_name(id, config_path) do
    digest = :crypto.hash(:sha256, Path.expand(config_path)) |> Base.encode16(case: :lower)
    "provider_#{id}_#{binary_part(digest, 0, 24)}"
  end

  defp locked(config_path, fun) do
    case :global.trans({{__MODULE__, Path.expand(config_path)}, self()}, fun, [node()], 3) do
      :aborted -> {:error, :busy}
      result -> result
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end

  defp read_config(config_path) do
    with {:ok, exists?} <- config_exists(config_path) do
      if exists? do
        case File.open(config_path, [:read, :binary], &IO.binread(&1, @max_config_bytes + 1)) do
          {:ok, :eof} ->
            {:ok, "", %{}}

          {:ok, content} when is_binary(content) and byte_size(content) <= @max_config_bytes ->
            with {:ok, decoded} <- decode(content), do: {:ok, content, decoded}

          _ ->
            {:error, :config_read_failed}
        end
      else
        {:ok, "", %{}}
      end
    end
  end

  defp config_exists(config_path) do
    case File.lstat(config_path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_config_bytes -> {:ok, true}
      {:error, :enoent} -> {:ok, false}
      _ -> {:error, :config_read_failed}
    end
  end

  defp decode(content) do
    case Toml.decode(content) do
      {:ok, decoded} ->
        if Enum.all?(
             ~w(providers defaults runtime provider_routing),
             &(is_nil(decoded[&1]) or is_map(decoded[&1]))
           ) and
             Enum.all?(Map.get(decoded, "providers", %{}), fn {_id, cfg} -> is_map(cfg) end) and
             is_map(routing(decoded)) and
             is_map(Map.get(routing(decoded), "credential_pools", %{})) and
             Enum.all?(Map.get(routing(decoded), "credential_pools", %{}), fn {_id, pool} ->
               is_map(pool) and (is_nil(pool["credentials"]) or is_map(pool["credentials"]))
             end),
           do: {:ok, decoded},
           else: {:error, :invalid_config}

      _ ->
        {:error, :invalid_config}
    end
  end

  defp write_config(config_path, content, opts) do
    result =
      case Keyword.get(opts, :write_fun) do
        fun when is_function(fun, 2) -> safe_call(fn -> fun.(config_path, content) end)
        _ -> safe_call(fn -> atomic_write(config_path, content) end)
      end

    if result == :ok, do: :ok, else: {:error, :config_write_failed}
  end

  defp atomic_write(config_path, content) do
    config_path = Path.expand(config_path)
    directory = Path.dirname(config_path)
    temporary = Path.join(directory, ".provider-config-#{System.unique_integer([:positive])}")

    try do
      with :ok <- File.mkdir_p(directory),
           {:ok, file} <- File.open(temporary, [:write, :binary, :exclusive]) do
        written =
          try do
            with :ok <- File.chmod(temporary, 0o600),
                 :ok <- IO.binwrite(file, content),
                 :ok <- :file.sync(file),
                 do: :ok
          after
            File.close(file)
          end

        with :ok <- written, do: File.rename(temporary, config_path)
      end
    after
      File.rm(temporary)
    end
  end

  defp reload(config_path, opts) do
    result =
      safe_call(fn ->
        case Keyword.get(opts, :reload_fun) do
          fun when is_function(fun, 0) -> fun.()
          _ -> reload_runtime_config(config_path, Keyword.get(opts, :cwd))
        end
      end)

    if result == :ok or is_struct(result, Config), do: :ok, else: {:error, :reload_failed}
  end

  defp reload_runtime_config(config_path, cwd) do
    runtime_paths = [Config.global_path(), Config.project_path(cwd || File.cwd!())]

    if Path.expand(config_path) in Enum.map(runtime_paths, &Path.expand/1),
      do: Config.reload(cwd),
      else: :ok
  end

  defp safe_secret(module, function, args), do: safe_call(fn -> apply(module, function, args) end)

  defp safe_call(fun) do
    fun.()
  rescue
    _ -> {:error, :unavailable}
  catch
    _, _ -> {:error, :unavailable}
  end
end
