defmodule LemonRouter.Submission do
  @moduledoc """
  Router-owned internal queue contract between orchestration and coordination.

  `LemonCore.RunRequest` remains the permissive router-facing boundary and
  `LemonGateway.ExecutionRequest` remains the gateway-facing execution contract.
  This struct owns the normalized router handoff in between.
  """

  alias LemonCore.{MapHelpers, RunPhase}
  alias LemonGateway.ExecutionRequest

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
    meta: %{},
    current_phase: nil
  ]

  @type t :: %__MODULE__{
          run_id: binary(),
          session_key: binary(),
          conversation_key: ExecutionRequest.conversation_key(),
          queue_mode: atom() | term(),
          execution_request: ExecutionRequest.t(),
          run_supervisor: module() | pid() | atom(),
          run_process_module: module(),
          run_process_opts: map(),
          meta: map(),
          current_phase: RunPhase.t() | nil
        }

  @spec new!(t() | map() | keyword()) :: t()
  def new!(%__MODULE__{} = submission) do
    submission
    |> Map.from_struct()
    |> new!()
  end

  def new!(attrs) when is_list(attrs) do
    if Keyword.keyword?(attrs) do
      attrs |> Enum.into(%{}) |> new!()
    else
      raise ArgumentError, "submission attrs must be a keyword list"
    end
  end

  def new!(attrs) when is_map(attrs) do
    execution_request =
      case MapHelpers.get_key(attrs, :execution_request) do
        %ExecutionRequest{} = request -> request
        other -> raise ArgumentError, "submission missing execution_request: #{inspect(other)}"
      end

    run_id = MapHelpers.get_key(attrs, :run_id) || execution_request.run_id
    session_key = MapHelpers.get_key(attrs, :session_key) || execution_request.session_key

    conversation_key =
      MapHelpers.get_key(attrs, :conversation_key) || execution_request.conversation_key

    unless is_binary(run_id) and run_id != "" do
      raise ArgumentError, "submission missing run_id"
    end

    unless is_binary(session_key) and session_key != "" do
      raise ArgumentError, "submission missing session_key"
    end

    if is_nil(conversation_key) do
      raise ArgumentError, "submission missing conversation_key"
    end

    current_phase = normalize_current_phase(MapHelpers.get_key(attrs, :current_phase))

    %__MODULE__{
      run_id: run_id,
      session_key: session_key,
      conversation_key: conversation_key,
      queue_mode: MapHelpers.get_key(attrs, :queue_mode) || :collect,
      execution_request: execution_request,
      run_supervisor: MapHelpers.get_key(attrs, :run_supervisor) || LemonRouter.RunSupervisor,
      run_process_module:
        MapHelpers.get_key(attrs, :run_process_module) || LemonRouter.RunProcess,
      run_process_opts: normalize_run_process_opts(MapHelpers.get_key(attrs, :run_process_opts)),
      meta: normalize_meta(MapHelpers.get_key(attrs, :meta)),
      current_phase: current_phase
    }
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

  defp normalize_current_phase(nil), do: nil

  defp normalize_current_phase(phase) do
    if RunPhase.valid?(phase) do
      phase
    else
      raise ArgumentError, "invalid current_phase: #{inspect(phase)}"
    end
  end
end
