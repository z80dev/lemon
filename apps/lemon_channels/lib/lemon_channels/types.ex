defmodule LemonChannels.Types do
  @moduledoc false

  @type engine_id :: String.t()

  defmodule ResumeToken do
    @moduledoc false
    @enforce_keys [:engine, :value]
    defstruct [:engine, :value]

    @type t :: %__MODULE__{engine: LemonChannels.Types.engine_id(), value: String.t()}
  end

  defmodule ChatScope do
    @moduledoc false

    @enforce_keys [:transport, :chat_id]
    defstruct [:transport, :chat_id, :topic_id]

    @type t :: %__MODULE__{transport: atom(), chat_id: integer(), topic_id: integer() | nil}
  end
end
