defmodule Mix.Tasks.Lemon.Secrets.List do
  use Mix.Task

  alias LemonCore.Secrets

  @shortdoc "List stored secret metadata"
  @moduledoc """
  Lists stored secrets (metadata only, no plaintext values).

      mix lemon.secrets.list
  """

  @impl true
  def run(_args) do
    Mix.Tasks.Lemon.Secrets.ensure_started!()

    {:ok, entries} = Secrets.list()

    if entries == [] do
      Mix.shell().info("No secrets configured")
    else
      entries
      |> Enum.each(fn entry ->
        Mix.shell().info([
          entry.name,
          " provider=",
          entry.provider,
          " usage=",
          to_string(entry.usage_count),
          " expires_at=",
          format_optional(entry.expires_at)
        ])
      end)
    end
  end

  defp format_optional(nil), do: "never"
  defp format_optional(value), do: to_string(value)
end
