defmodule LemonRouter.QueueEffect do
  @moduledoc """
  Tiny typed effect surface for reducer-produced queue commands.

  `LemonRouter.SessionTransitions` returns these effects after pure state
  transitions. `LemonRouter.SessionCoordinator` interprets them. Queue policy
  stays in the reducer rather than in the interpreter.
  """

  alias LemonRouter.Submission

  @type fallback_mode :: :followup | :collect
  @type steer_mode :: :steer | :steer_backlog

  @type t ::
          :maybe_start_next
          | {:cancel_active, term()}
          | {:dispatch_steer, binary(), steer_mode(), Submission.t(), fallback_mode()}
          | :noop
end
