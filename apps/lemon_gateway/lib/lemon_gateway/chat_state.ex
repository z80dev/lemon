defmodule LemonGateway.ChatState do
  @moduledoc """
  Represents the persistent state for a chat scope.

  Used for auto-resume functionality - tracks the last engine and resume token
  so subsequent messages can automatically continue the conversation.
  """

  defstruct [:last_engine, :last_resume_token, :updated_at]

  @type t :: %__MODULE__{
          last_engine: String.t() | nil,
          last_resume_token: String.t() | nil,
          updated_at: integer() | nil
        }

  @doc """
  Creates a new ChatState with default values (all nil).
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Creates a new ChatState with the given values.
  """
  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      last_engine: attrs[:last_engine] || attrs["last_engine"],
      last_resume_token: attrs[:last_resume_token] || attrs["last_resume_token"],
      updated_at: attrs[:updated_at] || attrs["updated_at"]
    }
  end
end
