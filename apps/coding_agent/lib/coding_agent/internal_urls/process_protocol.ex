defmodule CodingAgent.InternalUrls.ProcessProtocol do
  @moduledoc "Session-scoped process URL operations using the background process tools."
  alias CodingAgent.ProcessManager
  alias CodingAgent.Tools.Bash.Service
  alias CodingAgent.Tools.{BashOutput, KillProcess, ProcessInput}
  alias LemonAgent.Types.AgentToolResult
  alias LemonAi.Types.TextContent

  def read("proc://", _signal, cwd, opts) do
    if is_binary(Keyword.get(opts, :session_id)) do
      lines =
        ProcessManager.list()
        |> Enum.filter(fn {id, _} -> BashOutput.authorize(id, opts) == :ok end)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.take(200)
        |> Enum.map(fn {id, record} ->
          name = get_in(record, [:service, :name])
          "#{id}#{if name, do: " (#{name})", else: ""}: #{Map.get(record, :status, :unknown)}"
        end)

      %AgentToolResult{
        content: [%TextContent{text: Enum.join(lines, "\n")}],
        details: %{cwd: cwd}
      }
    else
      {:error, "Process URLs require session_id"}
    end
  end

  def read("proc://" <> reference, signal, cwd, opts) do
    if valid_session?(opts) and valid_id?(reference) do
      id = Service.resolve(reference, cwd, opts)
      BashOutput.execute("proc", %{"process_id" => id, "peek" => true}, signal, nil, cwd, opts)
    else
      {:error, "Malformed process URL"}
    end
  end

  def write("proc://" <> reference, params, signal, cwd, opts) do
    case {valid_session?(opts), String.split(reference, "/")} do
      {true, [id, "kill"]} when id != "" ->
        id = Service.resolve(id, cwd, opts)
        KillProcess.execute("proc", %{"process_id" => id}, signal, nil, cwd, opts)

      {true, [id]} when id != "" ->
        id = Service.resolve(id, cwd, opts)

        ProcessInput.execute(
          "proc",
          %{"process_id" => id, "input" => Map.get(params, "content")},
          signal,
          nil,
          cwd,
          opts
        )

      _ ->
        {:error, "Malformed process URL"}
    end
  end

  defp valid_session?(opts) do
    id = Keyword.get(opts, :session_id)
    is_binary(id) and id != ""
  end

  defp valid_id?(id), do: id != "" and not String.contains?(id, ["/", "?", "#", "%", "\\"])
end
