defmodule LemonGateway.Cwd do
  @moduledoc """
  Resolves the default working directory for engine runs.

  Falls back through: configured `default_cwd` -> user home directory -> process cwd.
  """

  @doc "Returns the default working directory, resolved from config, home, or process cwd."
  @spec default_cwd() :: String.t()
  def default_cwd do
    case configured_default_cwd() |> normalize_existing_dir() do
      nil -> home_or_process_cwd()
      cwd -> cwd
    end
  end

  defp configured_default_cwd do
    if is_pid(Process.whereis(LemonGateway.Config)) do
      LemonGateway.Config.get(:default_cwd)
    else
      cfg = LemonGateway.ConfigLoader.load()
      cfg[:default_cwd] || cfg["default_cwd"]
    end
  rescue
    _ -> nil
  end

  defp home_or_process_cwd do
    case System.user_home() |> normalize_existing_dir() do
      nil -> File.cwd!()
      cwd -> cwd
    end
  rescue
    _ -> File.cwd!()
  end

  defp normalize_existing_dir(path) when is_binary(path) do
    path = String.trim(path)

    if path == "" do
      nil
    else
      expanded = Path.expand(path)
      if File.dir?(expanded), do: expanded, else: nil
    end
  end

  defp normalize_existing_dir(_), do: nil
end
