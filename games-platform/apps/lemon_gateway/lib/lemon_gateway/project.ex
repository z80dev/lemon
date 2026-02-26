defmodule LemonGateway.Project do
  @moduledoc """
  Represents a project configuration.

  Projects define a root directory for running agents and can specify
  a default engine to use for jobs bound to this project.
  """

  @enforce_keys [:id, :root]
  defstruct [:id, :root, :default_engine]

  @type t :: %__MODULE__{
          id: String.t(),
          root: String.t(),
          default_engine: String.t() | nil
        }
end
