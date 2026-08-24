defmodule CodingAgent.PythonRepl.Key do
  @moduledoc """
  Canonical identity of a persistent Python interpreter.

  A key selects which kernel state a call attaches to. It contains only
  stable, security-relevant identity:

    * `scope_id` — the persisted `CodingAgent.SessionManager` header id
    * `agent_id` — the agent/profile id within that session
    * `cwd` — canonical (expanded, symlink-resolved) working directory
    * `interpreter` — canonical real interpreter executable path
    * `helpers` — sorted, de-duplicated enabled helper names
    * `protocol_version` — runner protocol version

  Volatile or caller-overridable values must never participate: passing
  `run_id`, a tool-call id, `session_key`, or `policy` is rejected. Helper
  authorization is re-evaluated per cell, so no policy capability is cached
  in the key.

  Any change to a canonical field selects a different kernel; state is never
  migrated between keys.
  """

  @forbidden_fields ~w(run_id tool_call_id session_key policy)a

  defstruct [:scope_id, :agent_id, :cwd, :interpreter, :helpers, :protocol_version, :digest]

  @type t :: %__MODULE__{
          scope_id: String.t(),
          agent_id: String.t(),
          cwd: String.t(),
          interpreter: String.t(),
          helpers: [String.t()],
          protocol_version: pos_integer(),
          digest: String.t()
        }

  @type error ::
          {:forbidden_field, atom()}
          | {:missing_field, atom()}
          | {:invalid_scope_id, term()}
          | {:invalid_agent_id, term()}
          | {:cwd_not_found, String.t()}
          | {:cwd_not_directory, String.t()}
          | {:interpreter_not_found, String.t()}
          | {:interpreter_not_executable, String.t()}
          | {:invalid_helper, term()}
          | {:invalid_protocol_version, term()}

  @doc """
  Builds a canonical key from a map (or keyword list) of attributes.

  `cwd` and `interpreter` are expanded (`~` and relative paths) and resolved
  to their real paths; the interpreter may be given as a bare name, which is
  resolved through `PATH`. Helpers are sorted and de-duplicated. Returns
  `{:error, reason}` when identity is missing, non-canonicalizable, or
  contains a forbidden volatile field.
  """
  @spec new(map() | keyword()) :: {:ok, t()} | {:error, error()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)

    with :ok <- reject_forbidden(attrs),
         {:ok, scope_id} <- identity_string(attrs, :scope_id, {:invalid_scope_id, :scope_id}),
         {:ok, agent_id} <- identity_string(attrs, :agent_id, {:invalid_agent_id, :agent_id}),
         {:ok, cwd} <- canonical_dir(attrs),
         {:ok, interpreter} <- canonical_interpreter(attrs),
         {:ok, helpers} <- canonical_helpers(attrs),
         {:ok, version} <- protocol_version(attrs) do
      key = %__MODULE__{
        scope_id: scope_id,
        agent_id: agent_id,
        cwd: cwd,
        interpreter: interpreter,
        helpers: helpers,
        protocol_version: version,
        digest: digest(scope_id, agent_id, cwd, interpreter, helpers, version)
      }

      {:ok, key}
    end
  end

  def new(_attrs), do: {:error, {:missing_field, :scope_id}}

  @doc """
  The stable SHA-256 digest of the canonical key material.

  Two calls attach to the same kernel state exactly when their keys (and
  therefore digests) are equal.
  """
  @spec digest(t()) :: String.t()
  def digest(%__MODULE__{digest: digest}), do: digest

  defp reject_forbidden(attrs) do
    case Enum.find(@forbidden_fields, &Map.has_key?(attrs, &1)) do
      nil -> :ok
      field -> {:error, {:forbidden_field, field}}
    end
  end

  defp identity_string(attrs, field, error) do
    case Map.fetch(attrs, field) do
      {:ok, value} when is_binary(value) ->
        if String.trim(value) == "" do
          {:error, {elem(error, 0), value}}
        else
          {:ok, value}
        end

      {:ok, value} ->
        {:error, {elem(error, 0), value}}

      :error ->
        {:error, {:missing_field, field}}
    end
  end

  defp canonical_dir(attrs) do
    case Map.fetch(attrs, :cwd) do
      {:ok, path} when is_binary(path) and path != "" ->
        expanded = Path.expand(path)

        case real_path(expanded) do
          {:ok, real} ->
            if File.dir?(real) do
              {:ok, real}
            else
              {:error, {:cwd_not_directory, expanded}}
            end

          {:error, _reason} ->
            {:error, {:cwd_not_found, expanded}}
        end

      {:ok, value} ->
        {:error, {:cwd_not_found, value}}

      :error ->
        {:error, {:missing_field, :cwd}}
    end
  end

  defp canonical_interpreter(attrs) do
    case Map.fetch(attrs, :interpreter) do
      {:ok, path} when is_binary(path) and path != "" ->
        case expand_or_locate(path) do
          nil ->
            {:error, {:interpreter_not_found, path}}

          candidate ->
            case real_path(candidate) do
              {:ok, real} ->
                if File.regular?(real) and executable?(real) do
                  {:ok, real}
                else
                  {:error, {:interpreter_not_executable, candidate}}
                end

              {:error, _reason} ->
                {:error, {:interpreter_not_found, path}}
            end
        end

      {:ok, value} ->
        {:error, {:interpreter_not_found, value}}

      :error ->
        {:error, {:missing_field, :interpreter}}
    end
  end

  # A path with a separator is expanded in place; a bare name is looked up
  # on PATH just like spawn would.
  defp expand_or_locate(path) do
    if String.contains?(path, "/") do
      Path.expand(path)
    else
      System.find_executable(path)
    end
  end

  # Canonical absolute path with every symlink resolved (realpath(3)
  # semantics). `:file.realpath/1` is not available on all OTP releases, so
  # components are resolved one by one; fuel bounds symlink cycles.
  defp real_path(path) do
    resolve_parts(Path.split(Path.expand(path)), [], 128)
  end

  defp resolve_parts([], acc, _fuel), do: {:ok, join_parts(acc)}

  defp resolve_parts(["." | rest], acc, fuel), do: resolve_parts(rest, acc, fuel)

  # The parent of the root is the root.
  defp resolve_parts([".." | rest], ["/"] = acc, fuel), do: resolve_parts(rest, acc, fuel)

  defp resolve_parts([".." | rest], [_ | acc], fuel), do: resolve_parts(rest, acc, fuel)

  defp resolve_parts([part | rest], acc, fuel) do
    path = join_parts([part | acc])

    case File.read_link(path) do
      {:ok, target} when fuel > 1 ->
        if Path.type(target) == :absolute do
          resolve_parts(Path.split(target) ++ rest, [], fuel - 1)
        else
          resolve_parts(Path.split(target) ++ rest, acc, fuel - 1)
        end

      {:ok, _target} ->
        {:error, :too_many_symlinks}

      {:error, _reason} ->
        # realpath(3) fails when any component of the path is missing.
        if File.exists?(path) do
          resolve_parts(rest, [part | acc], fuel)
        else
          {:error, :enoent}
        end
    end
  end

  # `acc` is reversed, root-first at the bottom; `Path.join/1` collapses
  # the leading root marker without doubling the separator.
  defp join_parts(acc), do: acc |> Enum.reverse() |> Path.join()

  # `File.access?/2` is unavailable on recent Elixir; an interpreter is
  # usable when any execute bit is set.
  defp executable?(path) do
    case File.stat(path) do
      {:ok, stat} -> Bitwise.band(stat.mode, 0o111) != 0
      {:error, _reason} -> false
    end
  end

  defp canonical_helpers(attrs) do
    case Map.fetch(attrs, :helpers) do
      {:ok, helpers} when is_list(helpers) ->
        if Enum.all?(helpers, &helper_name?/1) do
          {:ok, helpers |> Enum.uniq() |> Enum.sort()}
        else
          {:error, {:invalid_helper, Enum.find(helpers, &(not helper_name?(&1)))}}
        end

      {:ok, value} ->
        {:error, {:invalid_helper, value}}

      :error ->
        {:error, {:missing_field, :helpers}}
    end
  end

  defp helper_name?(name) when is_binary(name) and name != "", do: true
  defp helper_name?(_), do: false

  defp protocol_version(attrs) do
    case Map.fetch(attrs, :protocol_version) do
      {:ok, version} when is_integer(version) and version > 0 -> {:ok, version}
      {:ok, version} -> {:error, {:invalid_protocol_version, version}}
      :error -> {:error, {:missing_field, :protocol_version}}
    end
  end

  # Length-prefixed fields make the digest input unambiguous regardless of
  # the values' contents; the sorted helper list uses a NUL separator for
  # the same reason.
  defp digest(scope_id, agent_id, cwd, interpreter, helpers, version) do
    fields = [
      {"scope_id", scope_id},
      {"agent_id", agent_id},
      {"cwd", cwd},
      {"interpreter", interpreter},
      {"helpers", Enum.join(helpers, <<0>>)},
      {"protocol_version", Integer.to_string(version)}
    ]

    payload =
      Enum.map_join(fields, "\n", fn {name, value} ->
        "#{byte_size(value)}:#{name}=#{value}"
      end)

    :crypto.hash(:sha256, payload)
    |> Base.encode16(case: :lower)
  end
end
