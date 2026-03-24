defmodule Ai.Providers.AssistantMessageHelper do
  @moduledoc """
  Shared helper for building the initial %AssistantMessage{} used by all streaming providers.
  """

  alias Ai.Types.{AssistantMessage, Cost, Usage}

  @doc """
  Build a zeroed-out AssistantMessage for the start of a streaming response.

  By default, `api` is taken from `model.api`. Pass `api_override` to hardcode
  a provider-specific API atom instead.

  Similarly, `provider` is taken from `model.provider`. Pass `provider_override`
  to supply a fallback (e.g. `model.provider || :amazon`).
  """
  def init_assistant_message(model, opts \\ []) do
    %AssistantMessage{
      role: :assistant,
      content: [],
      api: Keyword.get(opts, :api_override, model.api),
      provider: Keyword.get(opts, :provider_override, model.provider),
      model: model.id,
      usage: %Usage{cost: %Cost{}},
      stop_reason: :stop,
      timestamp: System.system_time(:millisecond)
    }
  end
end
