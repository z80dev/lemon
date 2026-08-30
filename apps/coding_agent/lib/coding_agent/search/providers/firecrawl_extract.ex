defmodule CodingAgent.Search.Providers.FirecrawlExtract do
  @moduledoc "Firecrawl readable-content extraction adapter."

  @behaviour CodingAgent.Search.Provider

  @impl true
  def id, do: "firecrawl"

  @impl true
  def capabilities, do: [:extract]

  @impl true
  def available?(:extract, %{extract: fun}) when is_function(fun, 1), do: :ok
  def available?(:extract, _context), do: {:error, :missing_firecrawl_extract_adapter}

  @impl true
  def extract(request, context), do: context.extract.(request)
end
