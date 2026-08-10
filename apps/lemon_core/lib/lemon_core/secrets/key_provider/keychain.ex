defmodule LemonCore.Secrets.KeyProvider.Keychain do
  @moduledoc """
  Master key provider backed by the macOS Keychain.

  Only active on macOS: on every other platform `available?/1` is false and
  `fetch/1` reports `:unavailable`, so the resolution chain moves on without
  shelling out.

  Tests and host applications can substitute the backing module with the
  `:keychain_module` option; doing so bypasses the platform guard, since the
  substitute is by definition not the real `security(1)` wrapper.
  """

  use LemonCore.Secrets.KeyProvider

  alias LemonCore.Secrets.Keychain
  alias LemonCore.Secrets.KeyProvider

  @impl true
  def name, do: :keychain

  @impl true
  def available?(opts) do
    module = module(opts)

    platform_ok?(opts) and KeyProvider.exports?(module, :available?, 0) and module.available?()
  end

  @impl true
  def fetch(opts) do
    module = module(opts)

    cond do
      not platform_ok?(opts) -> {:error, :unavailable}
      not KeyProvider.exports?(module, :get_master_key, 1) -> {:error, :unavailable}
      true -> module.get_master_key(opts)
    end
  end

  @impl true
  def put(value, opts) do
    module = module(opts)

    cond do
      not platform_ok?(opts) -> {:error, :unavailable}
      not KeyProvider.exports?(module, :put_master_key, 2) -> {:error, :unavailable}
      true -> module.put_master_key(value, opts)
    end
  end

  @impl true
  def on_invalid, do: :continue

  defp module(opts), do: Keyword.get(opts, :keychain_module, Keychain)

  # A caller-supplied keychain module (or command runner) is trusted on any
  # platform; the real one is macOS-only.
  defp platform_ok?(opts) do
    Keyword.has_key?(opts, :keychain_module) or Keyword.has_key?(opts, :runner) or
      match?({:unix, :darwin}, os_type(opts))
  end

  defp os_type(opts), do: Keyword.get(opts, :os_type) || :os.type()
end
