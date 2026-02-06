defmodule LemonRouter.SessionKey do
  @moduledoc """
  Backward-compatible wrapper around `LemonCore.SessionKey`.

  The canonical implementation lives in `LemonCore` so it can be shared by
  both the router/control-plane and transport runtimes (e.g. Telegram gateway).
  """

  defdelegate main(agent_id), to: LemonCore.SessionKey
  defdelegate channel_peer(opts), to: LemonCore.SessionKey
  defdelegate parse(session_key), to: LemonCore.SessionKey
  defdelegate valid?(session_key), to: LemonCore.SessionKey
  defdelegate allowed_peer_kinds(), to: LemonCore.SessionKey
  defdelegate agent_id(session_key), to: LemonCore.SessionKey
  defdelegate main?(session_key), to: LemonCore.SessionKey
  defdelegate channel_peer?(session_key), to: LemonCore.SessionKey
end

