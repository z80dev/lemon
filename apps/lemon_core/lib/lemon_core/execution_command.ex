defmodule LemonCore.ExecutionCommand do
  @moduledoc """
  Queue-semantic-free execution command shared across router/runtime boundaries.

  Router-owned callers build this core contract after resolving conversation,
  engine, model, cwd, resume, and metadata. Runtime implementations translate it
  into their private execution shape before scheduling work.
  """

  @enforce_keys [:run_id, :session_key, :prompt, :engine_id]
  defstruct [
    :run_id,
    :session_key,
    :prompt,
    :engine_id,
    :cwd,
    :resume,
    :lane,
    :tool_policy,
    :conversation_key,
    meta: %{}
  ]

  @type conversation_key :: {:resume, binary(), binary()} | {:session, binary()} | term()

  @type t :: %__MODULE__{
          run_id: String.t() | nil,
          session_key: String.t() | nil,
          prompt: String.t() | nil,
          engine_id: String.t() | nil,
          cwd: String.t() | nil,
          resume: LemonCore.ResumeToken.t() | nil,
          lane: atom() | nil,
          tool_policy: map() | nil,
          conversation_key: conversation_key() | nil,
          meta: map()
        }

  @spec ensure_conversation_key(t()) :: t()
  def ensure_conversation_key(%__MODULE__{conversation_key: conversation_key} = command)
      when not is_nil(conversation_key) do
    command
  end

  def ensure_conversation_key(%__MODULE__{run_id: run_id}) do
    raise ArgumentError,
          "execution command #{inspect(run_id)} is missing router-owned conversation_key"
  end

  @spec normalize_meta(term()) :: map()
  def normalize_meta(meta) when is_map(meta), do: meta
  def normalize_meta(_), do: %{}
end
