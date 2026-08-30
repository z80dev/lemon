defmodule CodingAgent.Search.Provider do
  @moduledoc """
  Contract for web search and extraction providers.

  Providers are deliberately independent of model tools and session state. The
  caller resolves credentials and policy into a bounded context map, while the
  provider performs one capability-specific request and returns normalized data.
  Provider output is still considered untrusted and must pass through the
  coding-agent external-content boundary before it reaches a model.
  """

  @type capability :: :search | :extract
  @type request :: map()
  @type context :: map()
  @type result :: {:ok, map()} | {:error, term()}

  @doc "Stable lowercase provider identifier."
  @callback id() :: String.t()

  @doc "Capabilities implemented by this provider."
  @callback capabilities() :: [capability()]

  @doc "Checks resolved configuration without making a network request."
  @callback available?(capability(), context()) :: :ok | {:error, term()}

  @doc "Runs a normalized web search request."
  @callback search(request(), context()) :: result()

  @doc "Extracts readable content from a URL."
  @callback extract(request(), context()) :: result()

  @optional_callbacks search: 2, extract: 2

  @doc false
  @spec valid_capability?(term()) :: boolean()
  def valid_capability?(capability), do: capability in [:search, :extract]
end
