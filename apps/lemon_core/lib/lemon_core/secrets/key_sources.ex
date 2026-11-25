defmodule LemonCore.Secrets.KeySources do
  @moduledoc "Resolves the configured order of master key providers."
  require Logger

  alias LemonCore.Secrets.KeyProvider

  @builtin %{keychain: KeyProvider.Keychain, env: KeyProvider.Env, file: KeyProvider.File}
  @default_order [:keychain, :env, :file]

  def default_order, do: @default_order

  @spec order(keyword()) :: [module()]
  def order(opts \\ []) do
    opts
    |> KeyProvider.option(:key_providers, @default_order)
    |> List.wrap()
    |> Enum.map(&translate/1)
    |> Enum.reject(&is_nil/1)
  end

  defp translate(name) when is_atom(name) do
    case Map.fetch(@builtin, name) do
      {:ok, module} ->
        module

      :error ->
        if Code.ensure_loaded?(name) do
          name
        else
          Logger.warning("Ignoring unknown secrets key provider: #{inspect(name)}")
          nil
        end
    end
  end

  defp translate(other) do
    Logger.warning("Ignoring invalid secrets key provider: #{inspect(other)}")
    nil
  end
end
