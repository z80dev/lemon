defmodule LemonCore.Config.Memory do
  @moduledoc """
  Memory behaviour settings, from the `[memory]` TOML section.

      [memory]
      auto_recall = true   # default; false stops the per-turn "Relevant memory" block

  `auto_recall` controls whether each main-session turn gets a short, bounded
  block of this agent's earlier conversations that share keywords with the new
  message (`LemonMemory.Recall`, contributed by `LemonSkills.MemoryRecall`). The
  `recall` tool works either way. Durable memory as a whole is still switched by
  `[features] session_search`; with that off there is nothing to recall.
  """

  defstruct auto_recall: true, write_approval: false

  @type t :: %__MODULE__{auto_recall: boolean(), write_approval: boolean()}

  @doc """
  Resolves the `[memory]` section. A missing section or key takes the default;
  a present value is kept as written so `LemonCore.Config.Validator` can reject
  a non-boolean.
  """
  @spec resolve(map()) :: t()
  def resolve(settings) when is_map(settings) do
    case settings["memory"] do
      %{} = memory ->
        %__MODULE__{
          auto_recall: Map.get(memory, "auto_recall", true),
          write_approval: Map.get(memory, "write_approval", false)
        }

      _ ->
        %__MODULE__{}
    end
  end

  @doc "Whether automatic recall is on; anything but an explicit `false` is on."
  @spec auto_recall?(t() | map() | nil) :: boolean()
  def auto_recall?(%{auto_recall: false}), do: false
  def auto_recall?(_memory), do: true
end
