defmodule LemonGateway.Engines.Echo do
  @moduledoc false
  @behaviour LemonGateway.Engine

  alias LemonGateway.Types.{Job, ResumeToken}
  alias LemonGateway.Event

  @impl true
  def id, do: "echo"

  @impl true
  def format_resume(%ResumeToken{value: sid}), do: "echo resume #{sid}"

  @impl true
  def extract_resume(text) do
    case Regex.run(~r/echo\s+resume\s+([\w-]+)/i, text) do
      [_, value] -> %ResumeToken{engine: id(), value: value}
      _ -> nil
    end
  end

  @impl true
  def is_resume_line(line) do
    Regex.match?(~r/^\s*`?echo\s+resume\s+[\w-]+`?\s*$/i, line)
  end

  @impl true
  def supports_steer?, do: false

  @impl true
  def start_run(%Job{} = job, _opts, sink_pid) do
    run_ref = make_ref()
    resume = job.resume || %ResumeToken{engine: id(), value: unique_id()}

    {:ok, task_pid} =
      Task.start(fn ->
        send(sink_pid, {:engine_event, run_ref, %Event.Started{engine: id(), resume: resume}})
        answer = "Echo: #{job.text}"

        send(
          sink_pid,
          {:engine_event, run_ref,
           %Event.Completed{engine: id(), resume: resume, ok: true, answer: answer}}
        )
      end)

    {:ok, run_ref, %{task_pid: task_pid}}
  end

  @impl true
  def cancel(%{task_pid: pid}) when is_pid(pid) do
    Process.exit(pid, :kill)
    :ok
  end

  defp unique_id do
    Integer.to_string(System.unique_integer([:positive]))
  end
end
