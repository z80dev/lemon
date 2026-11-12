defmodule LemonBrowser.Backends.Tern do
  @moduledoc "Native Tern browser automation over the pane daemon socket."
  @behaviour LemonBrowser.Backend

  alias LemonBrowser.TernSession
  alias LemonCore.Tern

  @impl true
  def id, do: :tern

  @impl true
  def available?, do: available?([])

  @impl true
  def available?(opts) do
    pane =
      if Keyword.has_key?(opts, :tern_pane),
        do: Tern.pane(Keyword.get(opts, :tern_pane)),
        else: Tern.resolve_pane()

    with true <- Tern.enabled?(opts),
         {:ok, _pane} <- pane,
         {:ok, client} <- Tern.connect() do
      try do
        Tern.supports?(client, "browser")
      after
        Tern.close(client)
      end
    else
      _ -> false
    end
  end

  @impl true
  def request(method, args, timeout_ms, opts) do
    if Tern.enabled?(opts) do
      TernSession.request(method, args, timeout_ms, opts)
    else
      {:error, {:unsupported, "Tern browser integration is disabled"}}
    end
  end

  @impl true
  def status(opts) do
    %{backend: :tern, available: available?(opts), sessions: TernSession.status()}
  end
end
