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
    case Process.whereis(LemonGateway.Config) do
      nil -> app_env_default_cwd()
      _pid -> LemonGateway.Config.get(:default_cwd) || app_env_default_cwd()
    end
  rescue
    _ -> app_env_default_cwd()
  catch
    :exit, _ -> app_env_default_cwd()
  end

  defp app_env_default_cwd do
    case Application.get_env(:lemon_gateway, LemonGateway.Config) do
      %{default_cwd: cwd} ->
        cwd

      %{"default_cwd" => cwd} ->
        cwd

      config when is_list(config) ->
        Keyword.get(config, :default_cwd) || Keyword.get(config, "default_cwd")

      _ ->
        nil
    end
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
