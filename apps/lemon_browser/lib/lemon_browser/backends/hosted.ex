defmodule LemonBrowser.Backends.Hosted do
  @moduledoc false

  defmacro __using__(opts) do
    provider = Keyword.fetch!(opts, :provider)

    quote bind_quoted: [provider: provider] do
      @behaviour LemonBrowser.Backend
      @provider provider
      def id, do: @provider
      def available?, do: LemonBrowser.Backends.Hosted.available?(@provider)
      def available?(opts), do: LemonBrowser.Backends.Hosted.available?(@provider, opts)

      def request(method, args, timeout_ms, opts),
        do: LemonBrowser.Backends.Hosted.request(@provider, method, args, timeout_ms, opts)

      def status(opts), do: LemonBrowser.Backends.Hosted.status(@provider, opts)
    end
  end

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

    sessions = CloudSession.status(provider)

    Map.merge(provider_status, %{
      available: available?(provider),
      sessions: sessions,
      session_count: length(sessions)
    })
  end

  def status(provider, opts) do
    status(provider) |> Map.put(:available, available?(provider, opts))
  end
end

defmodule LemonBrowser.Backends.Browserbase do
  @moduledoc "Browserbase hosted-CDP backend."
  use LemonBrowser.Backends.Hosted, provider: :browserbase
end

defmodule LemonBrowser.Backends.BrowserUse do
  @moduledoc "Browser Use Cloud hosted-CDP backend."
  use LemonBrowser.Backends.Hosted, provider: :browser_use
end

defmodule LemonBrowser.Backends.Firecrawl do
  @moduledoc "Firecrawl hosted-CDP backend."
  use LemonBrowser.Backends.Hosted, provider: :firecrawl
end
