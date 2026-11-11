defmodule CodingAgent.ExecutionNode.BotFolder do
  @moduledoc "Destination-local profile files directories; never accepts a caller-supplied root."

  alias LemonCore.ProfileStore

  def ensure(profile_id, opts \\ []) do
    with {:ok, paths} <- ProfileStore.paths(profile_id, opts) do
      root = paths["files"]

      :global.trans({{__MODULE__, root}, self()}, fn ->
        with :ok <- private_directory(Path.dirname(Path.dirname(Path.dirname(root)))),
             :ok <- private_directory(Path.dirname(Path.dirname(root))),
             :ok <- private_directory(Path.dirname(root)),
             :ok <- private_directory(root) do
          {:ok, root}
        else
          _ -> {:error, :invalid_cwd}
        end
      end)
    else
      _ -> {:error, :invalid_cwd}
    end
  end

  defp private_directory(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        File.chmod(path, 0o700)

      {:error, :enoent} ->
        with :ok <- File.mkdir_p(Path.dirname(path)) do
          case File.mkdir(path) do
            :ok -> File.chmod(path, 0o700)
            {:error, :eexist} -> private_directory(path)
            error -> error
          end
        end

      _ ->
        {:error, :invalid_directory}
    end
  end
end
