defmodule LemonCore.Binding do
  @moduledoc """
  Struct representing a binding between a transport chat/topic and a project configuration.

  Maps a transport, chat, and optional topic to a project, agent, default engine,
  and queue mode used by binding resolvers for scope resolution.
  """

  defstruct [:transport, :chat_id, :topic_id, :project, :agent_id, :default_engine, :queue_mode]

  @type t :: %__MODULE__{
          transport: atom(),
          chat_id: integer() | nil,
          topic_id: integer() | nil,
          project: String.t() | nil,
          agent_id: String.t() | nil,
          default_engine: String.t() | nil,
          queue_mode: atom() | nil
        }
end
