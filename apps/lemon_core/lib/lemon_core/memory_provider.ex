defmodule LemonCore.MemoryProvider do
  @moduledoc """
  Behaviour for searchable memory providers.

  Providers receive the same scoped search options as `LemonCore.SessionSearch`
  and return `LemonCore.MemoryDocument` structs. Provider implementations must
  not raise for user input; `LemonCore.MemoryProviders` isolates provider
  failures and timeouts, but providers should still treat search as best-effort.
  """

  alias LemonCore.MemoryDocument

  @type scope :: :session | :agent | :workspace | :all
  @type search_opts :: keyword()

  @callback put(MemoryDocument.t(), keyword()) :: :ok | {:error, term()}
  @callback search(binary(), search_opts()) :: [MemoryDocument.t()]
end
