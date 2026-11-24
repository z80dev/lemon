defmodule LemonRouter.Submission do
  @moduledoc """
  Router-owned internal queue contract between orchestration and coordination.

  `LemonCore.RunRequest` remains the permissive router-facing boundary and
  `LemonCore.ExecutionCommand` is the runtime-facing execution contract.
  This struct owns the normalized router handoff in between, including the
  pending-compaction marker that may be consumed after coordinator acceptance.
  `request` keeps the original `RunRequest` so a drain can carry queued and
  interrupted work across a restart (`LemonRouter.RestartCarryover`).
  """

  alias LemonCore.{ExecutionCommand, MapHelpers, RunPhase, RunRequest}

  @enforce_keys [:run_id, :session_key, :conversation_key, :queue_mode, :execution_request]
  defstruct [
    :run_id,
    :session_key,
    :conversation_key,
    queue_mode: :collect,
    execution_request: nil,
    run_supervisor: LemonRouter.RunSupervisor,
    run_process_module: LemonRouter.RunProcess,
    run_process_opts: %{},
    pending_compaction_marker: nil,
    meta: %{},
    current_phase: nil,
    request: nil
  ]

  @type t :: %__MODULE__{
          run_id: binary(),
          session_key: binary(),
          conversation_key: ExecutionCommand.conversation_key(),
          queue_mode: atom() | term(),
          execution_request: ExecutionCommand.t(),
          run_supervisor: module() | pid() | atom(),
          run_process_module: module(),
          run_process_opts: map(),
          pending_compaction_marker: map() | nil,
          meta: map(),
          current_phase: RunPhase.t() | nil,
          request: RunRequest.t() | nil
        }

  @doc """
  Build a submission, or `{:error, :invalid_submission}` when it lacks an
  execution request, a non-empty run ID or session key, a conversation key, or
  carries an invalid phase. Admission uses this so bad input is a definite
  rejection rather than an exception.
  """
  @spec new(t() | map() | keyword()) :: {:ok, t()} | {:error, :invalid_submission}
  def new(%__MODULE__{} = submission), do: submission |> Map.from_struct() |> new()

  def new(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs),
      do: attrs |> Map.new() |> new(),
      else: {:error, :invalid_submission}
  end

  def new(attrs) when is_map(attrs) do
    with %ExecutionCommand{} = execution_request <-
           MapHelpers.get_key(attrs, :execution_request),
         run_id when is_binary(run_id) and run_id != "" <-
           MapHelpers.get_key(attrs, :run_id) || execution_request.run_id,
         session_key when is_binary(session_key) and session_key != "" <-
           MapHelpers.get_key(attrs, :session_key) || execution_request.session_key,
         conversation_key when not is_nil(conversation_key) <-
           MapHelpers.get_key(attrs, :conversation_key) || execution_request.conversation_key,
         {:ok, current_phase} <- current_phase(MapHelpers.get_key(attrs, :current_phase)) do
      {:ok,
       %__MODULE__{
         run_id: run_id,
         session_key: session_key,
         conversation_key: conversation_key,
         queue_mode: MapHelpers.get_key(attrs, :queue_mode) || :collect,
         execution_request: execution_request,
         run_supervisor: MapHelpers.get_key(attrs, :run_supervisor) || LemonRouter.RunSupervisor,
         run_process_module:
           MapHelpers.get_key(attrs, :run_process_module) || LemonRouter.RunProcess,
         run_process_opts:
           normalize_run_process_opts(MapHelpers.get_key(attrs, :run_process_opts)),
         pending_compaction_marker: MapHelpers.get_key(attrs, :pending_compaction_marker),
         meta: normalize_meta(MapHelpers.get_key(attrs, :meta)),
         current_phase: current_phase,
         request: normalize_request(MapHelpers.get_key(attrs, :request))
       }}
    else
      _ -> {:error, :invalid_submission}
    end
  end

  def new(_attrs), do: {:error, :invalid_submission}

  @doc "Like `new/1`, for already-admitted submissions: invalid input is a bug and raises."
  @spec new!(t() | map() | keyword()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, submission} -> submission
      {:error, :invalid_submission} -> raise ArgumentError, "invalid submission"
    end
  end

  @spec put_phase(t(), RunPhase.t()) :: t()
  def put_phase(%__MODULE__{} = submission, phase) do
    if RunPhase.valid?(phase) do
      %{submission | current_phase: phase}
    else
      raise ArgumentError, "invalid run phase: #{inspect(phase)}"
    end
  end

  defp normalize_run_process_opts(opts) when is_map(opts), do: opts
  defp normalize_run_process_opts(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_run_process_opts(_), do: %{}

  defp normalize_meta(meta) when is_map(meta), do: meta
  defp normalize_meta(_), do: %{}

  defp normalize_request(%RunRequest{} = request), do: request
  defp normalize_request(_), do: nil

  defp current_phase(nil), do: {:ok, nil}

  defp current_phase(phase) do
    if RunPhase.valid?(phase), do: {:ok, phase}, else: {:error, :invalid_phase}
  end
end
