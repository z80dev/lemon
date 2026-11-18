defmodule LemonGateway.Tools.OutboundFile do
  @moduledoc """
  Path resolution shared by the file-sending tools (`discord_send_file`,
  `telegram_send_image`).

  Relative paths (including the `workspace/`, `./workspace/` and
  `.lemon/agent/workspace/` prefixes, which map to the workspace dir) are
  resolved through `LemonCore.FileAccess` beneath the project root, then the
  workspace dir. Absolute and `~` paths are accepted only when they lie under a
  root's expanded or physical path; they are converted to root-relative
  components and resolved the same way, so symlinks below the root, `..`,
  built-in secret names and the channel's `files.deny_globs` are refused.

  Callers queue `LemonCore.FileAccess.retain_copy/2` of the returned bytes,
  never the source path, so a later change to the source cannot alter what is
  delivered.
  """

  alias LemonCore.FileAccess

  @workspace_prefixes ["workspace/", "./workspace/", ".lemon/agent/workspace/"]
  @outside_error "Path must stay within the active workspace/project roots."

  @doc """
  Read the regular file `path` from the project/workspace roots. Returns the
  actual entry name and its bytes.
  """
  @spec read(String.t(), String.t() | nil, String.t() | nil, term(), pos_integer()) ::
          {:ok, String.t(), binary()} | {:error, String.t()}
  def read(path, root, workspace_dir, globs, max_bytes) when is_binary(path) do
    roots = [root, workspace_dir] |> Enum.filter(&is_binary/1) |> Enum.uniq()
    path = expand_user_home(path)

    cond do
      roots == [] ->
        {:error, "No project or workspace root is available."}

      String.contains?(path, <<0>>) ->
        {:error, "Invalid path."}

      ".." in Path.split(path) ->
        {:error, @outside_error}

      Path.type(path) == :absolute ->
        case absolute_candidates(Path.expand(path), roots) do
          [] -> {:error, @outside_error}
          candidates -> first_readable(candidates, globs, max_bytes)
        end

      true ->
        path
        |> relative_candidates(roots, workspace_dir)
        |> first_readable(globs, max_bytes)
    end
  end

  @doc "The running gateway config section for `channel`, or `%{}`."
  @spec channel_config(atom()) :: map() | keyword()
  def channel_config(channel) do
    case LemonGateway.Config.get_or_env(channel, %{}) do
      cfg when is_map(cfg) or is_list(cfg) -> cfg
      _ -> %{}
    end
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  @doc "Configured `files.deny_globs` of a channel config section."
  @spec deny_globs(map() | keyword()) :: term()
  def deny_globs(channel_cfg) do
    files = channel_cfg[:files] || channel_cfg["files"] || %{}

    if is_map(files) or is_list(files),
      do: files[:deny_globs] || files["deny_globs"],
      else: nil
  end

  defp relative_candidates(path, roots, workspace_dir) do
    prefixed =
      if is_binary(workspace_dir) do
        for prefix <- @workspace_prefixes, String.starts_with?(path, prefix) do
          {workspace_dir, String.replace_prefix(path, prefix, "")}
        end
      else
        []
      end

    Enum.uniq(prefixed ++ Enum.map(roots, &{&1, path}))
  end

  # A root may be named through a symlink, so an absolute path is matched
  # lexically against both its expanded and its physical spelling.
  defp absolute_candidates(path, roots) do
    path_parts = Path.split(path)

    for root <- roots,
        base <- Enum.uniq([Path.expand(root) | physical(root)]),
        rel <- List.wrap(relative_under(path_parts, Path.split(base))),
        uniq: true,
        do: {root, rel}
  end

  defp physical(root) do
    case FileAccess.real_root(root) do
      {:ok, real} -> [real]
      {:error, _} -> []
    end
  end

  defp relative_under(path_parts, base_parts) do
    if length(path_parts) > length(base_parts) and List.starts_with?(path_parts, base_parts),
      do: path_parts |> Enum.drop(length(base_parts)) |> Path.join(),
      else: nil
  end

  defp first_readable(candidates, globs, max_bytes) do
    Enum.reduce_while(candidates, {:error, "File not found."}, fn {root, rel}, error ->
      result =
        with {:ok, real} <- FileAccess.real_root(root),
             do: FileAccess.read_file(real, rel, globs, max_bytes)

      case result do
        {:ok, _name, _bytes} = ok -> {:halt, ok}
        {:error, "Not found."} -> {:cont, error}
        {:error, "No accessible working directory configured."} -> {:cont, error}
        {:error, "File is too large."} -> {:halt, too_large(max_bytes)}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp too_large(max_bytes),
    do: {:error, "File is too large. Max allowed is #{max_bytes} bytes."}

  defp expand_user_home(path) do
    home = System.user_home()

    cond do
      is_binary(home) and String.starts_with?(path, "~/") ->
        Path.join(home, String.replace_prefix(path, "~/", ""))

      is_binary(home) and path == "~" ->
        home

      true ->
        path
    end
  end
end
