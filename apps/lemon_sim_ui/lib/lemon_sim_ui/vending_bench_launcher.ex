defmodule LemonSimUi.VendingBenchLauncher do
  @moduledoc false

  alias LemonSimUi.SimManager

  @presets [
    %{
      id: "zai_glm_5_1",
      label: "GLM 5.1",
      detail: "Z.AI credentials",
      spec: "zai:glm-5.1",
      sim_slug: "glm51"
    },
    %{
      id: "codex_gpt_5_5",
      label: "GPT 5.5",
      detail: "Codex OAuth",
      spec: "openai-codex:gpt-5.5",
      sim_slug: "gpt55"
    }
  ]

  def presets, do: @presets

  def enabled? do
    Application.get_env(:lemon_sim_ui, :public_vending_launcher, false) == true
  end

  def start(preset_id) do
    if enabled?() do
      preset = preset(preset_id)
      spec = preset.spec
      sim_id = "vb_#{preset.sim_slug}_#{Calendar.strftime(DateTime.utc_now(), "%Y%m%d_%H%M%S")}"

      SimManager.start_sim(:vending_bench,
        sim_id: sim_id,
        max_days: 30,
        driver_max_turns: 300,
        operator_model_spec: spec,
        physical_worker_model_spec: spec
      )
    else
      {:error, :public_vending_launcher_disabled}
    end
  end

  defp preset(id) do
    Enum.find(@presets, &(&1.id == id)) || List.first(@presets)
  end
end
