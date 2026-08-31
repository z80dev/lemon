defmodule CodingAgent.Search.Providers.DirectExtract do
  @moduledoc "Guarded local HTTP/readability extraction adapter."

  @behaviour CodingAgent.Search.Provider

  @impl true
  def id, do: "direct"

  @impl true
  def capabilities, do: [:extract]

  @impl true
  def available?(:extract, %{extract: fun}) when is_function(fun, 1), do: :ok
  def available?(:extract, _context), do: {:error, :missing_direct_extract_adapter}

  @impl true
  def extract(request, context), do: context.extract.(request)
end
