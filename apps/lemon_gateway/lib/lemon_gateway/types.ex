defmodule LemonGateway.Types do
  @moduledoc false

  @type engine_id :: String.t()

  defmodule ResumeToken do
    @moduledoc false
    @enforce_keys [:engine, :value]
    defstruct [:engine, :value]

    @type t :: %__MODULE__{engine: LemonGateway.Types.engine_id(), value: String.t()}
  end

  defmodule ChatScope do
    @moduledoc false
    @enforce_keys [:transport, :chat_id]
    defstruct [:transport, :chat_id, :topic_id]

    @type t :: %__MODULE__{transport: atom(), chat_id: integer(), topic_id: integer() | nil}
  end

  defmodule Job do
    @moduledoc false
    @enforce_keys [:scope, :user_msg_id, :text]
    defstruct [:scope, :user_msg_id, :text, :resume, :engine_hint, :meta]

    @type t :: %__MODULE__{
            scope: ChatScope.t(),
            user_msg_id: integer(),
            text: String.t(),
            resume: LemonGateway.Types.ResumeToken.t() | nil,
            engine_hint: LemonGateway.Types.engine_id() | nil,
            meta: map() | nil
          }
  end
end
