defmodule LemonSimUi.VendingBenchLauncher do
  @moduledoc false

  require Logger

  alias LemonSimUi.SimManager

  @default_presets [
    %{
      id: "zai_glm_5_1",
      label: "GLM 5.1",
      model: "zai:glm-5.1",
      worker_model: "zai:glm-5.1",
      max_days: 30,
      max_turns: 300
    },
    %{
      id: "codex_gpt_5_5",
      label: "GPT 5.5",
      model: "openai-codex:gpt-5.5",
      worker_model: "openai-codex:gpt-5.5",
      max_days: 30,
      max_turns: 300
    }
  ]

  def presets do
    :lemon_sim_ui
    |> Application.get_env(:vending_launcher_presets, @default_presets)
    |> validate_presets()
  end

  def enabled? do
    Application.get_env(:lemon_sim_ui, :public_vending_launcher, false) == true
  end

  def start(preset_id) do
    if enabled?() do
      preset = preset(preset_id)

      case preset do
        nil ->
          {:error, :no_vending_launcher_presets}

        preset ->
          sim_id =
            "vb_#{sim_slug(preset.id)}_#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")}"

          SimManager.start_sim(:vending_bench,
            sim_id: sim_id,
            max_days: preset.max_days,
            driver_max_turns: preset.max_turns,
            operator_model_spec: preset.model,
            physical_worker_model_spec: preset.worker_model
          )
      end
    else
      {:error, :public_vending_launcher_disabled}
    end
  end

  defp preset(id) do
    resolved = presets()
    Enum.find(resolved, &(&1.id == id)) || List.first(resolved)
  end

  defp validate_presets(presets) when is_list(presets) do
    Enum.flat_map(presets, fn entry ->
      case validate_preset(entry) do
        {:ok, preset} ->
          [preset]

        {:error, reason} ->
          Logger.warning("Skipping malformed VendingBench launcher preset: #{inspect(reason)}")
          []
      end
    end)
  end

  defp validate_presets(other) do
    Logger.warning("Skipping malformed VendingBench launcher presets: #{inspect(other)}")
    []
  end

  defp validate_preset(entry) when is_map(entry) do
    preset = %{
      id: get_key(entry, :id),
      label: get_key(entry, :label),
      model: get_key(entry, :model),
      worker_model: get_key(entry, :worker_model),
      max_days: get_key(entry, :max_days),
      max_turns: get_key(entry, :max_turns)
    }

    cond do
      not valid_id?(preset.id) ->
        {:error, {:invalid_id, entry}}

      not present_string?(preset.label) ->
        {:error, {:invalid_label, entry}}

      not present_string?(preset.model) ->
        {:error, {:invalid_model, entry}}

      not present_string?(preset.worker_model) ->
        {:error, {:invalid_worker_model, entry}}

      not positive_integer?(preset.max_days) ->
        {:error, {:invalid_max_days, entry}}

      not positive_integer?(preset.max_turns) ->
        {:error, {:invalid_max_turns, entry}}

      true ->
        {:ok, preset}
    end
  end

  defp validate_preset(entry), do: {:error, {:invalid_entry, entry}}

  defp get_key(map, key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp valid_id?(value) when is_binary(value) do
    String.match?(value, ~r/^[A-Za-z0-9][A-Za-z0-9_-]*$/)
  end

  defp valid_id?(_value), do: false

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp sim_slug(id) do
    id
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end
end
