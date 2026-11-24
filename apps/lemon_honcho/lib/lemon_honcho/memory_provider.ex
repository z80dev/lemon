defmodule LemonHoncho.MemoryProvider do
  @moduledoc """
  Honcho as a `LemonMemory.Provider` write target.

  `LemonMemory` hands every finished run's document to each registered
  provider. This module is the entry Honcho occupies in that fan-out: it passes
  the document to `LemonHoncho.SessionManager`, which uploads the run's bounded
  prompt/answer summaries to the owner's Honcho session off the caller's path.

  Providers are write targets only: recall reads the owned local index, and
  Honcho's memory is read through the owner-scoped context block and the
  explicit `honcho_*` tools, never through a provider search whose results the
  local recall path could not attribute or display.

  ## `put/2` always returns `:ok`

  It returns `:ok` when Honcho is unconfigured too, and when the manager is not
  even running. That is deliberate rather than sloppy: `put/2` runs on the
  run-finalisation path where the registry logs the error and discards it, so an
  `{:error, _}` for the ordinary state of "this optional integration is switched
  off" buys nothing but a warning per finished run. The manager owns
  `save_messages?`, the "is this configured" decision and owner proof, so those
  live in exactly one place.
  """

  @behaviour LemonMemory.Provider

  alias LemonHoncho.SessionManager
  alias LemonMemory.Document

  @doc """
  Hands a finished run's document to `LemonHoncho.SessionManager` for upload.

  Always returns `:ok` — see the moduledoc for why an unconfigured or unreachable
  Honcho is not reported as an error here.
  """
  @impl true
  @spec put(Document.t(), keyword()) :: :ok
  def put(%Document{} = document, _opts) do
    SessionManager.sync_document(document)
    :ok
  end
end
