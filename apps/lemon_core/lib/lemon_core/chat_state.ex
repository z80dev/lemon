defmodule LemonCore.ChatState do
  @moduledoc """
  Persistent sticky execution state for a chat scope.

  Tracks the last engine and resume token so router and channel code can resume
  a conversation without depending on the gateway runtime.
  """

  defstruct [:last_engine, :last_resume_token, :updated_at, :expires_at]

  @type t :: %__MODULE__{
          last_engine: String.t() | nil,
          last_resume_token: String.t() | nil,
          updated_at: integer() | nil,
          expires_at: integer() | nil
        }

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      last_engine: attrs[:last_engine] || attrs["last_engine"],
      last_resume_token: attrs[:last_resume_token] || attrs["last_resume_token"],
      updated_at: attrs[:updated_at] || attrs["updated_at"],
      expires_at: attrs[:expires_at] || attrs["expires_at"]
    }
  end
end
