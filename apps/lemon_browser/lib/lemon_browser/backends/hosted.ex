defmodule LemonBrowser.Backends.Hosted do
  @moduledoc false

  alias LemonBrowser.CloudSession
  alias LemonBrowser.SessionProviderRegistry

  def available?(provider) do
    case SessionProviderRegistry.fetch(provider) do
      {:ok, module} -> module.available?()
      :error -> false
    end
  end

  def available?(provider, opts) do
    case SessionProviderRegistry.fetch(provider) do
      {:ok, module} ->
        if function_exported?(module, :available?, 1),
          do: module.available?(opts),
          else: module.available?()

      :error ->
        false
    end
  end

  def request(provider, method, args, timeout_ms, opts) do
    CloudSession.request(provider, method, args, timeout_ms, opts)
  end

  def status(provider) do
    provider_status =
      case SessionProviderRegistry.fetch(provider) do
        {:ok, module} -> module.status()
        :error -> %{provider: provider, configured: false, error: "unknown provider"}
      end

    Map.merge(provider_status, %{
      available: available?(provider),
      sessions: CloudSession.status(provider),
      session_count: length(CloudSession.status(provider))
    })
  end

  def status(provider, opts) do
    status(provider) |> Map.put(:available, available?(provider, opts))
  end
end

defmodule LemonBrowser.Backends.Browserbase do
  @moduledoc "Browserbase hosted-CDP backend."
  @behaviour LemonBrowser.Backend
  alias LemonBrowser.Backends.Hosted
  def id, do: :browserbase
  def available?, do: Hosted.available?(:browserbase)
  def available?(opts), do: Hosted.available?(:browserbase, opts)
  def request(method, args, timeout_ms, opts), do: Hosted.request(:browserbase, method, args, timeout_ms, opts)
  def status(opts), do: Hosted.status(:browserbase, opts)
end

defmodule LemonBrowser.Backends.BrowserUse do
  @moduledoc "Browser Use Cloud hosted-CDP backend."
  @behaviour LemonBrowser.Backend
  alias LemonBrowser.Backends.Hosted
  def id, do: :browser_use
  def available?, do: Hosted.available?(:browser_use)
  def available?(opts), do: Hosted.available?(:browser_use, opts)
  def request(method, args, timeout_ms, opts), do: Hosted.request(:browser_use, method, args, timeout_ms, opts)
  def status(opts), do: Hosted.status(:browser_use, opts)
end

defmodule LemonBrowser.Backends.Firecrawl do
  @moduledoc "Firecrawl hosted-CDP backend."
  @behaviour LemonBrowser.Backend
  alias LemonBrowser.Backends.Hosted
  def id, do: :firecrawl
  def available?, do: Hosted.available?(:firecrawl)
  def available?(opts), do: Hosted.available?(:firecrawl, opts)
  def request(method, args, timeout_ms, opts), do: Hosted.request(:firecrawl, method, args, timeout_ms, opts)
  def status(opts), do: Hosted.status(:firecrawl, opts)
end
