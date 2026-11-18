defmodule LemonSkills.McpConfig do
  @moduledoc """
  Named MCP configuration management. Mutations preserve unrelated JSON fields,
  serialize cooperating writers across VMs, and atomically replace private files.
  Reads never cache configuration; new sessions discover the next saved version.

  `set_enabled/3` maintains the per-name `disabled_servers` denylist and
  `enabled_servers` allowlist of the selected Lemon file; they apply to every
  merged source, including servers imported by `LemonSkills.McpDiscovery`.
  `list/1` with `all: true` reports the effective merged inventory.

  `trust_project/2` and `revoke_project_trust/1` maintain the operator's trust
  records for other tools' project MCP files in
  `LemonSkills.Config.mcp_project_trust_file/0` (agent directory only). A record
  binds an expanded project path to one digest from
  `LemonSkills.McpDiscovery.project_status/2`; project files never grant trust.
  """

  alias LemonSkills.{Config, McpDiscovery}

  @spec path(keyword()) :: String.t()
  def path(opts \\ []) do
    if opts[:global],
      do: Config.global_mcp_config_file(),
      else: Config.project_mcp_config_file(Keyword.get(opts, :cwd, File.cwd!()))
  end

  def list(opts \\ []) do
    if opts[:all] do
      cwd = if opts[:global], do: nil, else: Keyword.get(opts, :cwd, File.cwd!())
      {:ok, cwd |> Config.mcp_server_entries() |> Enum.map(&effective_summary/1)}
    else
      with {:ok, document, _original} <- load(path(opts)) do
        {:ok, Enum.map(Map.get(document, "servers", []), &summary/1)}
      end
    end
  end

  @doc """
  The exact entry `name` for `lemon mcp test`, which runs it, with its project
  provenance (`nil` for the global file). A project entry comes from the trusted
  project snapshot (`LemonSkills.McpDiscovery`), never from a fresh read:
  `{:error, :untrusted_project}` while the project's MCP files are untrusted or
  changed, and entries with host-secret references are absent. Pass the
  provenance to `LemonSkills.McpSession.open/5` so the spawn re-checks trust.
  """
  @spec fetch(String.t(), keyword()) ::
          {:ok, map(), %{project: String.t(), digest: String.t()} | nil} | {:error, atom()}
  def fetch(name, opts \\ []) do
    with {:ok, document, provenance} <- runnable_document(opts) do
      servers = if is_list(document["servers"]), do: document["servers"], else: []

      case Enum.filter(servers, &(is_map(&1) and &1["name"] == name)) do
        [entry] -> {:ok, entry, provenance}
        [] -> {:error, :not_found}
        _ -> {:error, :duplicate_name}
      end
    end
  end

  defp runnable_document(opts) do
    if opts[:global] do
      with {:ok, document, _original} <- load(path(opts)), do: {:ok, document, nil}
    else
      case McpDiscovery.project_config(Keyword.get(opts, :cwd, File.cwd!())) do
        %{trust: trust} when trust in [:untrusted, :changed] -> {:error, :untrusted_project}
        %{lemon: document, provenance: provenance} -> {:ok, document, provenance}
      end
    end
  end

  def add(entry, opts \\ []) do
    if valid_entry?(entry) do
      mutate(opts, fn document ->
        servers = Map.get(document, "servers", [])
        matches = Enum.filter(servers, &(&1["name"] == entry["name"]))

        case {matches, opts[:replace] == true} do
          {[], _} ->
            {:ok, Map.put(document, "servers", servers ++ [entry])}

          {[_], true} ->
            updated =
              Enum.map(servers, fn old ->
                if old["name"] == entry["name"], do: replace_entry(old, entry), else: old
              end)

            {:ok, Map.put(document, "servers", updated)}

          _ ->
            {:error, :duplicate_name}
        end
      end)
    else
      {:error, :invalid_entry}
    end
  end

  def remove(name, opts \\ []) do
    mutate(opts, fn document ->
      servers = Map.get(document, "servers", [])

      case Enum.count(servers, &(&1["name"] == name)) do
        0 -> {:error, :not_found}
        1 -> {:ok, Map.put(document, "servers", Enum.reject(servers, &(&1["name"] == name)))}
        _ -> {:error, :duplicate_name}
      end
    end)
  end

  @doc """
  Enable or disable `name` in the selected Lemon file.

  Enabling removes the name from `disabled_servers` and adds it to
  `enabled_servers`, which also overrides a source entry's own disabled flag.
  Disabling does the reverse. Project-file state takes precedence over the
  global file for the same name; within one file the denylist wins.
  """
  @spec set_enabled(String.t(), boolean(), keyword()) :: :ok | {:error, atom()}
  def set_enabled(name, enabled, opts \\ []) when is_boolean(enabled) do
    if valid_reference?(name) do
      {add, drop} =
        if enabled,
          do: {"enabled_servers", "disabled_servers"},
          else: {"disabled_servers", "enabled_servers"}

      mutate(opts, fn document ->
        with {:ok, added} <- name_list(document, add),
             {:ok, dropped} <- name_list(document, drop) do
          {:ok,
           document
           |> put_name_list(add, [name | added])
           |> put_name_list(drop, Enum.reject(dropped, &(&1 == name)))}
        end
      end)
    else
      {:error, :invalid_entry}
    end
  end

  @doc "Whether `name` can be referenced by enable/disable (includes imported names)."
  def valid_reference?(name) do
    is_binary(name) and byte_size(name) <= 128 and
      Config.validate_mcp_metadata(name: name) == :ok
  end

  @doc "Digest the operator trusted for other tools' MCP files in `cwd`, or `nil`."
  @spec project_trust(String.t()) :: String.t() | nil
  def project_trust(cwd) when is_binary(cwd) do
    with {:ok, %{"projects" => %{} = projects}, _bytes} <-
           load(Config.mcp_project_trust_file()),
         %{"digest" => digest} when is_binary(digest) <- projects[Path.expand(cwd)] do
      digest
    else
      _ -> nil
    end
  end

  @doc """
  Trust other tools' MCP files in `cwd` for exactly `digest`.

  `digest` must equal the current `LemonSkills.McpDiscovery.project_status/2`
  digest, so the operator approves the files they previewed; otherwise returns
  `{:error, :stale_digest}` (or `:no_project_config` without project files).
  Any later edit, addition or removal of a project file changes the digest and
  suspends trust.
  """
  @spec trust_project(String.t(), String.t()) :: :ok | {:error, atom()}
  def trust_project(cwd, digest) when is_binary(cwd) and is_binary(digest) do
    project = Path.expand(cwd)

    case McpDiscovery.project_status(project) do
      %{digest: nil} -> {:error, :no_project_config}
      %{digest: ^digest} -> update_project_trust(project, %{"digest" => digest})
      _ -> {:error, :stale_digest}
    end
  end

  @doc "Remove the operator's trust record for `cwd`, if any."
  @spec revoke_project_trust(String.t()) :: :ok | {:error, atom()}
  def revoke_project_trust(cwd) when is_binary(cwd),
    do: update_project_trust(Path.expand(cwd), nil)

  defp update_project_trust(project, record) do
    result =
      mutate_file(Config.mcp_project_trust_file(), fn document ->
        case Map.get(document, "projects", %{}) do
          %{} = projects ->
            projects =
              if record,
                do: Map.put(projects, project, record),
                else: Map.delete(projects, project)

            {:ok, Map.put(document, "projects", projects)}

          _ ->
            {:error, :invalid_config}
        end
      end)

    with {:ok, _original, _bytes} <- result, do: :ok
  end

  def valid_name?(name),
    do: is_binary(name) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/, name)

  def valid_entry?(entry) when is_map(entry) do
    valid_name?(entry["name"]) and entry["approval"] in ["always", "never"] and
      Config.validate_mcp_metadata(
        name: entry["name"],
        approval: entry["approval"],
        tool_approvals: Map.get(entry, "tool_approvals", %{})
      ) == :ok and valid_transport?(entry)
  end

  def valid_entry?(_), do: false

  defp valid_transport?(%{"type" => "stdio", "command" => command} = entry) do
    is_binary(command) and String.trim(command) != "" and
      is_list(entry["args"]) and Enum.all?(entry["args"], &is_binary/1) and
      valid_pairs?(Map.get(entry, "env", %{}), fn key, value ->
        key != "" and not String.contains?(key, ["=", <<0>>]) and
          not String.contains?(value, <<0>>)
      end)
  end

  defp valid_transport?(%{"type" => "http", "url" => url} = entry) when is_binary(url) do
    uri = URI.parse(url)

    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" and
      valid_pairs?(Map.get(entry, "headers", %{}), fn key, value ->
        key != "" and not String.contains?(key <> value, ["\r", "\n", <<0>>])
      end)
  end

  defp valid_transport?(_), do: false

  defp valid_pairs?(pairs, validator) when is_map(pairs) do
    Enum.all?(pairs, fn {key, value} ->
      is_binary(key) and is_binary(value) and validator.(key, value)
    end)
  end

  defp valid_pairs?(_, _), do: false

  defp name_list(document, key) do
    case Map.get(document, key, []) do
      names when is_list(names) ->
        if Enum.all?(names, &is_binary/1), do: {:ok, names}, else: {:error, :invalid_config}

      _ ->
        {:error, :invalid_config}
    end
  end

  defp put_name_list(document, key, names) do
    case names |> Enum.uniq() |> Enum.sort() do
      [] -> Map.delete(document, key)
      names -> Map.put(document, key, names)
    end
  end

  defp summary(entry) do
    %{
      "name" => if(valid_name?(entry["name"]), do: entry["name"], else: nil),
      "type" => if(entry["type"] in ["stdio", "http", "sse"], do: entry["type"], else: "unknown"),
      "approval" =>
        case entry["approval"] do
          nil -> "never"
          value when value in ["always", "never"] -> value
          _ -> "invalid"
        end,
      "tool_approval_count" => map_size_safe(entry["tool_approvals"]),
      "environment_count" => map_size_safe(entry["env"]),
      "header_count" => map_size_safe(entry["headers"])
    }
  end

  defp effective_summary(entry) do
    {type, opts} =
      case entry.config do
        {:stdio, _command, _args} -> {"stdio", []}
        {:stdio, _command, _args, opts} -> {"stdio", opts}
        {transport, _url} -> {Atom.to_string(transport), []}
        {transport, _url, opts} -> {Atom.to_string(transport), opts}
      end

    %{
      "name" => if(valid_reference?(entry.name), do: entry.name),
      "type" => type,
      "provider" => entry.source.provider,
      "scope" => Atom.to_string(entry.source.scope),
      "enabled" => entry.enabled,
      "source_enabled" => entry.source_enabled,
      "override" => entry.override && Atom.to_string(entry.override),
      "approval" =>
        if(Keyword.get(opts, :approval, :never) in [:never, "never"], do: "never", else: "always"),
      "tool_approval_count" => map_size_safe(Keyword.get(opts, :tool_approvals)),
      "environment_count" => length_safe(Keyword.get(opts, :env)),
      "header_count" => length_safe(Keyword.get(opts, :headers))
    }
  end

  defp length_safe(value) when is_list(value), do: length(value)
  defp length_safe(_), do: 0

  defp map_size_safe(value) when is_map(value), do: map_size(value)
  defp map_size_safe(_), do: 0

  # Retain unknown extensions and same-transport credentials unless explicitly
  # supplied. On transport changes remove only obsolete transport-specific keys.
  defp replace_entry(old, entry) do
    old =
      if old["type"] == entry["type"] do
        old
      else
        Map.drop(old, ["command", "args", "env", "cwd", "url", "headers", "oauth"])
      end

    Map.merge(old, entry, fn key, previous, replacement ->
      if key in ["env", "headers", "tool_approvals"] and is_map(previous) and is_map(replacement),
        do: Map.merge(previous, replacement),
        else: replacement
    end)
  end

  defp load(path) do
    case File.read(path) do
      {:ok, bytes} ->
        case Jason.decode(bytes) do
          {:ok, document} when is_map(document) ->
            servers = Map.get(document, "servers", [])

            if is_list(servers) and Enum.all?(servers, &is_map/1),
              do: {:ok, document, bytes},
              else: {:error, :invalid_config}

          _ ->
            {:error, :invalid_config}
        end

      {:error, :enoent} ->
        {:ok, %{}, nil}

      {:error, _} ->
        {:error, :read_failed}
    end
  end

  # Operator edits of a trusted (or still empty) project keep its trust record
  # bound to exactly the bytes written; see `McpDiscovery.operator_lemon_write/1`.
  defp mutate(opts, update) do
    project = if !opts[:global], do: Path.expand(Keyword.get(opts, :cwd, File.cwd!()))
    rebind = project && McpDiscovery.operator_lemon_write(project)

    with {:ok, original, bytes} <- mutate_file(path(opts), update) do
      case rebind && rebind.(original, bytes) do
        digest when is_binary(digest) -> update_project_trust(project, %{"digest" => digest})
        _ -> :ok
      end
    end
  end

  defp mutate_file(path, update) do
    lock = path <> ".lock"

    with :ok <- make_parent(path), :ok <- acquire_lock(lock) do
      try do
        with {:ok, document, original} <- load(path),
             {:ok, updated} <- update.(document),
             {:ok, bytes} <- save(path, updated, original) do
          {:ok, original, bytes}
        end
      after
        File.rmdir(lock)
      end
    end
  end

  defp make_parent(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> :ok
      _ -> {:error, :write_failed}
    end
  end

  defp acquire_lock(lock) do
    case File.mkdir(lock) do
      :ok -> :ok
      {:error, :eexist} -> {:error, :busy}
      _ -> {:error, :write_failed}
    end
  end

  defp save(path, document, original) do
    temp = path <> ".tmp." <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    bytes = Jason.encode!(document, pretty: true) <> "\n"

    try do
      with :ok <- write_private(temp, bytes),
           :ok <- unchanged(path, original),
           :ok <- File.rename(temp, path) do
        {:ok, bytes}
      else
        {:error, :changed} -> {:error, :changed}
        _ -> {:error, :write_failed}
      end
    after
      File.rm(temp)
    end
  end

  defp write_private(path, bytes) do
    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, io} ->
        try do
          with :ok <- File.chmod(path, 0o600),
               :ok <- IO.binwrite(io, bytes),
               :ok <- :file.sync(io),
               do: :ok
        after
          File.close(io)
        end

      error ->
        error
    end
  end

  defp unchanged(path, original) do
    case {File.read(path), original} do
      {{:error, :enoent}, nil} -> :ok
      {{:ok, bytes}, bytes} -> :ok
      _ -> {:error, :changed}
    end
  end
end
