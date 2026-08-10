defmodule LemonCore.Events.ConfigReloaded do
  @moduledoc """
  Configuration was reloaded successfully. Published on `system`.
  """

  use LemonCore.Events.Payload,
    type: :config_reloaded,
    enforce: [:reload_id],
    fields: [reload_id: nil, reason: nil, changed_sources: [], changed_paths: [], diff: nil]

  @type t :: %__MODULE__{
          reload_id: String.t(),
          reason: atom() | String.t() | nil,
          changed_sources: [atom() | String.t()],
          changed_paths: [String.t()],
          diff: map() | nil
        }
end
