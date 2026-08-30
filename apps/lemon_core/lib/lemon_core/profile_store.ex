defmodule LemonCore.ProfileStore do
  @moduledoc """
  Durable user-managed Lemon profiles over the canonical `[profiles.<id>]`
  configuration plane.

  A profile is an existing router agent profile with an owned filesystem home,
  not a second agent engine or routing system. Records stay in the global Lemon
  config so `LemonRouter.AgentProfiles` consumes the same name, model, prompt,
  and policy fields it already understands. Derived profile paths provide
  isolated bootstrap/memory and skill boundaries for native sessions:

      ~/.lemon/profiles/<id>/
      ├── profile.json
      ├── config.toml
      └── workspace/
          ├── memory/
          └── .lemon/skill/

  Lifecycle edits are serialized per config path and use atomic same-directory
  replacement. Targeted TOML patching preserves unrelated user keys/comments.
  Profile homes are always derived from the validated id; paths stored in TOML
  or imported data are never trusted.
  """

  alias LemonCore.Config.Modular
  alias LemonCore.Config.TomlPatch
  alias LemonCore.Paths
  alias LemonCore.RunRequest
  alias LemonCore.SessionKey

  @version 1
  @id_regex ~r/^[a-z0-9][a-z0-9_-]{0,63}$/
  @node_regex ~r/^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/
  @managed_keys ~w(name description avatar model system_prompt node status profile_version created_at updated_at)
  @max_description_bytes 4_096
  @max_prompt_bytes 65_536
  @max_export_files 256
  @max_export_file_bytes 1_048_576
  @max_export_total_bytes 8_388_608

  @type profile :: map()

  @doc "Return the current profile record format version."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "Return the managed global profile config path."
  @spec config_path(keyword()) :: String.t()
  def config_path(opts \\ []) do
    Keyword.get(opts, :config_path, Modular.global_path()) |> Path.expand()
  end

  @doc "Return derived, validated filesystem boundaries for a profile id."
  @spec paths(String.t(), keyword()) :: {:ok, map()} | {:error, :invalid_id}
  def paths(id, opts \\ []) do
    with :ok <- validate_id(id) do
      home = Paths.home_path(["profiles", id], path_opts(opts))
      workspace = Path.join(home, "workspace")

      {:ok,
       %{
         "home" => home,
         "config" => Path.join(home, "config.toml"),
         "manifest" => Path.join(home, "profile.json"),
         "workspace" => workspace,
         "memory" => Path.join(workspace, "memory"),
         "skills" => Path.join([workspace, ".lemon", "skill"]),
         "sessions" => Path.join(home, "sessions")
       }}
    end
  end

  @doc "List user-visible profiles from the canonical global profile table."
  @spec list(keyword()) :: [profile()]
  def list(opts \\ []) do
    opts
    |> read_profiles()
    |> Enum.flat_map(fn {id, raw} ->
      case build_profile(id, raw, opts) do
        {:ok, profile} -> [profile]
        {:error, _} -> []
      end
    end)
    |> Enum.sort_by(&{String.downcase(&1["name"]), &1["id"]})
  end

  @doc "Fetch one profile by its stable id."
  @spec get(String.t(), keyword()) :: {:ok, profile()} | {:error, :invalid_id | :not_found}
  def get(id, opts \\ []) do
    with :ok <- validate_id(id),
         raw when is_map(raw) <- Map.get(read_profiles(opts), id),
         {:ok, profile} <- build_profile(id, raw, opts) do
      {:ok, profile}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @doc "Create a profile plus its isolated home boundaries."
  @spec create(map() | keyword(), keyword()) :: {:ok, profile()} | {:error, term()}
  def create(attrs, opts \\ []) do
    attrs = normalize_attrs(attrs)
    id = value(attrs, "id") || slug(value(attrs, "name"))

    with :ok <- validate_id(id),
         :ok <- reject_reserved_id(id),
         {:ok, normalized} <- normalize_profile_attrs(id, attrs) do
      locked(opts, fn -> create_locked(normalized, opts) end)
    end
  end

  @doc "Clone a profile record and its regular home files into a new id."
  @spec clone(String.t(), map() | keyword(), keyword()) :: {:ok, profile()} | {:error, term()}
  def clone(source_id, attrs, opts \\ []) do
    with {:ok, source} <- get(source_id, opts) do
      attrs = normalize_attrs(attrs)

      clone_attrs =
        source
        |> Map.take(~w(name description avatar model systemPrompt node))
        |> Map.merge(stringify_keys(attrs))
        |> Map.put("id", value(attrs, "id") || slug(value(attrs, "name")))

      create(clone_attrs, Keyword.put(opts, :clone_home, source["paths"]["home"]))
    end
  end

  @doc "Rename a profile without changing its stable id or canonical chat."
  @spec rename(String.t(), String.t(), keyword()) :: {:ok, profile()} | {:error, term()}
  def rename(id, name, opts \\ []) do
    with :ok <- validate_id(id),
         {:ok, name} <- bounded_string(name, :name, 256) do
      locked(opts, fn ->
        with {:ok, _current} <- get(id, opts),
             {:ok, content} <- read_config(config_path(opts)) do
          now = now_ms()
          table = profile_table(id)

          updated =
            content
            |> TomlPatch.upsert_string(table, "name", name)
            |> TomlPatch.upsert_raw_line(table, "updated_at", "updated_at = #{now}")

          with :ok <- write_config(config_path(opts), updated, opts),
               {:ok, profile} <- get(id, opts),
               :ok <- write_manifest(profile) do
            {:ok, profile}
          else
            {:error, reason} ->
              _ =
                write_config(config_path(opts), content, Keyword.delete(opts, :atomic_write_fun))

              {:error, reason}
          end
        end
      end)
    end
  end

  @doc "Build the canonical native run request for a profile's main chat."
  @spec chat_request(profile(), String.t(), keyword()) ::
          {:ok, RunRequest.t()} | {:error, term()}
  def chat_request(profile, prompt, opts \\ []) when is_map(profile) do
    with id when is_binary(id) <- profile["id"],
         :ok <- validate_id(id),
         {:ok, prompt} <- bounded_string(prompt, :prompt, @max_prompt_bytes) do
      meta = Map.merge(%{profile_id: id}, Keyword.get(opts, :meta, %{}))

      {:ok,
       RunRequest.new(%{
         origin: Keyword.get(opts, :origin, :control_plane),
         session_key: profile["canonicalSessionKey"] || SessionKey.main(id),
         agent_id: id,
         prompt: prompt,
         queue_mode: Keyword.get(opts, :queue_mode, :collect),
         model: Keyword.get(opts, :model, profile["model"]),
         cwd: Keyword.get(opts, :cwd, profile["paths"]["workspace"]),
         meta: meta
       })}
    else
      nil -> {:error, :invalid_profile}
      {:error, _} = error -> error
    end
  end

  @doc "Export a portable, bounded JSON snapshot of a profile and its regular files."
  @spec export(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def export(id, destination, opts \\ []) do
    with {:ok, profile} <- get(id, opts),
         {:ok, files} <- collect_export_files(profile["paths"]["home"]),
         :ok <- ensure_export_destination(destination, opts) do
      payload = %{
        "format" => "lemon-profile",
        "version" => @version,
        "exportedAt" => now_ms(),
        "profile" => Map.drop(profile, ["paths"]),
        "files" => files
      }

      encoded = Jason.encode_to_iodata!(payload, pretty: true)

      with :ok <- atomic_write(Path.expand(destination), [encoded, "\n"]) do
        {:ok,
         %{
           "path" => Path.expand(destination),
           "profileId" => id,
           "fileCount" => map_size(files),
           "bytes" => IO.iodata_length(encoded)
         }}
      end
    end
  end

  @doc """
  Delete a profile after exact-id confirmation.

  The profile home is moved to `~/.lemon/trash/profiles/` before its config
  table is removed. A failed config write moves the home back, so the operation
  is both guarded and recoverable.
  """
  @spec delete(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def delete(id, opts \\ []) do
    with :ok <- validate_id(id),
         :ok <- reject_reserved_id(id),
         :ok <- validate_confirmation(id, Keyword.get(opts, :confirm)) do
      locked(opts, fn -> delete_locked(id, opts) end)
    end
  end

  defp create_locked(attrs, opts) do
    id = attrs["id"]

    with {:error, :not_found} <- get(id, opts),
         {:ok, final_paths} <- paths(id, opts),
         :ok <- ensure_home_missing(final_paths["home"]),
         {:ok, content} <- read_config(config_path(opts)),
         {:ok, temp_home} <- prepare_home(id, final_paths, opts) do
      updated = put_profile(content, attrs, now_ms())
      commit_created_profile(id, content, updated, temp_home, final_paths, opts)
    else
      {:ok, _existing} -> {:error, :already_exists}
      {:error, _} = error -> error
      other -> {:error, other}
    end
  end

  defp commit_created_profile(id, original, updated, temp_home, paths, opts) do
    config = config_path(opts)

    case write_config(config, updated, opts) do
      :ok ->
        case File.rename(temp_home, paths["home"]) do
          :ok ->
            case get(id, opts) do
              {:ok, profile} ->
                case write_manifest(profile) do
                  :ok -> {:ok, profile}
                  {:error, reason} -> rollback_create(config, original, paths["home"], reason)
                end

              {:error, reason} ->
                rollback_create(config, original, paths["home"], reason)
            end

          {:error, reason} ->
            _ = File.rm_rf(temp_home)
            rollback_create(config, original, nil, {:home_commit_failed, reason})
        end

      {:error, reason} ->
        _ = File.rm_rf(temp_home)
        {:error, reason}
    end
  end

  defp rollback_create(config, original, created_home, reason) do
    if is_binary(created_home), do: File.rm_rf(created_home)

    case atomic_write(config, original) do
      :ok -> {:error, reason}
      {:error, rollback_reason} -> {:error, {:rollback_failed, reason, rollback_reason}}
    end
  end

  defp delete_locked(id, opts) do
    with {:ok, profile} <- get(id, opts),
         :ok <- ensure_safe_home(profile["paths"]["home"]),
         {:ok, content} <- read_config(config_path(opts)),
         {:ok, moved} <- move_home_to_trash(profile, opts),
         updated <- TomlPatch.delete_table_tree(content, profile_table(id)) do
      case write_config(config_path(opts), updated, opts) do
        :ok ->
          {:ok,
           %{
             "id" => id,
             "canonicalSessionKey" => profile["canonicalSessionKey"],
             "homeMoved" => moved != nil,
             "trashPath" => moved
           }}

        {:error, reason} ->
          _ = restore_home(moved, profile["paths"]["home"])
          {:error, reason}
      end
    end
  end

  defp put_profile(content, attrs, now) do
    table = profile_table(attrs["id"])

    content
    |> TomlPatch.upsert_string(table, "name", attrs["name"])
    |> put_optional_string(table, "description", attrs["description"])
    |> put_optional_string(table, "avatar", attrs["avatar"])
    |> put_optional_string(table, "model", attrs["model"])
    |> put_optional_string(table, "system_prompt", attrs["systemPrompt"])
    |> TomlPatch.upsert_string(table, "node", attrs["node"])
    |> TomlPatch.upsert_string(table, "status", "active")
    |> TomlPatch.upsert_raw_line(table, "profile_version", "profile_version = #{@version}")
    |> TomlPatch.upsert_raw_line(table, "created_at", "created_at = #{now}")
    |> TomlPatch.upsert_raw_line(table, "updated_at", "updated_at = #{now}")
  end

  defp put_optional_string(content, table, key, nil),
    do: TomlPatch.delete_key(content, table, key)

  defp put_optional_string(content, table, key, value),
    do: TomlPatch.upsert_string(content, table, key, value)

  defp prepare_home(id, final_paths, opts) do
    profiles_root = Path.dirname(final_paths["home"])
    temp_home = Path.join(profiles_root, ".#{id}.tmp-#{System.unique_integer([:positive])}")

    with :ok <- File.mkdir_p(profiles_root),
         :ok <- ensure_home_missing(temp_home),
         :ok <- File.mkdir_p(Path.join(temp_home, "workspace/memory")),
         :ok <- File.mkdir_p(Path.join(temp_home, "workspace/.lemon/skill")),
         :ok <- File.mkdir_p(Path.join(temp_home, "sessions")),
         :ok <- File.write(Path.join(temp_home, "config.toml"), profile_config_header()),
         :ok <- maybe_copy_clone_home(Keyword.get(opts, :clone_home), temp_home) do
      _ = File.chmod(profiles_root, 0o700)
      _ = File.chmod(temp_home, 0o700)
      {:ok, temp_home}
    else
      {:error, reason} ->
        _ = File.rm_rf(temp_home)
        {:error, reason}
    end
  end

  defp profile_config_header do
    "# Profile-local Lemon overrides. This file is owned by the profile home.\n"
  end

  defp maybe_copy_clone_home(nil, _destination), do: :ok

  defp maybe_copy_clone_home(source, destination) when is_binary(source) do
    copy_regular_tree(source, destination, ["profile.json", "config.toml", "sessions"])
  end

  defp copy_regular_tree(source, destination, ignored) do
    with {:ok, names} <- File.ls(source) do
      Enum.reduce_while(names, :ok, fn name, :ok ->
        if name in ignored do
          {:cont, :ok}
        else
          from = Path.join(source, name)
          to = Path.join(destination, name)

          case File.lstat(from) do
            {:ok, %File.Stat{type: :directory}} ->
              case File.mkdir_p(to) do
                :ok ->
                  case copy_regular_tree(from, to, []) do
                    :ok -> {:cont, :ok}
                    {:error, _} = error -> {:halt, error}
                  end

                {:error, _} = error ->
                  {:halt, error}
              end

            {:ok, %File.Stat{type: :regular}} ->
              case File.cp(from, to) do
                :ok -> {:cont, :ok}
                {:error, _} = error -> {:halt, error}
              end

            {:ok, _other} ->
              {:halt, {:error, {:unsafe_profile_entry, relative_to(from, source)}}}

            {:error, _} = error ->
              {:halt, error}
          end
        end
      end)
    end
  end

  defp collect_export_files(home) do
    case collect_files(home, home, %{}, 0) do
      {:ok, files, _bytes} -> {:ok, files}
      {:error, _} = error -> error
    end
  end

  defp collect_files(root, current, files, total_bytes) do
    with {:ok, names} <- File.ls(current) do
      Enum.reduce_while(Enum.sort(names), {:ok, files, total_bytes}, fn name, {:ok, acc, bytes} ->
        path = Path.join(current, name)
        relative = relative_to(path, root)

        case File.lstat(path) do
          {:ok, %File.Stat{type: :directory}} ->
            case collect_files(root, path, acc, bytes) do
              {:ok, _, _} = ok -> {:cont, ok}
              {:error, _} = error -> {:halt, error}
            end

          {:ok, %File.Stat{type: :regular, size: size}}
          when size <= @max_export_file_bytes and map_size(acc) < @max_export_files and
                 bytes + size <= @max_export_total_bytes ->
            case File.read(path) do
              {:ok, content} ->
                entry = %{
                  "encoding" => "base64",
                  "data" => Base.encode64(content),
                  "bytes" => size
                }

                {:cont, {:ok, Map.put(acc, relative, entry), bytes + size}}

              {:error, reason} ->
                {:halt, {:error, {:export_read_failed, relative, reason}}}
            end

          {:ok, %File.Stat{type: :regular}} ->
            {:halt, {:error, {:export_limit_exceeded, relative}}}

          {:ok, _other} ->
            {:halt, {:error, {:unsafe_profile_entry, relative}}}

          {:error, reason} ->
            {:halt, {:error, {:export_stat_failed, relative, reason}}}
        end
      end)
    end
  end

  defp move_home_to_trash(profile, opts) do
    home = profile["paths"]["home"]

    if File.exists?(home) do
      trash_root = Paths.home_path(["trash", "profiles"], path_opts(opts))
      trash = Path.join(trash_root, "#{profile["id"]}-#{now_ms()}")

      with :ok <- File.mkdir_p(trash_root),
           :ok <- File.rename(home, trash) do
        {:ok, trash}
      end
    else
      {:ok, nil}
    end
  end

  defp restore_home(nil, _home), do: :ok
  defp restore_home(trash, home), do: File.rename(trash, home)

  defp ensure_home_missing(home) do
    case File.lstat(home) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :symlink}} -> {:error, :unsafe_profile_home}
      {:ok, _} -> {:error, :home_exists}
      {:error, reason} -> {:error, {:home_stat_failed, reason}}
    end
  end

  defp ensure_safe_home(home) do
    case File.lstat(home) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, _} -> {:error, :unsafe_profile_home}
      {:error, reason} -> {:error, {:home_stat_failed, reason}}
    end
  end

  defp build_profile(id, raw, opts) when is_map(raw) do
    with :ok <- validate_id(id),
         {:ok, derived_paths} <- paths(id, opts) do
      {:ok,
       %{
         "version" => integer_value(raw["profile_version"], @version),
         "id" => id,
         "name" => string_value(raw["name"], id),
         "description" => optional_string(raw["description"]),
         "avatar" => optional_string(raw["avatar"]),
         "model" => optional_string(raw["model"]),
         "systemPrompt" => optional_string(raw["system_prompt"]),
         "node" => string_value(raw["node"], "local"),
         "status" => string_value(raw["status"], "active"),
         "createdAt" => integer_value(raw["created_at"], nil),
         "updatedAt" => integer_value(raw["updated_at"], nil),
         "canonicalSessionKey" => SessionKey.main(id),
         "paths" => derived_paths,
         "managedKeys" => Enum.filter(@managed_keys, &Map.has_key?(raw, &1))
       }}
    end
  end

  defp normalize_profile_attrs(id, attrs) do
    with {:ok, name} <- bounded_string(value(attrs, "name") || id, :name, 256),
         {:ok, description} <-
           optional_bounded(value(attrs, "description"), :description, @max_description_bytes),
         {:ok, avatar} <- optional_bounded(value(attrs, "avatar"), :avatar, 2_048),
         {:ok, model} <- optional_bounded(value(attrs, "model"), :model, 512),
         {:ok, system_prompt} <-
           optional_bounded(
             value(attrs, "systemPrompt") || value(attrs, "system_prompt"),
             :system_prompt,
             @max_prompt_bytes
           ),
         {:ok, node} <- normalize_node(value(attrs, "node")) do
      {:ok,
       %{
         "id" => id,
         "name" => name,
         "description" => description,
         "avatar" => avatar,
         "model" => model,
         "systemPrompt" => system_prompt,
         "node" => node
       }}
    end
  end

  defp normalize_node(nil), do: {:ok, "local"}

  defp normalize_node(node) do
    with {:ok, node} <- bounded_string(node, :node, 128),
         true <- Regex.match?(@node_regex, node) || {:error, {:invalid_field, :node}} do
      {:ok, node}
    end
  end

  defp optional_bounded(nil, _field, _max), do: {:ok, nil}
  defp optional_bounded("", _field, _max), do: {:ok, nil}
  defp optional_bounded(value, field, max), do: bounded_string(value, field, max)

  defp bounded_string(value, field, max) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> {:error, {:invalid_field, field}}
      not String.valid?(value) -> {:error, {:invalid_field, field}}
      byte_size(value) > max -> {:error, {:field_too_large, field, max}}
      true -> {:ok, value}
    end
  end

  defp bounded_string(_value, field, _max), do: {:error, {:invalid_field, field}}

  defp validate_id(id) when is_binary(id) do
    if Regex.match?(@id_regex, id), do: :ok, else: {:error, :invalid_id}
  end

  defp validate_id(_), do: {:error, :invalid_id}

  defp reject_reserved_id("default"), do: {:error, :reserved_profile}
  defp reject_reserved_id(_), do: :ok

  defp validate_confirmation(id, id), do: :ok
  defp validate_confirmation(_id, _confirmation), do: {:error, :confirmation_required}

  defp read_profiles(opts) do
    with {:ok, content} <- read_config(config_path(opts)),
         {:ok, decoded} <- Toml.decode(content) do
      case decoded["profiles"] do
        profiles when is_map(profiles) -> profiles
        _ -> %{}
      end
    else
      _ -> %{}
    end
  end

  defp read_config(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:ok, ""}
      {:error, reason} -> {:error, {:config_read_failed, reason}}
    end
  end

  defp atomic_write(path, content) do
    path = Path.expand(path)
    dir = Path.dirname(path)
    temp = Path.join(dir, ".#{Path.basename(path)}.tmp-#{System.unique_integer([:positive])}")
    existing_mode = existing_mode(path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(temp, content, [:binary]),
         :ok <- File.chmod(temp, existing_mode),
         :ok <- File.rename(temp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temp)
        {:error, {:write_failed, reason}}
    end
  end

  defp write_config(path, content, opts) do
    case Keyword.get(opts, :atomic_write_fun) do
      fun when is_function(fun, 2) -> fun.(path, content)
      _ -> atomic_write(path, content)
    end
  end

  defp existing_mode(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o777)
      _ -> 0o600
    end
  end

  defp write_manifest(profile) do
    profile
    |> Jason.encode_to_iodata!(pretty: true)
    |> then(&atomic_write(profile["paths"]["manifest"], [&1, "\n"]))
  end

  defp ensure_export_destination(destination, opts) when is_binary(destination) do
    destination = Path.expand(destination)

    cond do
      File.dir?(destination) ->
        {:error, :destination_is_directory}

      File.exists?(destination) and not Keyword.get(opts, :force, false) ->
        {:error, :destination_exists}

      true ->
        :ok
    end
  end

  defp ensure_export_destination(_destination, _opts), do: {:error, :invalid_destination}

  defp locked(opts, fun) do
    key = {__MODULE__, config_path(opts)}
    :global.trans(key, fun, [node()])
  end

  defp profile_table(id), do: "profiles.#{id}"
  defp now_ms, do: System.system_time(:millisecond)

  defp path_opts(opts) do
    opts
    |> Keyword.take([:home_dir, :home_state_dir, :state_dir])
  end

  defp relative_to(path, root), do: Path.relative_to(path, root) |> String.replace("\\", "/")

  defp normalize_attrs(attrs) when is_list(attrs), do: Map.new(attrs)
  defp normalize_attrs(attrs) when is_map(attrs), do: attrs
  defp normalize_attrs(_), do: %{}

  defp stringify_keys(map) when is_map(map),
    do: Map.new(map, fn {key, val} -> {to_string(key), val} end)

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, safe_existing_atom(key))

  defp safe_existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> :__missing_profile_key__
  end

  defp slug(nil), do: nil

  defp slug(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.normalize(:nfd)
    |> String.replace(~r/[^a-z0-9_-]+/u, "-")
    |> String.trim("-")
    |> String.slice(0, 64)
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp string_value(value, default) when is_binary(value) do
    case String.trim(value) do
      "" -> default
      value -> value
    end
  end

  defp string_value(_value, default), do: default
  defp optional_string(value) when is_binary(value), do: string_value(value, nil)
  defp optional_string(_), do: nil
  defp integer_value(value, _default) when is_integer(value), do: value
  defp integer_value(_value, default), do: default
end
