defmodule LemonCore.OutputIntent do
  @moduledoc """
  Channel-neutral output intent describing WHAT should be delivered,
  not HOW it should be delivered. The translation from intent to
  channel-specific payload happens in LemonChannels.Dispatcher.
  """

  @enforce_keys [:route, :op]
  defstruct [:route, :op, body: %{}, meta: %{}]

  @type op ::
          :stream_append
          | :stream_replace
          | :tool_status
          | :keepalive_prompt
          | :final_text
          | :fanout_text
          | :send_files

  @type t :: %__MODULE__{
          route: LemonCore.ChannelRoute.t(),
          op: op(),
          body: map(),
          meta: map()
        }
end
