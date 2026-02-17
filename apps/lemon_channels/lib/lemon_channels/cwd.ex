defmodule LemonChannels.Cwd do
  @moduledoc false

  @spec default_cwd() :: String.t()
  def default_cwd do
    case configured_default_cwd() |> normalize_existing_dir() do
      nil -> home_or_process_cwd()
      cwd -> cwd
    end
  end

  defp configured_default_cwd do
    LemonChannels.GatewayConfig.get(:default_cwd)
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
