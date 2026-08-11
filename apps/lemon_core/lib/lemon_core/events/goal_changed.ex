defmodule LemonCore.Events.GoalChanged do
  @moduledoc """
  A durable goal's lifecycle changed. Published on `goals` and `session:<session_key>` by
  `LemonAgent.Workspace.GoalStore`; the specific transition is the `LemonCore.Event` type
  (`:goal_set`, `:goal_paused`, `:goal_resumed`, `:goal_completed`, `:goal_cleared`,
  `:goal_continuation_submitted`, `:goal_loop_verdict`, `:goal_loop_status`).
  """

  use LemonCore.Events.Payload,
    type: :goal_changed,
    enforce: [:goal_id],
    fields: [
      goal_id: nil,
      agent_id: nil,
      session_key: nil,
      status: nil,
      objective_bytes: nil,
      continuation_count: nil,
      last_run_id: nil,
      loop_verdict: nil,
      loop_status: nil,
      loop_auto_enabled: nil
    ]

  @type t :: %__MODULE__{
          goal_id: String.t(),
          agent_id: String.t() | nil,
          session_key: String.t() | nil,
          status: atom() | String.t() | nil,
          objective_bytes: non_neg_integer() | nil,
          continuation_count: non_neg_integer() | nil,
          last_run_id: String.t() | nil,
          loop_verdict: term() | nil,
          loop_status: term() | nil,
          loop_auto_enabled: boolean() | nil
        }
end
