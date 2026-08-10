defmodule LemonCore.Events.ConfigReloadFailed do
  @moduledoc """
  A configuration reload raised. Published on `system`.
  """

  use LemonCore.Events.Payload,
    type: :config_reload_failed,
    enforce: [:reload_id, :error],
    fields: [reload_id: nil, reason: nil, error: nil]

  @type t :: %__MODULE__{
          reload_id: String.t(),
          reason: atom() | String.t() | nil,
          error: String.t()
        }
end
