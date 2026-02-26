defmodule LemonChannels.Capabilities do
  @moduledoc """
  Channel capability definitions.

  Defines the capabilities that channels can advertise.
  """

  @type t :: %{
          edit_support: boolean(),
          delete_support: boolean(),
          chunk_limit: non_neg_integer(),
          rate_limit: non_neg_integer() | nil,
          voice_support: boolean(),
          image_support: boolean(),
          file_support: boolean(),
          reaction_support: boolean(),
          thread_support: boolean()
        }

  @doc """
  Default capabilities for a channel.
  """
  @spec defaults() :: t()
  def defaults do
    %{
      edit_support: false,
      delete_support: false,
      chunk_limit: 4096,
      rate_limit: nil,
      voice_support: false,
      image_support: false,
      file_support: false,
      reaction_support: false,
      thread_support: false
    }
  end

  @doc """
  Merge capabilities with defaults.
  """
  @spec with_defaults(map()) :: t()
  def with_defaults(caps) do
    Map.merge(defaults(), caps)
  end

  @doc """
  Check if a channel supports a capability.
  """
  @spec supports?(t(), atom()) :: boolean()
  def supports?(caps, capability) do
    Map.get(caps, capability, false) == true
  end
end
