defmodule LemonChannels.Adapters.Discord.StatusRenderer do
  @moduledoc """
  Renders Discord message components for run status messages.

  Generates action rows with buttons for cancel, keep-waiting, and stop
  controls on progress/status messages.
  """

  @cancel_callback_prefix "lemon:cancel"
  @idle_keepalive_continue_callback_prefix "lemon:idle:c:"
  @idle_keepalive_stop_callback_prefix "lemon:idle:k:"

  @spec components(LemonCore.DeliveryIntent.t()) :: list() | nil
  def components(%LemonCore.DeliveryIntent{kind: :tool_status_finalize}),
    do: []

  def components(%LemonCore.DeliveryIntent{
        kind: :tool_status_snapshot,
        run_id: run_id,
        controls: controls
      })
      when is_binary(run_id) and run_id != "" do
    if allow_cancel?(controls) do
      [
        action_row([
          button("Cancel", @cancel_callback_prefix <> ":" <> run_id, style: :danger)
        ])
      ]
    else
      nil
    end
  end

  def components(%LemonCore.DeliveryIntent{kind: :watchdog_prompt, run_id: run_id})
      when is_binary(run_id) and run_id != "" do
    [
      action_row([
        button("Keep Waiting", @idle_keepalive_continue_callback_prefix <> run_id,
          style: :primary
        ),
        button("Stop Run", @idle_keepalive_stop_callback_prefix <> run_id, style: :danger)
      ])
    ]
  end

  def components(_intent), do: nil

  # ============================================================================
  # Discord Component Builders
  # ============================================================================

  @doc "Build an action row containing components."
  def action_row(components) when is_list(components) do
    %{type: 1, components: components}
  end

  @doc "Build a button component."
  def button(label, custom_id, opts \\ []) do
    style =
      case Keyword.get(opts, :style, :secondary) do
        :primary -> 1
        :secondary -> 2
        :success -> 3
        :danger -> 4
        :link -> 5
        n when is_integer(n) -> n
        _ -> 2
      end

    btn = %{type: 2, style: style, label: label, custom_id: custom_id}

    if Keyword.has_key?(opts, :disabled) do
      Map.put(btn, :disabled, Keyword.get(opts, :disabled))
    else
      btn
    end
  end

  @doc "Build a string select menu component."
  def select_menu(custom_id, options, opts \\ []) do
    menu = %{
      type: 3,
      custom_id: custom_id,
      options: options
    }

    menu =
      if Keyword.has_key?(opts, :placeholder),
        do: Map.put(menu, :placeholder, Keyword.get(opts, :placeholder)),
        else: menu

    menu =
      if Keyword.has_key?(opts, :min_values),
        do: Map.put(menu, :min_values, Keyword.get(opts, :min_values)),
        else: menu

    menu =
      if Keyword.has_key?(opts, :max_values),
        do: Map.put(menu, :max_values, Keyword.get(opts, :max_values)),
        else: menu

    menu
  end

  @doc "Build a select menu option."
  def select_option(label, value, opts \\ []) do
    opt = %{label: label, value: value}

    opt =
      if Keyword.has_key?(opts, :description),
        do: Map.put(opt, :description, Keyword.get(opts, :description)),
        else: opt

    opt =
      if Keyword.has_key?(opts, :default),
        do: Map.put(opt, :default, Keyword.get(opts, :default)),
        else: opt

    opt
  end

  defp allow_cancel?(controls) when is_map(controls) do
    controls[:allow_cancel?] == true or controls["allow_cancel?"] == true
  end

  defp allow_cancel?(_), do: false
end
