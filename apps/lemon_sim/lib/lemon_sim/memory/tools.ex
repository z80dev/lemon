defmodule LemonSim.Memory.Tools do
  @moduledoc """
  File-based memory tools for simulation agents.

  Tools are scoped to a memory root and only accept relative paths inside that
  root. This allows the agent to maintain focused notes (for example `index.md`
  plus linked files) without exposing arbitrary filesystem access.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}

  @default_list_limit 200
  @default_max_read_bytes 256 * 1024
  @default_max_write_bytes 256 * 1024

  @tool_names [
    "memory_read_file",
    "memory_write_file",
    "memory_patch_file",
    "memory_list_files",
    "memory_delete_file"
  ]

  @spec tool_names() :: [String.t()]
  def tool_names, do: @tool_names

  @spec build(keyword()) :: [AgentTool.t()]
  def build(opts \\ []) do
    root = memory_root(opts)
    ensure_memory_root!(root)
    ensure_index!(root)

    [
      read_tool(root, opts),
      write_tool(root, opts),
      patch_tool(root),
      list_tool(root, opts),
      delete_tool(root)
    ]
  end

  @spec memory_root(keyword()) :: String.t()
  def memory_root(opts \\ []) do
    base =
      opts
      |> Keyword.get(:memory_root, Path.join(File.cwd!(), ".lemon/sim_memory"))
      |> Path.expand()

    namespace =
      opts
      |> Keyword.get(:memory_namespace, Keyword.get(opts, :sim_id, "default"))
      |> to_string()

    namespace = String.trim(namespace)
    safe_namespace = if namespace == "", do: "default", else: namespace

    Path.expand(safe_namespace, base)
  end

  defp read_tool(root, opts) do
    max_bytes = Keyword.get(opts, :memory_max_read_bytes, @default_max_read_bytes)

    %AgentTool{
      name: "memory_read_file",
      label: "Memory Read",
      description: "Read a memory file by relative path (e.g. index.md).",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Relative file path"},
          "max_bytes" => %{
            "type" => "integer",
            "description" => "Optional read cap in bytes",
            "minimum" => 1
          }
        },
        "required" => ["path"],
        "additionalProperties" => false
      },
      execute: fn _id, params, _signal, _on_update ->
        with {:ok, path} <- fetch_string(params, "path"),
             {:ok, abs_path} <- resolve_memory_path(root, path),
             {:ok, content} <- File.read(abs_path) do
          cap = normalize_positive_int(Map.get(params, "max_bytes"), max_bytes)
          truncated? = byte_size(content) > cap
          text = if truncated?, do: binary_part(content, 0, cap), else: content

          {:ok,
           %AgentToolResult{
             content: [AgentCore.text_content(text)],
             details: %{
               path: path,
               bytes: byte_size(content),
               truncated: truncated?,
               root: root
             },
             trust: :trusted
           }}
        else
          {:error, :enoent} ->
            {:error, "Memory file not found"}

          {:error, reason} when is_binary(reason) ->
            {:error, reason}

          {:error, reason} ->
            {:error, "Unable to read memory file: #{inspect(reason)}"}
        end
      end
    }
  end

  defp write_tool(root, opts) do
    max_bytes = Keyword.get(opts, :memory_max_write_bytes, @default_max_write_bytes)

    %AgentTool{
      name: "memory_write_file",
      label: "Memory Write",
      description:
        "Write a memory file at a relative path. Use mode=append to add to an existing file.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Relative file path"},
          "content" => %{"type" => "string", "description" => "File content"},
          "mode" => %{
            "type" => "string",
            "enum" => ["overwrite", "append"],
            "description" => "Write mode (default: overwrite)"
          }
        },
        "required" => ["path", "content"],
        "additionalProperties" => false
      },
      execute: fn _id, params, _signal, _on_update ->
        with {:ok, path} <- fetch_string(params, "path"),
             {:ok, content} <- fetch_string(params, "content"),
             true <- byte_size(content) <= max_bytes or {:error, :too_large},
             {:ok, abs_path} <- resolve_memory_path(root, path),
             :ok <- File.mkdir_p(Path.dirname(abs_path)),
             :ok <- write_file(abs_path, content, Map.get(params, "mode", "overwrite")) do
          {:ok,
           %AgentToolResult{
             content: [AgentCore.text_content("ok")],
             details: %{path: path, bytes: byte_size(content), root: root},
             trust: :trusted
           }}
        else
          {:error, :too_large} ->
            {:error, "Memory write exceeds size limit"}

          {:error, reason} when is_binary(reason) ->
            {:error, reason}

          {:error, reason} ->
            {:error, "Unable to write memory file: #{inspect(reason)}"}
        end
      end
    }
  end

  defp patch_tool(root) do
    %AgentTool{
      name: "memory_patch_file",
      label: "Memory Patch",
      description:
        "Patch text in a memory file by replacing target text with replacement text.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Relative file path"},
          "target" => %{"type" => "string", "description" => "Text to replace"},
          "replacement" => %{"type" => "string", "description" => "Replacement text"},
          "replace_all" => %{
            "type" => "boolean",
            "description" => "Replace all occurrences (default: false)"
          }
        },
        "required" => ["path", "target", "replacement"],
        "additionalProperties" => false
      },
      execute: fn _id, params, _signal, _on_update ->
        with {:ok, path} <- fetch_string(params, "path"),
             {:ok, target} <- fetch_string(params, "target"),
             {:ok, replacement} <- fetch_string(params, "replacement"),
             true <- target != "" or {:error, :empty_target},
             {:ok, abs_path} <- resolve_memory_path(root, path),
             {:ok, content} <- File.read(abs_path),
             {updated, replacements} <- replace_content(content, target, replacement, params),
             :ok <- File.write(abs_path, updated) do
          {:ok,
           %AgentToolResult{
             content: [AgentCore.text_content("ok")],
             details: %{path: path, replacements: replacements, root: root},
             trust: :trusted
           }}
        else
          {:error, :empty_target} ->
            {:error, "Patch target must not be empty"}

          {:error, :enoent} ->
            {:error, "Memory file not found"}

          {:error, reason} when is_binary(reason) ->
            {:error, reason}

          {:error, reason} ->
            {:error, "Unable to patch memory file: #{inspect(reason)}"}
        end
      end
    }
  end

  defp list_tool(root, opts) do
    list_limit = Keyword.get(opts, :memory_list_limit, @default_list_limit)

    %AgentTool{
      name: "memory_list_files",
      label: "Memory List",
      description: "List memory files under a relative directory.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Relative directory path (default: .)"
          },
          "recursive" => %{
            "type" => "boolean",
            "description" => "List recursively (default: false)"
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Max files to return",
            "minimum" => 1
          }
        },
        "required" => [],
        "additionalProperties" => false
      },
      execute: fn _id, params, _signal, _on_update ->
        with {:ok, rel_dir} <- fetch_optional_string(params, "path", "."),
             {:ok, abs_dir} <- resolve_memory_path(root, rel_dir),
             true <- File.dir?(abs_dir) or {:error, :not_directory},
             files <- list_files(abs_dir, Map.get(params, "recursive", false)),
             limit <- normalize_positive_int(Map.get(params, "limit"), list_limit),
             visible <- files |> Enum.map(&Path.relative_to(&1, root)) |> Enum.take(limit) do
          {:ok,
           %AgentToolResult{
             content: [AgentCore.text_content(Enum.join(visible, "\n"))],
             details: %{count: length(visible), root: root},
             trust: :trusted
           }}
        else
          {:error, :not_directory} ->
            {:error, "Memory path is not a directory"}

          {:error, reason} when is_binary(reason) ->
            {:error, reason}

          {:error, reason} ->
            {:error, "Unable to list memory files: #{inspect(reason)}"}
        end
      end
    }
  end

  defp delete_tool(root) do
    %AgentTool{
      name: "memory_delete_file",
      label: "Memory Delete",
      description: "Delete a memory file by relative path.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Relative file path"}
        },
        "required" => ["path"],
        "additionalProperties" => false
      },
      execute: fn _id, params, _signal, _on_update ->
        with {:ok, path} <- fetch_string(params, "path"),
             {:ok, abs_path} <- resolve_memory_path(root, path),
             :ok <- File.rm(abs_path) do
          {:ok,
           %AgentToolResult{
             content: [AgentCore.text_content("ok")],
             details: %{path: path, root: root},
             trust: :trusted
           }}
        else
          {:error, :enoent} ->
            {:error, "Memory file not found"}

          {:error, reason} when is_binary(reason) ->
            {:error, reason}

          {:error, reason} ->
            {:error, "Unable to delete memory file: #{inspect(reason)}"}
        end
      end
    }
  end

  defp ensure_memory_root!(root) do
    File.mkdir_p!(root)
  end

  defp ensure_index!(root) do
    index_path = Path.join(root, "index.md")

    if not File.exists?(index_path) do
      File.write!(
        index_path,
        """
        # Memory Index

        Keep memory concise and focused. Link to topic files as needed.
        """
      )
    end
  end

  defp resolve_memory_path(root, path) do
    path = String.trim(path || "")

    cond do
      path == "" ->
        {:error, "Path must not be empty"}

      Path.type(path) == :absolute ->
        {:error, "Path must be relative to memory root"}

      true ->
        expanded = Path.expand(path, root)

        if within_root?(expanded, root) do
          {:ok, expanded}
        else
          {:error, "Path escapes memory root"}
        end
    end
  end

  defp within_root?(path, root) do
    path == root or String.starts_with?(path, root <> "/")
  end

  defp write_file(path, content, "append"), do: File.write(path, content, [:append])
  defp write_file(path, content, _), do: File.write(path, content)

  defp replace_content(content, target, replacement, params) do
    replace_all? = Map.get(params, "replace_all", false)

    if replace_all? do
      count = count_occurrences(content, target)
      {String.replace(content, target, replacement), count}
    else
      case :binary.matches(content, target) do
        [] ->
          {content, 0}

        [{idx, len} | _] ->
          prefix = binary_part(content, 0, idx)
          suffix = binary_part(content, idx + len, byte_size(content) - idx - len)
          {prefix <> replacement <> suffix, 1}
      end
    end
  end

  defp count_occurrences(content, target) do
    :binary.matches(content, target)
    |> length()
  end

  defp list_files(abs_dir, true) do
    abs_dir
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
  end

  defp list_files(abs_dir, false) do
    abs_dir
    |> File.ls!()
    |> Enum.map(&Path.join(abs_dir, &1))
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
  end

  defp fetch_string(map, key) when is_map(map) and is_binary(key) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        {:ok, value}

      _ ->
        {:error, "Expected string parameter: #{key}"}
    end
  end

  defp fetch_optional_string(map, key, default) when is_map(map) and is_binary(key) do
    case Map.get(map, key, default) do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, "Expected string parameter: #{key}"}
    end
  end

  defp normalize_positive_int(value, default) when is_integer(default) and default > 0 do
    case value do
      int when is_integer(int) and int > 0 -> int
      _ -> default
    end
  end
end
