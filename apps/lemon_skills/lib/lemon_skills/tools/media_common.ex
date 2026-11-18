defmodule LemonSkills.Tools.MediaCommon do
  @moduledoc false

  require Logger

  alias LemonAgent.ModelRuntime.{Credentials, ProviderNames}
  alias LemonAgent.Tools.AbortHelpers
  alias LemonMedia.MediaJobs

  @default_openai_base_url "https://api.openai.com/v1"

  @doc """
  Pairs an OpenAI-compatible media request's host with its credential.

  This is the only place media tools choose a host for a provider credential:

    * `openai` may use the explicit `override_key`/`override_base_url` tool
      options, then the `[providers.openai]` `base_url`, then the public
      OpenAI host.
    * Any other provider must have an explicit `base_url` in its own provider
      config and only ever resolves its own credential; the OpenAI overrides
      and the OpenAI default host are never used for it.

  Returns a runtime fragment (`provider`, `base_url`, `api_key`,
  `provider_cfg`) for `provider_api_key/3`, or a typed error string.
  """
  def openai_compatible_endpoint(provider, provider_cfg, override_key, override_base_url) do
    provider_cfg = provider_cfg || %{}
    configured_base_url = optional_string(provider_config_value(provider_cfg, :base_url))

    endpoint =
      if ProviderNames.canonical_name(provider) == "openai" do
        {:ok,
         %{
           provider: :openai,
           base_url: override_base_url || configured_base_url || @default_openai_base_url,
           api_key: override_key,
           provider_cfg: provider_cfg
         }}
      else
        case configured_base_url do
          nil ->
            {:error,
             "media provider #{provider} requires an explicit OpenAI-compatible base_url in [providers.#{provider}]"}

          base_url ->
            {:ok,
             %{provider: provider, base_url: base_url, api_key: nil, provider_cfg: provider_cfg}}
        end
      end

    case endpoint do
      {:ok, %{provider: provider, base_url: base_url}} ->
        Logger.info(
          "media provider endpoint resolved provider=#{provider} host=#{URI.parse(base_url).host}"
        )

      {:error, _} ->
        Logger.warning("media provider endpoint rejected provider=#{provider} reason=no_base_url")
    end

    endpoint
  end

  def timeout_ms(params, default, max_timeout) do
    value = Map.get(params, "timeoutMs", default)

    cond do
      is_integer(value) -> {:ok, value |> max(100) |> min(max_timeout)}
      is_binary(value) -> parse_timeout(value, max_timeout)
      true -> {:error, "timeoutMs must be an integer"}
    end
  end

  defp parse_timeout(value, max_timeout) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int |> max(100) |> min(max_timeout)}
      _ -> {:error, "timeoutMs must be an integer"}
    end
  end

  @doc """
  The artifact path for a media output, inside the artifacts directory.

  The host's `:output_guard` (the coding agent's tool registry and browser
  tools pass `CodingAgent.Tools.OperatorState.check_mutation/1`) must accept
  the path, so a default or configured artifacts directory that resolves into
  Lemon operator state is refused. Without a guard the call fails closed; only
  a trusted internal caller with no operator state to protect passes
  `output_guard: :none`. Write the bytes with `write_artifact/2`.
  """
  def artifact_path(params, cwd, opts, format, prefix) do
    artifacts_dir =
      opts
      |> Keyword.get(:media_artifacts_dir, MediaJobs.default_artifacts_dir(cwd))
      |> Path.expand()

    name = sanitize_filename(Map.get(params, "filename"), format, prefix)
    path = Path.join(artifacts_dir, name)

    cond do
      not String.starts_with?(Path.expand(path), artifacts_dir <> "/") ->
        {:error, "artifact path escaped media artifact directory"}

      (guarded = output_guard(opts, path)) != :ok ->
        guarded

      true ->
        {:ok, path}
    end
  end

  defp output_guard(opts, path) do
    case Keyword.get(opts, :output_guard) do
      guard when is_function(guard, 1) -> guard.(path)
      :none -> :ok
      _ -> {:error, "media output guard is not configured; refusing to write #{path}"}
    end
  end

  @doc """
  Writes an artifact through an exclusive temporary file renamed over `path`,
  so an existing symlink or hard link at `path` is replaced, never written
  through: the inode it aliases is not modified.
  """
  @spec write_artifact(String.t(), iodata()) :: :ok | {:error, term()}
  def write_artifact(path, bytes) do
    dir = Path.dirname(path)
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    temp = Path.join(dir, ".#{Path.basename(path)}.tmp-#{suffix}")

    with :ok <- File.mkdir_p(dir) do
      try do
        with :ok <- File.write(temp, bytes, [:exclusive]), do: File.rename(temp, path)
      after
        File.rm(temp)
      end
    end
  end

  defp sanitize_filename(value, format, prefix) when is_binary(value) do
    value
    |> Path.basename()
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")
    |> String.slice(0, 96)
    |> case do
      "" -> default_filename(format, prefix)
      name -> ensure_extension(name, format)
    end
  end

  defp sanitize_filename(_value, format, prefix), do: default_filename(format, prefix)

  defp default_filename(format, prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}.#{format}"
  end

  defp ensure_extension(name, format) do
    if String.downcase(Path.extname(name)) == ".#{format}" do
      name
    else
      "#{Path.rootname(name)}.#{format}"
    end
  end

  def media_job_opts(cwd, opts, artifact_path, runner) do
    [
      project_dir: cwd,
      dir: Keyword.get(opts, :media_jobs_dir),
      artifacts_dir: Path.dirname(artifact_path),
      runner: runner
    ]
  end

  def provider_api_key(runtime, missing, provider \\ :openai)

  def provider_api_key(%{api_key: key}, _missing, _provider) when is_binary(key) and key != "",
    do: {:ok, key}

  def provider_api_key(%{provider_cfg: provider_cfg}, missing, provider) do
    case Credentials.resolve_provider_api_key(provider, provider_cfg, provider_cfg: true) do
      key when is_binary(key) and key != "" -> {:ok, key}
      _ -> {:error, missing}
    end
  end

  def transient_status?(status) when status in [408, 409, 425, 429], do: true
  def transient_status?(status) when is_integer(status) and status >= 500, do: true
  def transient_status?(_status), do: false

  def wait_for_job(job_id, timeout_ms, signal) do
    receive do
      {:media_job, :completed, %{job_id: ^job_id} = job} ->
        {:ok, job}

      {:media_job, :failed, %{job_id: ^job_id} = job} ->
        {:error, "media job failed: #{Map.get(job, :error_kind, "unknown")}"}

      {:media_job, _event, %{job_id: ^job_id}} ->
        case AbortHelpers.check_abort(signal) do
          :ok -> wait_for_job(job_id, timeout_ms, signal)
          {:error, reason} -> {:error, reason}
        end

      _other ->
        wait_for_job(job_id, timeout_ms, signal)
    after
      timeout_ms -> {:error, "media job timed out after #{timeout_ms}ms"}
    end
  end

  def payload(job, artifact_path, default_mime, hash_kind) do
    artifact_name = get_in(job, [:artifact, :name]) || Path.basename(artifact_path)
    mime_type = get_in(job, [:artifact, :mime_type]) || default_mime

    artifact = %{
      "path" => artifact_path,
      "filename" => artifact_name,
      "mime_type" => mime_type,
      "bytes" => artifact_bytes(artifact_path)
    }

    %{
      "job_id" => job.job_id,
      "status" => Atom.to_string(job.status),
      "type" => Atom.to_string(job.type),
      "provider" => job.provider,
      "model" => job.model,
      "#{hash_kind}_hash" => job.prompt_hash,
      "#{hash_kind}_chars" => job.prompt_chars,
      "artifact" => artifact,
      "media_job" => redacted_job(job)
    }
  end

  def redacted_job(job) do
    job
    |> Map.take([
      :job_id,
      :type,
      :status,
      :provider,
      :model,
      :artifact,
      :prompt_hash,
      :prompt_chars,
      :created_at,
      :updated_at
    ])
    |> stringify_atoms()
  end

  def stringify_atoms(value) when is_map(value) do
    Map.new(value, fn {key, value} -> {to_string(key), stringify_atoms(value)} end)
  end

  def stringify_atoms(value) when is_atom(value), do: Atom.to_string(value)
  def stringify_atoms(value) when is_list(value), do: Enum.map(value, &stringify_atoms/1)
  def stringify_atoms(value), do: value

  def maybe_auto_send(payload, params, caption) do
    if Map.get(params, "sendToChannel") == true do
      Map.put(payload, "auto_send_files", [
        %{
          "path" => payload["artifact"]["path"],
          "filename" => payload["artifact"]["filename"],
          "caption" => caption,
          "source" => "generated"
        }
      ])
    else
      payload
    end
  end

  defp artifact_bytes(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.size
      {:error, _reason} -> nil
    end
  end

  def optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def optional_string(_value), do: nil

  def provider_config_value(cfg, key) when is_map(cfg) do
    Map.get(cfg, key) || Map.get(cfg, Atom.to_string(key))
  end

  def bounded_integer(value, min, max) when is_integer(value), do: value |> max(min) |> min(max)

  def bounded_integer(value, min, max) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> bounded_integer(int, min, max)
      _ -> min
    end
  end

  def bounded_integer(_value, min, _max), do: min

  def reject_blank_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) or value == "" end)
  end

  def provider_error_kind(%{"error" => error}) when is_map(error) do
    {:safe_error_kind,
     optional_string(error["type"]) || optional_string(error["status"]) ||
       optional_string(error["code"]) || "provider_error"}
  end

  def provider_error_kind(%{error: error}) when is_map(error) do
    provider_error_kind(%{
      "error" => %{"type" => error[:type], "status" => error[:status], "code" => error[:code]}
    })
  end

  def provider_error_kind(%{"detail" => detail}) when is_map(detail) do
    {:safe_error_kind,
     optional_string(detail["status"]) || optional_string(detail["type"]) ||
       optional_string(detail["code"]) || "provider_error"}
  end

  def provider_error_kind(%{detail: detail}) when is_map(detail) do
    provider_error_kind(%{
      "detail" => %{"status" => detail[:status], "type" => detail[:type], "code" => detail[:code]}
    })
  end

  def provider_error_kind(reason) when is_atom(reason),
    do: {:safe_error_kind, Atom.to_string(reason)}

  def provider_error_kind(_reason), do: {:safe_error_kind, "provider_error"}
end
