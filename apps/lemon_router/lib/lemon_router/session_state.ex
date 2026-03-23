defmodule LemonRouter.SessionState do
  @moduledoc """
  Pure state container for router-owned per-conversation queue semantics.
  """

  alias LemonRouter.Submission

  @type active_run :: %{
          required(:run_id) => binary(),
          required(:session_key) => binary(),
          optional(:pid) => pid() | nil,
          optional(:mon_ref) => reference() | nil,
          optional(:submission) => Submission.t()
        }

  @type queued_submission :: Submission.t()

  @type pending_steer_entry :: {queued_submission(), atom()}

  @type t :: %__MODULE__{
          conversation_key: term(),
          active: active_run() | nil,
          queue: [queued_submission()],
          last_followup_at_ms: integer() | nil,
          pending_steers: %{optional(binary()) => [pending_steer_entry()]}
        }

  defstruct conversation_key: nil,
            active: nil,
            queue: [],
            last_followup_at_ms: nil,
            pending_steers: %{}

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      conversation_key: Keyword.fetch!(opts, :conversation_key)
    }
  end

  @spec idle?(t()) :: boolean()
  def idle?(%__MODULE__{active: nil}), do: true
  def idle?(_state), do: false

  @spec active?(t()) :: boolean()
  def active?(state), do: not idle?(state)
end
