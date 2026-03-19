defmodule LemonSimUi.ProjectRoot do
  @moduledoc false

  @spec resolve(String.t()) :: String.t()
  def resolve(start_dir) when is_binary(start_dir) do
    start_dir
    |> Path.expand()
    |> do_resolve()
  end

  defp do_resolve(dir) do
    cond do
      umbrella_root?(dir) ->
        dir

      true ->
        parent = Path.dirname(dir)

        if parent == dir do
          File.cwd!()
        else
          do_resolve(parent)
        end
    end
  end

  defp umbrella_root?(dir) do
    File.exists?(Path.join(dir, "mix.exs")) and File.dir?(Path.join(dir, "apps"))
  end
end
