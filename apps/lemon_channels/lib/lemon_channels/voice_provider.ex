defmodule LemonChannels.VoiceProvider do
  @moduledoc """
  Channel speech synthesis boundary. Providers return audio bytes and optional
  actual response usage; absent response pricing must never be estimated.
  """

  @callback synthesize(binary(), map(), map()) ::
              {:ok, map()} | {:error, term()}
end
