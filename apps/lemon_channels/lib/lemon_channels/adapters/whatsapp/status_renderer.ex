defmodule LemonChannels.Adapters.WhatsApp.StatusRenderer do
  @moduledoc false

  @doc "WhatsApp has no inline keyboards in Phase 1; always returns nil."
  @spec reply_markup(LemonCore.DeliveryIntent.t()) :: nil
  def reply_markup(_intent), do: nil
end
