defmodule LemonChannels.Adapters.Telegram.StatusRenderer do
  @moduledoc false

  @cancel_callback_prefix "lemon:cancel"
  @idle_keepalive_continue_callback_prefix "lemon:idle:c:"
  @idle_keepalive_stop_callback_prefix "lemon:idle:k:"

  @spec reply_markup(LemonCore.DeliveryIntent.t()) :: map() | nil
  def reply_markup(%LemonCore.DeliveryIntent{kind: :tool_status_finalize}),
    do: %{"inline_keyboard" => []}

  def reply_markup(%LemonCore.DeliveryIntent{kind: :tool_status_snapshot, run_id: run_id, controls: controls})
      when is_binary(run_id) and run_id != "" do
    if allow_cancel?(controls) do
      %{
        "inline_keyboard" => [
          [
            %{
              "text" => "cancel",
              "callback_data" => @cancel_callback_prefix <> ":" <> run_id
            }
          ]
        ]
      }
    else
      nil
    end
  end

  def reply_markup(%LemonCore.DeliveryIntent{kind: :watchdog_prompt, run_id: run_id})
      when is_binary(run_id) and run_id != "" do
    %{
      "inline_keyboard" => [
        [
          %{
            "text" => "Keep Waiting",
            "callback_data" => @idle_keepalive_continue_callback_prefix <> run_id
          },
          %{
            "text" => "Stop Run",
            "callback_data" => @idle_keepalive_stop_callback_prefix <> run_id
          }
        ]
      ]
    }
  end

  def reply_markup(_intent), do: nil

  defp allow_cancel?(controls) when is_map(controls) do
    controls[:allow_cancel?] == true or controls["allow_cancel?"] == true
  end

  defp allow_cancel?(_), do: false
end
