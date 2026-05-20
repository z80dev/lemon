defmodule LemonControlPlane.Methods.Health do
  @moduledoc """
  Health check method.

  Returns basic health information about the control plane server.
  This is a public method that does not require authentication.

  ## Response

      %{
        "ok" => true,
        "uptime_ms" => 12345,
        "memory_mb" => 256.5,
        "schedulers" => 8
      }
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "health"

  @impl true
  def scopes, do: []

  @impl true
  def handle(_params, _ctx) do
    uptime_ms = uptime_ms()
    memory_mb = memory_mb()
    schedulers = System.schedulers_online()

    {:ok,
     %{
       "ok" => true,
       "uptime_ms" => uptime_ms,
       "memory_mb" => memory_mb,
       "schedulers" => schedulers,
       "summary" => summary(uptime_ms, memory_mb, schedulers)
     }}
  end

  defp uptime_ms do
    {uptime, _} = :erlang.statistics(:wall_clock)
    uptime
  end

  defp memory_mb do
    bytes = :erlang.memory(:total)
    Float.round(bytes / 1_048_576, 2)
  end

  defp summary(uptime_ms, memory_mb, schedulers) do
    %{
      "action" => "health",
      "ok" => true,
      "uptimeMs" => uptime_ms,
      "memoryMb" => memory_mb,
      "schedulerCount" => schedulers,
      "cleanup" => %{
        "includesRawProcessState" => false,
        "includesCredentialValues" => false,
        "includesSecretValues" => false
      }
    }
  end
end
