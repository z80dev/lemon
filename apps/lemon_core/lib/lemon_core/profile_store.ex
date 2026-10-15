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

  Names are limited to 120 Unicode scalar values, with a defensive 512-byte UTF-8
  ceiling (120 valid scalars occupy at most 480 bytes). System prompts retain
  their exact UTF-8 bytes up to 131,072 bytes; chat prompts, each persona file and
  MCP definition JSON have separate 65,536-byte limits.
  """

  alias LemonCore.Config.Modular
  alias LemonCore.Config.TomlPatch
  alias LemonCore.Paths
  alias LemonCore.RunRequest
  alias LemonCore.SessionKey

  @version 1
  @id_regex ~r/^[a-z0-9][a-z0-9_-]{0,63}$/
  @node_regex ~r/^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/
  @managed_keys ~w(name description avatar model system_prompt node mcp_servers_json tool_policy_json status profile_version created_at updated_at)
  @max_name_bytes 512
  @max_name_scalars 120
  @max_description_bytes 4_096
  @max_prompt_bytes 65_536
  @max_system_prompt_bytes 131_072
  @max_persona_file_bytes 65_536
  @max_mcp_definition_bytes 65_536
  @max_export_files 256
  @max_export_file_bytes 1_048_576
  @max_export_total_bytes 8_388_608
  @export_workspace_files ~w(AGENTS.md IDENTITY.md README.md SOUL.md USER.md)
  @profile_instruction_files ~w(AGENTS.md IDENTITY.md README.md SOUL.md)
  @export_text_extensions ~w(.ex .exs .js .json .md .py .sh .toml .ts .txt .yaml .yml)

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
        {:ok, profile} -> [project_read(profile, opts)]
        {:error, _} -> []
      end
    end)
    |> Enum.sort_by(&{String.downcase(&1["name"]), &1["id"]})
  end

  @doc "Fetch one profile by its stable id; corrupt or unreadable config is not absence."
  @spec get(String.t(), keyword()) :: {:ok, profile()} | {:error, term()}
  def get(id, opts \\ []) do
    with :ok <- validate_id(id),
         {:ok, profiles} <- read_profiles_strict(opts),
         raw when is_map(raw) <- Map.get(profiles, id),
         {:ok, profile} <- build_profile(id, raw, opts) do
      {:ok, project_read(profile, opts)}
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
      _ -> {:error, :invalid_profile}
    end
  end

  @doc "Fetch a private profile for execution, including MCP authentication headers."
  @spec get_for_execution(String.t(), keyword()) :: {:ok, profile()} | {:error, term()}
  def get_for_execution(id, opts \\ []), do: get(id, Keyword.put(opts, :execution, true))

  defp project_read(profile, opts) do
    if Keyword.get(opts, :execution, false), do: profile, else: projection(profile)
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
    with {:ok, source} <- get_for_execution(source_id, opts) do
      attrs = normalize_attrs(attrs)

      clone_attrs =
        source
        |> Map.take(~w(name description avatar model systemPrompt node mcpServers toolPolicy))
        |> Map.merge(stringify_keys(attrs))
        |> Map.put("id", value(attrs, "id") || slug(value(attrs, "name")))

      create(clone_attrs, Keyword.put(opts, :clone_home, source["paths"]["home"]))
    end
  end

  @doc "Update managed fields atomically, preserving omitted fields and unrelated config."
  @spec update(String.t(), map() | keyword(), keyword()) :: {:ok, profile()} | {:error, term()}
  def update(id, attrs, opts \\ []) do
    with :ok <- validate_id(id) do
      locked(opts, fn ->
        with {:ok, current} <- get_for_execution(id, opts),
             patch <- stringify_keys(normalize_attrs(attrs)),
             patch <- canonical_patch(patch),
             attrs <- Map.merge(current, patch),
             {:ok, normalized} <- normalize_profile_attrs(id, attrs),
             {:ok, content} <- read_config(config_path(opts)) do
          updated =
            content
            |> put_profile(normalized, now_ms())
            |> TomlPatch.upsert_raw_line(
              profile_table(id),
              "created_at",
              "created_at = #{current["createdAt"] || now_ms()}"
            )

          with :ok <- write_config(config_path(opts), updated, opts),
               {:ok, profile} <- get(id, opts),
               :ok <- write_manifest(profile) do
            {:ok, profile}
          else
            {:error, reason} ->
              case write_config(
                     config_path(opts),
                     content,
                     Keyword.delete(opts, :atomic_write_fun)
                   ) do
                :ok -> {:error, reason}
                {:error, rollback} -> {:error, {:rollback_failed, reason, rollback}}
              end
          end
        end
      end)
    end
  end

  @doc "Management projection of a profile. MCP authentication headers are write-only."
  @spec projection(profile()) :: profile()
  def projection(profile) do
    profile
    |> Map.put_new_lazy("mcpConfigFingerprint", fn ->
      mcp_config_fingerprint(profile["mcpServers"] || [])
    end)
    |> Map.update("mcpServers", [], fn servers ->
      Enum.map(servers, &Map.delete(&1, "headers"))
    end)
  end

  @doc "Hash the normalized private MCP definitions, retaining server order and absent-field semantics."
  def mcp_config_fingerprint(servers) do
    canonical =
      Enum.map(servers, fn server ->
        headers =
          server
          |> Map.get("headers", %{})
          |> Enum.sort()
          |> Enum.map(fn {key, value} -> [key, value] end)

        [
          server["name"],
          server["url"],
          headers,
          server["enabledTools"],
          server["allowedOrigins"],
          server["approvedPrivateOrigins"]
        ]
      end)

    :crypto.hash(:sha256, Jason.encode!(canonical)) |> Base.encode16(case: :lower)
  end

  @doc "Rename a profile without changing its stable id or canonical chat."
  @spec rename(String.t(), String.t(), keyword()) :: {:ok, profile()} | {:error, term()}
  def rename(id, name, opts \\ []) do
    with :ok <- validate_id(id),
         {:ok, name} <- profile_name(name) do
      locked(opts, fn ->
        with {:ok, _current} <- get(id, opts),
             {:ok, content} <- read_config(config_path(opts)) do
          now = now_ms()
          table = profile_table(id)

          updated =
            content
            |> put_profile_string(table, "name", name)
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

  @doc """
  Read the controller-owned persona snapshot for destination provisioning.
  Mutable USER.md, memory, local configuration and credentials are excluded.
  """
  @spec persona_snapshot(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def persona_snapshot(id, opts \\ []) do
    with {:ok, profile} <- get(id, opts),
         {:ok, instructions} <- profile_instructions(profile) do
      {:ok,
       %{
         "id" => profile["id"],
         "model" => profile["model"],
         "systemPrompt" => profile["systemPrompt"],
         "instructions" => instructions
       }}
    end
  end

  @doc """
  Build the canonical native run request for a profile's main chat.

  An image-only prompt may be empty when `:images` contains normalized, nonempty
  native image blocks. Ingress owns image decoding/limits; workspace and node
  ownership remain profile-derived. `:invocation_mcp_servers`, when present,
  replaces the complete profile connector list; `[]` attaches none. Omission
  retains the profile list. Headers are never merged between principals.
  """
  @spec chat_request(profile(), String.t(), keyword()) ::
          {:ok, RunRequest.t()} | {:error, term()}
  def chat_request(profile, prompt, opts \\ []) when is_map(profile) do
    with id when is_binary(id) <- profile["id"],
         :ok <- validate_id(id),
         {:ok, prompt} <- chat_prompt(prompt, Keyword.get(opts, :images, [])),
         {:ok, node} <- normalize_node(profile["node"]),
         {:ok, instructions} <- profile_instructions(profile),
         {:ok, mcp_servers} <- invocation_mcp_servers(profile, opts),
         {:ok, profile_policy} <- LemonCore.ToolPolicy.normalize(profile["toolPolicy"] || %{}) do
      meta =
        opts
        |> Keyword.get(:meta, %{})
        |> Map.drop([
          "profile_id",
          :profile_id,
          "node",
          :node,
          "system_prompt",
          :system_prompt,
          "profile_instructions",
          :profile_instructions,
          "mcp_servers",
          :mcp_servers,
          "remote_cwd_explicit",
          :remote_cwd_explicit,
          "remote_cwd",
          :remote_cwd,
          "cwd",
          :cwd,
          "tool_policy",
          :tool_policy,
          "toolPolicy"
        ])
        |> Map.put(:profile_id, id)
        |> Map.put(:node, node)
        |> Map.put(:system_prompt, profile["systemPrompt"])
        |> Map.put(:profile_instructions, instructions)
        |> Map.put(:mcp_servers, mcp_servers)

      cwd =
        case Keyword.fetch(opts, :cwd) do
          {:ok, cwd} when is_binary(cwd) and cwd != "" -> cwd
          :error when node == "local" -> profile["paths"]["workspace"]
          _ when node == "local" -> profile["paths"]["workspace"]
          _ -> nil
        end

      meta =
        meta
        |> Map.put(:remote_cwd_explicit, node != "local" and is_binary(cwd))
        |> Map.put(:remote_cwd, if(node != "local", do: cwd))

      {:ok,
       RunRequest.new(%{
         origin: Keyword.get(opts, :origin, :control_plane),
         session_key:
           Keyword.get(opts, :session_key) || profile["canonicalSessionKey"] ||
             SessionKey.main(id),
         agent_id: id,
         prompt: prompt,
         images: Keyword.get(opts, :images, []),
         queue_mode: Keyword.get(opts, :queue_mode, :collect),
         model: Keyword.get(opts, :model) || profile["model"],
         cwd: cwd,
         run_id: Keyword.get(opts, :run_id),
         resume: Keyword.get(opts, :resume),
         tool_policy:
           LemonCore.ToolPolicy.intersect(profile_policy, Keyword.get(opts, :tool_policy)),
         meta: meta
       })}
    else
      nil -> {:error, :invalid_profile}
      {:error, _} = error -> error
    end
  end

  defp invocation_mcp_servers(profile, opts) do
    servers =
      case Keyword.fetch(opts, :invocation_mcp_servers) do
        {:ok, servers} -> servers
        :error -> profile["mcpServers"] || []
      end

    normalize_mcp_servers(servers)
  end

  defp profile_instructions(profile) do
    workspace = get_in(profile, ["paths", "workspace"])

    if is_binary(workspace) do
      Enum.reduce_while(@profile_instruction_files, {:ok, %{}}, fn name, {:ok, files} ->
        path = Path.join(workspace, name)

        case File.lstat(path) do
          {:error, :enoent} ->
            {:cont, {:ok, files}}

          {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_persona_file_bytes ->
            case File.read(path) do
              {:ok, text} when byte_size(text) <= @max_persona_file_bytes ->
                if String.valid?(text) and not String.contains?(text, <<0>>),
                  do: {:cont, {:ok, Map.put(files, name, text)}},
                  else: {:halt, {:error, :invalid_profile_instructions}}

              _ ->
                {:halt, {:error, :invalid_profile_instructions}}
            end

          _ ->
            {:halt, {:error, :invalid_profile_instructions}}
        end
      end)
    else
      {:ok, %{}}
    end
  end

  @doc """
  Export a portable, bounded, credential-safe JSON snapshot.

  Exports are selected-file by default: sessions, memory, artifacts, manifests,
  binary files, and secret-like paths are omitted. Profile-local config,
  bootstrap markdown, and skill text are included only after assignment and
  inline credential redaction. The result reports omission and redaction counts.
  """
  @spec export(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def export(id, destination, opts \\ []) do
    with {:ok, profile} <- get(id, opts),
         {:ok, files, report} <- collect_export_files(profile["paths"]["home"]),
         :ok <- ensure_export_destination(destination, opts) do
      {portable_profile, profile_redactions} = portable_profile(profile)
      report = Map.update!(report, "redactionCount", &(&1 + profile_redactions))

      payload = %{
        "format" => "lemon-profile",
        "version" => @version,
        "exportedAt" => now_ms(),
        "profile" => portable_profile,
        "files" => files,
        "exportPolicy" =>
          Map.merge(report, %{
            "mode" => "credential-safe-selected-files",
            "includesSessions" => false,
            "includesMemory" => false,
            "includesSecrets" => false
          })
      }

      encoded = Jason.encode_to_iodata!(payload, pretty: true)

      with :ok <- atomic_write(Path.expand(destination), [encoded, "\n"]) do
        {:ok,
         %{
           "path" => Path.expand(destination),
           "profileId" => id,
           "fileCount" => map_size(files),
           "omittedCount" => report["omittedCount"],
           "redactionCount" => report["redactionCount"],
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
    |> put_profile_string(table, "name", attrs["name"])
    |> put_optional_string(table, "description", attrs["description"])
    |> put_optional_string(table, "avatar", attrs["avatar"])
    |> put_optional_string(table, "model", attrs["model"])
    |> put_optional_string(table, "system_prompt", attrs["systemPrompt"])
    |> put_profile_string(table, "node", attrs["node"])
    |> put_profile_string(table, "mcp_servers_json", Jason.encode!(attrs["mcpServers"]))
    |> put_profile_string(table, "tool_policy_json", Jason.encode!(attrs["toolPolicy"]))
    |> put_profile_string(table, "status", "active")
    |> TomlPatch.upsert_raw_line(table, "profile_version", "profile_version = #{@version}")
    |> TomlPatch.upsert_raw_line(table, "created_at", "created_at = #{now}")
    |> TomlPatch.upsert_raw_line(table, "updated_at", "updated_at = #{now}")
  end

  defp put_optional_string(content, table, key, nil),
    do: TomlPatch.delete_key(content, table, key)

  defp put_optional_string(content, table, key, value),
    do: put_profile_string(content, table, key, value)

  defp put_profile_string(content, table, key, value),
    do: TomlPatch.upsert_raw_line(content, table, key, key <> " = " <> Jason.encode!(value))

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
    initial = %{
      files: %{},
      bytes: 0,
      omitted_count: 0,
      omission_counts: %{},
      redaction_count: 0
    }

    case collect_files(home, home, initial) do
      {:ok, state} ->
        {:ok, state.files,
         %{
           "omittedCount" => state.omitted_count,
           "omissionCounts" => state.omission_counts,
           "redactionCount" => state.redaction_count
         }}

      {:error, _} = error ->
        error
    end
  end

  defp collect_files(root, current, state) do
    with {:ok, names} <- File.ls(current) do
      Enum.reduce_while(Enum.sort(names), {:ok, state}, fn name, {:ok, acc} ->
        path = Path.join(current, name)
        relative = relative_to(path, root)

        case File.lstat(path) do
          {:ok, %File.Stat{type: :directory}} ->
            if private_export_boundary?(relative) do
              {:cont, {:ok, omit_export(acc, "private_boundary")}}
            else
              case collect_files(root, path, acc) do
                {:ok, _} = ok -> {:cont, ok}
                {:error, _} = error -> {:halt, error}
              end
            end

          {:ok, %File.Stat{type: :regular, size: size}}
          when size > @max_export_file_bytes ->
            {:cont, {:ok, omit_export(acc, "file_too_large")}}

          {:ok, %File.Stat{type: :regular}} ->
            collect_export_file(path, relative, acc)

          {:ok, _other} ->
            {:cont, {:ok, omit_export(acc, "unsafe_file_type")}}

          {:error, reason} ->
            {:halt, {:error, {:export_stat_failed, relative, reason}}}
        end
      end)
    end
  end

  defp collect_export_file(path, relative, state) do
    cond do
      secret_like_path?(relative) ->
        {:cont, {:ok, omit_export(state, "secret_like_path")}}

      not selected_export_path?(relative) ->
        {:cont, {:ok, omit_export(state, "not_selected")}}

      map_size(state.files) >= @max_export_files ->
        {:halt, {:error, {:export_limit_exceeded, :file_count}}}

      true ->
        case File.read(path) do
          {:ok, content} when is_binary(content) ->
            if String.valid?(content) do
              {redacted, redactions} = LemonCore.Redact.text(content, strict: true, count: true)
              bytes = byte_size(redacted)

              if state.bytes + bytes <= @max_export_total_bytes do
                entry = %{
                  "encoding" => "base64",
                  "data" => Base.encode64(redacted),
                  "bytes" => bytes,
                  "redacted" => redactions > 0
                }

                next = %{
                  state
                  | files: Map.put(state.files, relative, entry),
                    bytes: state.bytes + bytes,
                    redaction_count: state.redaction_count + redactions
                }

                {:cont, {:ok, next}}
              else
                {:halt, {:error, {:export_limit_exceeded, :total_bytes}}}
              end
            else
              {:cont, {:ok, omit_export(state, "binary_content")}}
            end

          {:error, reason} ->
            {:halt, {:error, {:export_read_failed, relative, reason}}}
        end
    end
  end

  defp private_export_boundary?(relative) do
    relative in ["sessions", "workspace/memory", "workspace/artifacts"] or
      String.starts_with?(relative, "sessions/") or
      String.starts_with?(relative, "workspace/memory/") or
      String.starts_with?(relative, "workspace/artifacts/")
  end

  defp selected_export_path?("config.toml"), do: true

  defp selected_export_path?("workspace/" <> rest = relative) do
    rest in @export_workspace_files or
      (String.starts_with?(relative, "workspace/.lemon/skill/") and
         Path.extname(relative) in @export_text_extensions)
  end

  defp selected_export_path?(_), do: false

  defp secret_like_path?(relative) do
    downcased = String.downcase(relative)
    basename = Path.basename(downcased)

    basename in [".env", ".env.local", "id_rsa", "id_ed25519"] or
      LemonCore.Redact.sensitive_key?(downcased)
  end

  defp omit_export(state, reason) do
    %{
      state
      | omitted_count: state.omitted_count + 1,
        omission_counts: Map.update(state.omission_counts, reason, 1, &(&1 + 1))
    }
  end

  defp portable_profile(profile) do
    profile =
      profile |> projection() |> Map.drop(["paths", "managedKeys", "mcpConfigFingerprint"])

    Enum.reduce(["name", "description", "systemPrompt"], {profile, 0}, fn key, {acc, count} ->
      case acc[key] do
        value when is_binary(value) ->
          {redacted, redactions} = LemonCore.Redact.text(value, strict: true, count: true)
          {Map.put(acc, key, redacted), count + redactions}

        _ ->
          {acc, count}
      end
    end)
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
         {:ok, derived_paths} <- paths(id, opts),
         {:ok, tool_policy} <- decode_tool_policy(raw),
         {:ok, system_prompt} <- optional_system_prompt(raw["system_prompt"]) do
      {:ok,
       %{
         "version" => integer_value(raw["profile_version"], @version),
         "id" => id,
         "name" => string_value(raw["name"], id),
         "description" => optional_string(raw["description"]),
         "avatar" => optional_string(raw["avatar"]),
         "model" => optional_string(raw["model"]),
         "systemPrompt" => system_prompt,
         "node" => string_value(raw["node"], "local"),
         "mcpServers" => decode_mcp_servers(raw["mcp_servers_json"]),
         "toolPolicy" => tool_policy,
         "status" => string_value(raw["status"], "active"),
         "createdAt" => integer_value(raw["created_at"], nil),
         "updatedAt" => integer_value(raw["updated_at"], nil),
         "canonicalSessionKey" => SessionKey.main(id),
         "paths" => derived_paths,
         "managedKeys" => Enum.filter(@managed_keys, &Map.has_key?(raw, &1))
       }}
    end
  end

  defp build_profile(_id, _raw, _opts), do: {:error, :invalid_profile}

  defp normalize_profile_attrs(id, attrs) do
    with {:ok, name} <- profile_name(value(attrs, "name") || id),
         {:ok, description} <-
           optional_bounded(value(attrs, "description"), :description, @max_description_bytes),
         {:ok, avatar} <- optional_bounded(value(attrs, "avatar"), :avatar, 2_048),
         {:ok, model} <- optional_bounded(value(attrs, "model"), :model, 512),
         {:ok, system_prompt} <-
           optional_system_prompt(value(attrs, "systemPrompt") || value(attrs, "system_prompt")),
         {:ok, node} <- normalize_node(value(attrs, "node")),
         {:ok, mcp_servers} <-
           normalize_mcp_servers(value(attrs, "mcpServers") || value(attrs, "mcp_servers") || []),
         {:ok, tool_policy} <-
           LemonCore.ToolPolicy.normalize(
             Map.get(
               attrs,
               "toolPolicy",
               Map.get(
                 attrs,
                 :toolPolicy,
                 Map.get(attrs, "tool_policy", Map.get(attrs, :tool_policy, %{}))
               )
             )
           ) do
      {:ok,
       %{
         "id" => id,
         "name" => name,
         "description" => description,
         "avatar" => avatar,
         "model" => model,
         "systemPrompt" => system_prompt,
         "node" => node,
         "mcpServers" => mcp_servers,
         "toolPolicy" => tool_policy
       }}
    end
  end

  defp decode_tool_policy(%{"tool_policy_json" => json}) do
    with {:ok, policy} <- Jason.decode(json),
         {:ok, normalized} <- LemonCore.ToolPolicy.normalize(policy) do
      {:ok, normalized}
    else
      _ -> {:error, {:invalid_field, :tool_policy}}
    end
  end

  defp decode_tool_policy(raw) do
    policy = LemonCore.Config.parse_tool_policy(raw["tool_policy"]) || %{}
    LemonCore.ToolPolicy.normalize(policy)
  end

  defp decode_mcp_servers(nil), do: []

  defp decode_mcp_servers(json) when is_binary(json) do
    with {:ok, servers} <- Jason.decode(json),
         {:ok, normalized} <- normalize_mcp_servers(servers) do
      normalized
    else
      _ -> []
    end
  end

  defp decode_mcp_servers(_), do: []

  @doc """
  Validate and normalize bounded profile or invocation HTTP MCP definitions.
  `enabledTools` uses exact remote tool names: omitted allows all, `[]` none.
  """
  @spec normalize_mcp_servers(term()) :: {:ok, [map()]} | {:error, term()}
  def normalize_mcp_servers(servers) when is_list(servers) and length(servers) <= 32 do
    Enum.reduce_while(servers, {:ok, [], MapSet.new()}, fn server, {:ok, acc, names} ->
      with true <- is_map(server),
           {:ok, name} <- bounded_string(value(server, "name"), :mcp_servers, 128),
           false <- MapSet.member?(names, name),
           {:ok, url} <- bounded_string(value(server, "url"), :mcp_servers, 2_048),
           %URI{scheme: scheme, host: host, userinfo: nil, fragment: nil} <- URI.parse(url),
           true <- scheme in ["http", "https"] and is_binary(host) and host != "",
           {:ok, headers} <-
             normalize_mcp_headers(Map.get(server, "headers", Map.get(server, :headers, %{}))),
           {:ok, enabled_tools} <- normalize_enabled_tools(server),
           {:ok, origin_policy} <- normalize_mcp_origins(server) do
        normalized = %{"name" => name, "url" => url, "headers" => headers}

        normalized =
          if is_nil(enabled_tools),
            do: normalized,
            else: Map.put(normalized, "enabledTools", enabled_tools)

        normalized = Map.merge(normalized, origin_policy)
        {:cont, {:ok, [normalized | acc], MapSet.put(names, name)}}
      else
        _ -> {:halt, {:error, {:invalid_field, :mcp_servers}}}
      end
    end)
    |> case do
      {:ok, normalized, _names} ->
        normalized = Enum.reverse(normalized)

        if byte_size(Jason.encode!(normalized)) <= @max_mcp_definition_bytes,
          do: {:ok, normalized},
          else: {:error, {:field_too_large, :mcp_servers, @max_mcp_definition_bytes}}

      error ->
        error
    end
  end

  def normalize_mcp_servers(_), do: {:error, {:invalid_field, :mcp_servers}}

  defp normalize_mcp_origins(server) do
    allowed? = Map.has_key?(server, "allowedOrigins") or Map.has_key?(server, :allowedOrigins)

    private? =
      Map.has_key?(server, "approvedPrivateOrigins") or
        Map.has_key?(server, :approvedPrivateOrigins)

    cond do
      not allowed? and not private? ->
        {:ok, %{}}

      not allowed? ->
        {:error, {:invalid_field, :mcp_servers}}

      true ->
        with {:ok, allowed} <-
               normalize_origins(
                 Map.get(server, "allowedOrigins", Map.get(server, :allowedOrigins))
               ),
             {:ok, private} <-
               normalize_origins(
                 Map.get(
                   server,
                   "approvedPrivateOrigins",
                   Map.get(server, :approvedPrivateOrigins, [])
                 )
               ),
             true <- Enum.all?(private, &(&1 in allowed)) do
          policy = %{"allowedOrigins" => allowed}

          {:ok,
           if(private?, do: Map.put(policy, "approvedPrivateOrigins", private), else: policy)}
        else
          _ -> {:error, {:invalid_field, :mcp_servers}}
        end
    end
  end

  defp normalize_origins(origins) when is_list(origins) and length(origins) <= 32 do
    Enum.reduce_while(origins, {:ok, []}, fn origin, {:ok, acc} ->
      case normalize_origin(origin) do
        {:ok, normalized} ->
          if normalized in acc,
            do: {:halt, {:error, {:invalid_field, :mcp_servers}}},
            else: {:cont, {:ok, [normalized | acc]}}

        _ ->
          {:halt, {:error, {:invalid_field, :mcp_servers}}}
      end
    end)
    |> case do
      {:ok, origins} -> {:ok, Enum.reverse(origins)}
      error -> error
    end
  end

  defp normalize_origins(_), do: {:error, {:invalid_field, :mcp_servers}}

  defp normalize_origin(origin) when is_binary(origin) and byte_size(origin) <= 2_048 do
    with true <- String.valid?(origin),
         %URI{
           scheme: scheme,
           host: host,
           port: port,
           path: path,
           userinfo: nil,
           query: nil,
           fragment: nil
         } <- URI.parse(origin),
         true <-
           scheme in ["http", "https"] and is_binary(host) and host != "" and
             is_integer(port) and port in 1..65_535 and path in [nil, "/"],
         {:ok, host} <- canonical_origin_host(host) do
      {:ok, URI.to_string(%URI{scheme: scheme, host: host, port: port})}
    else
      _ -> {:error, {:invalid_field, :mcp_servers}}
    end
  end

  defp normalize_origin(_), do: {:error, {:invalid_field, :mcp_servers}}

  defp canonical_origin_host(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, address} ->
        {:ok, address |> :inet.ntoa() |> List.to_string()}

      {:error, _} ->
        host = host |> String.downcase() |> String.replace_suffix(".", "")
        labels = String.split(host, ".")

        if byte_size(host) in 1..253 and
             Enum.all?(labels, fn label ->
               byte_size(label) in 1..63 and
                 Regex.match?(~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/, label)
             end) do
          {:ok, host}
        else
          {:error, {:invalid_field, :mcp_servers}}
        end
    end
  end

  defp normalize_enabled_tools(server) do
    case Map.fetch(server, "enabledTools") do
      :error ->
        case Map.fetch(server, :enabledTools) do
          :error -> {:ok, nil}
          {:ok, names} -> validate_enabled_tools(names)
        end

      {:ok, names} ->
        validate_enabled_tools(names)
    end
  end

  defp validate_enabled_tools(names) when is_list(names) and length(names) <= 256 do
    valid? =
      Enum.all?(names, fn name ->
        is_binary(name) and String.valid?(name) and byte_size(name) in 1..128 and
          not Regex.match?(~r/[\x00-\x20\x7f]/, name)
      end)

    if valid? and MapSet.size(MapSet.new(names)) == length(names),
      do: {:ok, names},
      else: {:error, {:invalid_field, :mcp_servers}}
  end

  defp validate_enabled_tools(_), do: {:error, {:invalid_field, :mcp_servers}}

  defp normalize_mcp_headers(headers) when is_map(headers) and map_size(headers) <= 64 do
    valid? =
      Enum.all?(headers, fn {name, value} ->
        is_binary(name) and byte_size(name) in 1..128 and
          Regex.match?(~r/^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/, name) and
          is_binary(value) and String.valid?(value) and byte_size(value) <= 8_192 and
          not String.contains?(value, ["\r", "\n", <<0>>])
      end)

    if valid?, do: {:ok, headers}, else: {:error, {:invalid_field, :mcp_servers}}
  end

  defp normalize_mcp_headers(_), do: {:error, {:invalid_field, :mcp_servers}}

  defp normalize_node(nil), do: {:ok, "local"}

  defp normalize_node(node) do
    with {:ok, node} <- bounded_string(node, :node, 128),
         true <- Regex.match?(@node_regex, node) || {:error, {:invalid_field, :node}} do
      {:ok, node}
    end
  end

  defp profile_name(value) do
    with {:ok, name} <- bounded_string(value, :name, @max_name_bytes) do
      cond do
        String.contains?(name, <<0>>) ->
          {:error, {:invalid_field, :name}}

        not within_scalar_limit?(name, @max_name_scalars) ->
          {:error, {:field_too_large, :name, @max_name_scalars}}

        true ->
          {:ok, name}
      end
    end
  end

  defp within_scalar_limit?(<<>>, _remaining), do: true
  defp within_scalar_limit?(_text, 0), do: false

  defp within_scalar_limit?(<<_scalar::utf8, rest::binary>>, remaining),
    do: within_scalar_limit?(rest, remaining - 1)

  defp optional_system_prompt(nil), do: {:ok, nil}
  defp optional_system_prompt(""), do: {:ok, nil}

  defp optional_system_prompt(value) when is_binary(value) do
    cond do
      not String.valid?(value) or String.contains?(value, <<0>>) ->
        {:error, {:invalid_field, :system_prompt}}

      byte_size(value) > @max_system_prompt_bytes ->
        {:error, {:field_too_large, :system_prompt, @max_system_prompt_bytes}}

      true ->
        {:ok, value}
    end
  end

  defp optional_system_prompt(_value), do: {:error, {:invalid_field, :system_prompt}}

  defp optional_bounded(nil, _field, _max), do: {:ok, nil}
  defp optional_bounded("", _field, _max), do: {:ok, nil}
  defp optional_bounded(value, field, max), do: bounded_string(value, field, max)

  defp chat_prompt("", [_ | _] = images) do
    normalized? =
      Enum.all?(images, fn
        %{type: :image, data: data, mime_type: mime}
        when is_binary(data) and data != "" and
               mime in ["image/png", "image/jpeg", "image/gif", "image/webp"] ->
          true

        _ ->
          false
      end)

    if normalized?, do: {:ok, ""}, else: {:error, {:invalid_field, :prompt}}
  end

  defp chat_prompt(prompt, _images), do: bounded_string(prompt, :prompt, @max_prompt_bytes)

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
    case read_profiles_strict(opts) do
      {:ok, profiles} -> profiles
      {:error, _} -> %{}
    end
  end

  defp read_profiles_strict(opts) do
    case read_config(config_path(opts)) do
      {:ok, content} ->
        case Toml.decode(content) do
          {:ok, decoded} ->
            case decoded["profiles"] do
              nil -> {:ok, %{}}
              profiles when is_map(profiles) -> {:ok, profiles}
              _ -> {:error, :invalid_profile_config}
            end

          {:error, _} ->
            {:error, :invalid_profile_config}
        end

      {:error, _} ->
        {:error, :profile_store_unavailable}
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
      {:ok, %File.Stat{mode: mode}} -> Bitwise.band(mode, 0o600)
      _ -> 0o600
    end
  end

  defp write_manifest(profile) do
    profile
    |> projection()
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

  defp canonical_patch(patch) do
    Enum.reduce(
      [
        {"system_prompt", "systemPrompt"},
        {"mcp_servers", "mcpServers"},
        {"tool_policy", "toolPolicy"}
      ],
      patch,
      fn
        {source, destination}, acc ->
          case Map.fetch(acc, source) do
            {:ok, value} -> acc |> Map.delete(source) |> Map.put(destination, value)
            :error -> acc
          end
      end
    )
  end

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
    if String.valid?(name) and not String.contains?(name, <<0>>) do
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
