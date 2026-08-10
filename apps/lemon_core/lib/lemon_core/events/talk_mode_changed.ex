defmodule LemonCore.Events.TalkModeChanged do
  @moduledoc """
  A session's talk mode changed. Published on `system`.
  """

  use LemonCore.Events.Payload,
    type: :talk_mode_changed,
    enforce: [:session_key, :mode],
    fields: [session_key: nil, mode: nil]

  @type t :: %__MODULE__{session_key: String.t(), mode: atom() | String.t()}
end
