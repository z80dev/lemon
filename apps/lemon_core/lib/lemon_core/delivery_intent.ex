defmodule LemonCore.DeliveryIntent do
  @moduledoc """
  Semantic router-to-channels delivery contract.
  """

  alias LemonCore.DeliveryRoute

  @type kind ::
          :stream_snapshot
          | :stream_finalize
          | :tool_status_snapshot
          | :tool_status_finalize
          | :final_text
          | :file_batch
          | :reaction
          | :watchdog_prompt

  @enforce_keys [:intent_id, :run_id, :session_key, :route, :kind]
  defstruct [
    :intent_id,
    :run_id,
    :session_key,
    :route,
    :kind,
    body: %{},
    attachments: [],
    controls: %{},
    meta: %{}
  ]

  @type t :: %__MODULE__{
          intent_id: String.t(),
          run_id: String.t(),
          session_key: String.t(),
          route: DeliveryRoute.t(),
          kind: kind(),
          body: map(),
          attachments: list(),
          controls: map(),
          meta: map()
        }
end
