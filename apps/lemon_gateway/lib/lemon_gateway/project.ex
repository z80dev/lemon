defmodule LemonGateway.Project do
  @moduledoc """
  Represents a project configuration.
  Projects define a root directory for running agents.
  """

  @enforce_keys [:id, :root]
  defstruct [:id, :root]

  @type t :: %__MODULE__{
          id: String.t(),
          root: String.t()
        }
end
