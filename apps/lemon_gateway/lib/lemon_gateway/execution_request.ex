defmodule LemonGateway.ExecutionRequest do
  @moduledoc """
  Gateway-private execution request.

  Router-owned callers hand `%LemonCore.ExecutionCommand{}` values to the
  configured `LemonCore.EngineRuntime`. Gateway passes this request directly to
  its configured native executor.
  """

  alias LemonCore.ExecutionCommand

  @enforce_keys [:run_id, :session_key, :prompt]
  defstruct [
    :run_id,
    :session_key,
    :prompt,
    :cwd,
    :resume,
    :lane,
    :tool_policy,
    :conversation_key,
    images: [],
    meta: %{}
  ]

  @type conversation_key :: {:resume, binary(), binary()} | {:session, binary()} | term()

  @type t :: %__MODULE__{
          run_id: String.t() | nil,
          session_key: String.t() | nil,
          prompt: String.t() | nil,
          images: [map()],
          cwd: String.t() | nil,
          resume: LemonCore.ResumeToken.t() | nil,
          lane: LemonGateway.Types.lane() | nil,
          tool_policy: map() | nil,
          conversation_key: conversation_key() | nil,
          meta: map()
        }

  @doc """
  Converts the core execution command into gateway's private scheduling shape.
  """
  @spec from_command(ExecutionCommand.t()) :: t()
  def from_command(%ExecutionCommand{} = command) do
    %__MODULE__{
      run_id: command.run_id,
      session_key: command.session_key,
      prompt: command.prompt,
      images: command.images || [],
      cwd: command.cwd,
      resume: command.resume,
      lane: command.lane,
      tool_policy: command.tool_policy,
      conversation_key: command.conversation_key,
      meta: ExecutionCommand.normalize_meta(command.meta)
    }
  end

  @doc """
  Converts the gateway-private request back into the core boundary contract.
  """
  @spec to_command(t()) :: ExecutionCommand.t()
  def to_command(%__MODULE__{} = request) do
    %ExecutionCommand{
      run_id: request.run_id,
      session_key: request.session_key,
      prompt: request.prompt,
      images: request.images || [],
      cwd: request.cwd,
      resume: request.resume,
      lane: request.lane,
      tool_policy: request.tool_policy,
      conversation_key: request.conversation_key,
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
