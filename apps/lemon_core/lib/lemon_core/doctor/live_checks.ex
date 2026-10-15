defmodule LemonCore.Doctor.LiveChecks do
  @moduledoc "Runs opt-in diagnostic jobs concurrently under one overall deadline."

  alias LemonCore.Doctor.Check
  alias LemonCore.Redact

  @type job :: {String.t(), (-> Check.t())}

  @spec run([job()], keyword()) :: [Check.t()]
  def run(jobs, opts \\ []) do
    timeout = Keyword.get(opts, :live_overall_timeout_ms, 6_000)
    {:ok, supervisor} = Task.Supervisor.start_link()

    try do
      tasks =
        Enum.map(jobs, fn {name, fun} ->
          Task.Supervisor.async_nolink(supervisor, fn -> safely_run(name, fun) end)
        end)

      results = Task.yield_many(tasks, timeout)

      Enum.zip_with(jobs, results, fn {name, _}, {task, result} ->
        check =
          case result do
            {:ok, %Check{} = check} ->
              check

            {:exit, _} ->
              Check.fail(name, "Live check could not complete.")

            nil ->
              Task.shutdown(task, :brutal_kill)
              Check.fail(name, "Live check timed out.")
          end

        %{
          check
          | name: Redact.text(check.name),
            message: Redact.text(check.message),
            remediation: Redact.text(check.remediation)
        }
      end)
    after
      Supervisor.stop(supervisor)
    end
  end

  defp safely_run(name, fun) do
    fun.()
  rescue
    _ -> Check.fail(name, "Live check could not complete.")
  catch
    _, _ -> Check.fail(name, "Live check could not complete.")
  end
end
