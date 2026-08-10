defmodule LemonMemory.Provider do
  @moduledoc """
  Behaviour for searchable memory providers.

  Providers receive the same scoped search options as `LemonMemory.SessionSearch`
  and return `LemonMemory.Document` structs. Provider implementations must
  not raise for user input; `LemonMemory.Providers` isolates provider
  failures and timeouts, but providers should still treat search as best-effort.
  """

  alias LemonMemory.Document

  @type scope :: :session | :agent | :workspace | :all
  @type search_opts :: keyword()

  @callback put(Document.t(), keyword()) :: :ok | {:error, term()}
  @callback search(binary(), search_opts()) :: [Document.t()]
end
