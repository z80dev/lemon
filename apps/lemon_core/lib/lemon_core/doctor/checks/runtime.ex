defmodule LemonCore.Doctor.Checks.Runtime do
  @moduledoc "Checks Lemon runtime health: port availability and running apps."

  alias LemonCore.Doctor.Check
  alias LemonCore.Runtime.{Env, Health}

  @doc """
  Returns a list of Check results covering runtime readiness.
  """
  @spec run(keyword()) :: [Check.t()]
  def run(_opts \\ []) do
    env = Env.resolve()

    [
      check_control_port(env),
      check_lemon_root(env)
    ]
  end

  defp check_control_port(env) do
    port = env.control_port

    if Health.running?(port, timeout_ms: 500) do
      Check.pass(
        "runtime.control_port",
        "Control-plane is listening on port #{port}."
      )
    else
      Check.skip(
        "runtime.control_port",
        "Control-plane not running on port #{port} (expected when not started)."
      )
    end
  end

  defp check_lemon_root(env) do
    root = env.lemon_root

    cond do
      is_nil(root) ->
        Check.skip("runtime.lemon_root", "LEMON_PATH not set; root resolved from source layout.")

      File.dir?(root) ->
        Check.pass("runtime.lemon_root", "Lemon root directory exists: #{root}")

      true ->
        Check.warn(
          "runtime.lemon_root",
          "LEMON_PATH points to a non-existent directory: #{root}",
          "Fix LEMON_PATH or unset it to use the source-relative default."
        )
    end
  end
end
