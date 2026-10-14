defmodule CodingAgent.Artifacts do
  @moduledoc """
  Session-scoped, disk-backed references to existing tool output files.

  An `artifact://` handle is the SHA-256 of the absolute output path. A small
  JSON record beneath the session spill directory's `.artifacts` directory
  maps the handle back to that path, including outputs outside the spill
  directory. Registration never reads, copies, or changes output contents.

  The session APIs require `:session_id` in their options. A root
  `:context_guardrails` map or keyword list may override `:spill_dir`; that
  override must be the session's spill directory, just as for guardrails.
  Otherwise `CodingAgent.Config.spill_dir/2` supplies the directory. There is
  no process-local or global registry, so handles survive process restarts.
  """

  alias CodingAgent.Config
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  @type options :: keyword() | map()

  @doc "Registers an existing output file in the current session's index."
  @spec register(String.t(), String.t(), options()) :: {:ok, String.t()} | {:error, String.t()}
  def register(path, cwd, opts) do
    with {:ok, directory} <- spill_dir(cwd, opts),
         :ok <- validate_path(path) do
      register_in_dir(Path.expand(path, cwd), directory)
    end
  end

  @doc """
  Adds a retrievable handle to a tool result carrying an output file. A result
  whose `details.artifact_truncated` is true is labelled as partial output.
  """
  @spec attach(term(), String.t(), options()) :: term()
  def attach(%AgentToolResult{details: %{full_output_path: path} = details} = result, cwd, opts)
      when is_binary(path) do
    case register(path, cwd, opts) do
      {:ok, uri} ->
        label =
          if Map.get(details, :artifact_truncated) == true,
            do: "Partial output (saving stopped early; later output was not saved)",
            else: "Full output"

        reference = %TextContent{
          text: "[#{label}: #{uri} — read this handle with offset and limit for more lines]"
        }

        %{
          result
          | content: [reference | result.content],
            details: Map.put(result.details, :artifact_uri, uri)
        }

      {:error, _} ->
        result
    end
  end

  def attach(result, _cwd, _opts), do: result

  @doc """
  Registers an existing output in an explicitly selected session spill directory.

  This entry point lets guardrails use the directory they already selected.
  Relative output paths are relative to that directory. A handle is returned
  only after its index entry has been written successfully.
  """
  @spec register_in_dir(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def register_in_dir(path, directory) do
    with :ok <- validate_path(directory),
         :ok <- validate_path(path),
         absolute_path = Path.expand(path, Path.expand(directory)),
         :ok <- ensure_output(absolute_path),
         id = path_id(absolute_path),
         index_path = index_path(directory, id),
         :ok <- persist(index_path, absolute_path, id) do
      {:ok, "artifact://" <> id}
    end
  end

  @doc "Resolves a handle only through the current session's on-disk index."
  @spec resolve(String.t(), String.t(), options()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve(uri, cwd, opts) do
    with {:ok, directory} <- spill_dir(cwd, opts) do
      resolve_in_dir(uri, directory)
    end
  end

  @doc "Resolves a handle within an explicitly selected session spill directory."
  @spec resolve_in_dir(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resolve_in_dir(uri, directory) do
    with {:ok, id} <- parse_handle(uri),
         :ok <- validate_path(directory),
         {:ok, path} <- read_index(index_path(directory, id), id),
         :ok <- ensure_output(path) do
      {:ok, path}
    end
  end

  @doc "Returns the session spill directory, or a clear error without session context."
  @spec spill_dir(String.t(), options()) :: {:ok, String.t()} | {:error, String.t()}
  def spill_dir(cwd, opts) do
    session_id = option(opts, :session_id)

    with :ok <- validate_session(session_id),
         :ok <- validate_path(cwd) do
      directory = option(option(opts, :context_guardrails), :spill_dir)
      directory = directory || Config.spill_dir(cwd, session_id)

      with :ok <- validate_path(directory) do
        {:ok, Path.expand(directory, cwd)}
      end
    end
  end

  defp option(opts, key) when is_map(opts), do: Map.get(opts, key)
  defp option(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp option(_opts, _key), do: nil

  defp validate_session(session_id) do
    if valid_path?(session_id) and String.trim(session_id) != "" do
      :ok
    else
      {:error, "Artifact references require a non-empty session_id"}
    end
  end

  defp validate_path(path) do
    if valid_path?(path), do: :ok, else: {:error, "Invalid artifact filesystem path"}
  end

  defp valid_path?(path) do
    is_binary(path) and path != "" and String.valid?(path) and
      not Regex.match?(~r/[\x00-\x1f\x7f-\x9f]/u, path)
  end

  defp parse_handle("artifact://" <> id) do
    if byte_size(id) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, id) do
      {:ok, id}
    else
      {:error,
       "Malformed artifact handle; expected artifact:// followed by 64 lowercase hex digits"}
    end
  end

  defp parse_handle(_uri), do: {:error, "Malformed artifact handle; expected artifact://<id>"}

  defp path_id(path), do: :crypto.hash(:sha256, path) |> Base.encode16(case: :lower)

  defp index_path(directory, id),
    do: Path.join([Path.expand(directory), ".artifacts", id <> ".json"])

  defp ensure_output(path) do
    case File.stat(path) do
      {:ok, %{type: :regular}} -> :ok
      {:ok, _} -> {:error, "Artifact output is not a regular file"}
      {:error, :enoent} -> {:error, "Artifact output file is missing or has been deleted"}
      {:error, reason} -> filesystem_error("Cannot access artifact output", reason)
    end
  end

  defp persist(index_path, output_path, id) do
    case read_index(index_path, id) do
      {:ok, ^output_path} -> :ok
      _ -> write_index(index_path, output_path)
    end
  end

  defp write_index(index_path, output_path) do
    temporary = index_path <> ".tmp-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    contents = Jason.encode!(%{version: 1, path: output_path})

    result =
      with :ok <- File.mkdir_p(Path.dirname(index_path)),
           :ok <- File.write(temporary, contents, [:binary, :exclusive]),
           :ok <- File.rename(temporary, index_path) do
        :ok
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        File.rm(temporary)
        filesystem_error("Cannot persist artifact index", reason)
    end
  end

  defp read_index(index_path, id) do
    case File.read(index_path) do
      {:ok, contents} -> decode_index(contents, id)
      {:error, :enoent} -> {:error, "Artifact is not registered in the current session"}
      {:error, reason} -> filesystem_error("Cannot read artifact index", reason)
    end
  end

  defp decode_index(contents, id) do
    with {:ok, %{"version" => 1, "path" => path}} <- Jason.decode(contents),
         true <- valid_path?(path),
         true <- Path.type(path) == :absolute,
         true <- path_id(path) == id do
      {:ok, path}
    else
      _ -> {:error, "Artifact index entry is invalid"}
    end
  end

  defp filesystem_error(message, reason) do
    {:error, message <> ": " <> List.to_string(:file.format_error(reason))}
  end
end
