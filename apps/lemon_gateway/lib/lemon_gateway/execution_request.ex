defmodule LemonGateway.ExecutionRequest do
  @moduledoc """
  Queue-semantic-free public execution contract for gateway submission.

  Router-owned callers hand `%ExecutionRequest{}` values across the
  router->gateway boundary. Gateway internals still convert these requests into
  `%LemonGateway.Types.Job{}` before invoking engines.
  """

  alias LemonGateway.Types.Job

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
          lane: LemonGateway.Types.lane() | nil,
          tool_policy: map() | nil,
          conversation_key: conversation_key() | nil,
          meta: map()
        }

  @doc """
  Compatibility/migration helper; new code should build `%ExecutionRequest{}`
  values directly.
  """
  @spec from_job(Job.t(), keyword()) :: t()
  def from_job(%Job{} = job, opts \\ []) do
    %__MODULE__{
      run_id: job.run_id,
      session_key: job.session_key,
      prompt: job.prompt,
      engine_id: job.engine_id,
      cwd: job.cwd,
      resume: job.resume,
      lane: job.lane,
      tool_policy: job.tool_policy,
      conversation_key: Keyword.get(opts, :conversation_key),
      meta: normalize_meta(job.meta)
    }
  end

  @doc """
  Converts the public execution contract into the internal engine-facing job
  shape used inside gateway run execution.
  """
  @spec to_job(t()) :: Job.t()
  def to_job(%__MODULE__{} = request) do
    %Job{
      run_id: request.run_id,
      session_key: request.session_key,
      prompt: request.prompt,
      engine_id: request.engine_id,
      cwd: request.cwd,
      resume: request.resume,
      lane: request.lane,
      tool_policy: request.tool_policy,
      meta: normalize_meta(request.meta)
    }
  end

  @spec ensure_conversation_key(t()) :: t()
  def ensure_conversation_key(%__MODULE__{conversation_key: conversation_key} = request)
      when not is_nil(conversation_key) do
    request
  end

  def ensure_conversation_key(%__MODULE__{run_id: run_id}) do
    raise ArgumentError,
          "execution request #{inspect(run_id)} is missing router-owned conversation_key"
  end

  defp normalize_meta(meta) when is_map(meta), do: meta
  defp normalize_meta(_), do: %{}
end
