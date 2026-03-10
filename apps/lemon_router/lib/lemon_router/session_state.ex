defmodule LemonRouter.SessionState do
  @moduledoc """
  Pure state container for router-owned per-conversation queue semantics.
  """

  alias LemonGateway.ExecutionRequest

  @type active_run :: %{
          required(:run_id) => binary(),
          required(:session_key) => binary(),
          optional(:pid) => pid() | nil,
          optional(:mon_ref) => reference() | nil,
          optional(:submission) => map()
        }

  @type queued_submission :: %{
          required(:run_id) => binary(),
          required(:session_key) => binary(),
          required(:queue_mode) => atom(),
          required(:execution_request) => ExecutionRequest.t(),
          optional(:run_supervisor) => module() | pid() | atom(),
          optional(:run_process_module) => module(),
          optional(:run_process_opts) => map(),
          optional(:meta) => map()
        }

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
