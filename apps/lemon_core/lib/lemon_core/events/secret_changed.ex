defmodule LemonCore.Events.SecretChanged do
  @moduledoc """
  A stored secret was added, updated or removed. Published on `system`.

  Carries the secret's owner and name only — never its value.
  """

  use LemonCore.Events.Payload,
    type: :secret_changed,
    enforce: [:owner, :name, :action],
    fields: [owner: nil, name: nil, action: nil]

  @type t :: %__MODULE__{
          owner: String.t(),
          name: String.t(),
          action: atom()
        }
end
