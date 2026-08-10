defmodule LemonChannels.Adapters.Discord.ModelPicker do
  @moduledoc """
  Builds the Discord message components (select menus + nav buttons) for the
  `/model` picker and parses the component callbacks they produce.

  Pure view/parse layer over `StatusRenderer` and `ModelCatalog`; holds no
  transport state. Extracted from `LemonChannels.Adapters.Discord.Transport`.
  """

  alias LemonChannels.Adapters.Discord.{ModelCatalog, StatusRenderer}

  @providers_per_page 8
  @models_per_page 8
  @model_callback_prefix "lemon:model"

  def model_provider_components(providers, page) when is_list(providers) do
    {slice, has_prev, has_next} = paginate(providers, page, @providers_per_page)

    options =
      Enum.map(slice, fn provider ->
        StatusRenderer.select_option(provider, provider)
      end)

    nav_buttons =
      []
      |> maybe_append(
        has_prev,
        StatusRenderer.button("Prev", "#{@model_callback_prefix}:providers:#{max(page - 1, 0)}")
      )
      |> maybe_append(
        has_next,
        StatusRenderer.button("Next", "#{@model_callback_prefix}:providers:#{page + 1}")
      )
      |> maybe_append(
        true,
        StatusRenderer.button("Close", "#{@model_callback_prefix}:close", style: :danger)
      )

    components = [
      StatusRenderer.action_row([
        StatusRenderer.select_menu("#{@model_callback_prefix}:select_provider", options,
          placeholder: "Choose a provider"
        )
      ])
    ]

    if nav_buttons != [] do
      components ++ [StatusRenderer.action_row(nav_buttons)]
    else
      components
    end
  end

  def model_list_components(provider, models, page) when is_list(models) do
    indexed = Enum.with_index(models)
    {slice, has_prev, has_next} = paginate(indexed, page, @models_per_page)

    options =
      Enum.map(slice, fn {model, idx} ->
        StatusRenderer.select_option(ModelCatalog.model_label(model), "#{provider}:#{idx}")
      end)

    nav_buttons =
      []
      |> maybe_append(
        has_prev,
        StatusRenderer.button(
          "Prev",
          "#{@model_callback_prefix}:provider:#{provider}:#{max(page - 1, 0)}"
        )
      )
      |> maybe_append(
        has_next,
        StatusRenderer.button(
          "Next",
          "#{@model_callback_prefix}:provider:#{provider}:#{page + 1}"
        )
      )
      |> maybe_append(
        true,
        StatusRenderer.button("Back", "#{@model_callback_prefix}:providers:0")
      )
      |> maybe_append(
        true,
        StatusRenderer.button("Close", "#{@model_callback_prefix}:close", style: :danger)
      )

    [
      StatusRenderer.action_row([
        StatusRenderer.select_menu(
          "#{@model_callback_prefix}:select_model:#{provider}:#{page}",
          options,
          placeholder: "Choose a model"
        )
      ]),
      StatusRenderer.action_row(nav_buttons)
    ]
  end

  def model_scope_components(provider, index) do
    [
      StatusRenderer.action_row([
        StatusRenderer.button(
          "This session",
          "#{@model_callback_prefix}:set:s:#{provider}:#{index}",
          style: :primary
        ),
        StatusRenderer.button(
          "All future sessions",
          "#{@model_callback_prefix}:set:f:#{provider}:#{index}",
          style: :success
        ),
        StatusRenderer.button("Back", "#{@model_callback_prefix}:provider:#{provider}:0"),
        StatusRenderer.button("Close", "#{@model_callback_prefix}:close", style: :danger)
      ])
    ]
  end

  def parse_model_callback(custom_id, values) when is_binary(custom_id) do
    cond do
      # Select menu: provider selection
      String.starts_with?(custom_id, "#{@model_callback_prefix}:select_provider") and values != [] ->
        {:select_provider, List.first(values)}

      # Select menu: model selection
      String.starts_with?(custom_id, "#{@model_callback_prefix}:select_model:") and values != [] ->
        selected = List.first(values)

        case String.split(selected, ":", parts: 2) do
          [provider, idx_str] ->
            case Integer.parse(idx_str) do
              {idx, _} -> {:choose, provider, idx}
              _ -> nil
            end

          _ ->
            nil
        end

      # Button callbacks
      true ->
        prefix = @model_callback_prefix <> ":"

        if String.starts_with?(custom_id, prefix) do
          rest = String.replace_prefix(custom_id, prefix, "")
          parse_model_button_callback(rest)
        else
          nil
        end
    end
  end

  def parse_model_callback(_, _), do: nil

  defp parse_model_button_callback(rest) do
    case String.split(rest, ":") do
      ["providers", page] -> {:providers, max(parse_int(page) || 0, 0)}
      ["provider", provider, page] -> {:provider, provider, max(parse_int(page) || 0, 0)}
      ["choose", provider, index, _page] -> {:choose, provider, parse_int(index)}
      ["set", "s", provider, index] -> {:set, :session, provider, parse_int(index)}
      ["set", "f", provider, index] -> {:set, :future, provider, parse_int(index)}
      ["close"] -> :close
      _ -> nil
    end
  end

  defp paginate(list, page, per_page)
       when is_list(list) and is_integer(page) and is_integer(per_page) do
    p = if page < 0, do: 0, else: page
    start_index = p * per_page
    total = length(list)
    slice = list |> Enum.drop(start_index) |> Enum.take(per_page)
    {slice, p > 0, start_index + per_page < total}
  end

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, _} -> id
      :error -> nil
    end
  end

  defp parse_int(_), do: nil

  defp maybe_append(list, true, item), do: list ++ [item]
  defp maybe_append(list, false, _item), do: list
end
