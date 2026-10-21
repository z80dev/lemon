defmodule LemonCli.PrintCommand do
  @moduledoc "Non-interactive, daemon-backed coding runs with machine-readable output."
  alias LemonCli.ControlPlaneClient, as: Client
  alias LemonCli.CLI.Error

  def run(args) do
    {opts, words, invalid} =
      OptionParser.parse(args,
        strict: [
          output: :string,
          model: :string,
          cwd: :string,
          session: :string,
          continue: :boolean,
          approval_policy: :string,
          allowed_tools: :string,
          denied_tools: :string
        ]
      )

    output = opts[:output] || "text"
    approval = opts[:approval_policy] || "deny"

    unless invalid == [] and output in ["text", "json", "stream-json"] and
             approval in ["deny", "allow"] do
      raise Error,
        message:
          "Invalid run options; use --output text|json|stream-json and --approval-policy deny|allow",
        exit_code: 2
    end

    if opts[:continue] && opts[:session],
      do: raise(Error, message: "Choose --continue or --session, not both", exit_code: 2)

    prompt = if words == [], do: IO.read(:stdio, :eof), else: Enum.join(words, " ")

    unless is_binary(prompt) and String.trim(prompt) != "",
      do: raise(Error, message: "A prompt argument or stdin is required", exit_code: 2)

    cwd = Path.expand(opts[:cwd] || File.cwd!())

    unless File.dir?(cwd),
      do: raise(Error, message: "--cwd must name an existing directory", exit_code: 2)

    with :ok <- LemonCli.LocalRuntime.ensure_running(), {:ok, conn} <- Client.open() do
      try do
        session = session(conn, opts, cwd)
        policy = %{} |> tools("allow", opts[:allowed_tools]) |> tools("deny", opts[:denied_tools])

        params = %{
          "prompt" => prompt,
          "session_key" => session,
          "cwd" => cwd,
          "tool_policy" => policy
        }

        params = if opts[:model], do: Map.put(params, "model", opts[:model]), else: params

        case Client.call(conn, "agent", params) do
          {:ok, %{"run_id" => run_id}} when is_binary(run_id) and run_id != "" ->
            emit(output, %{"type" => "init", "run_id" => run_id, "session_key" => session})

            result =
              drain(conn, run_id, output, approval, System.monotonic_time(:millisecond) + 600_000)

            result =
              Map.merge(result, %{
                "type" => "result",
                "run_id" => run_id,
                "session_key" => session
              })

            case output do
              "text" ->
                if is_binary(result["answer"]), do: IO.puts(result["answer"])

                if result["ok"] != true,
                  do: IO.puts(:stderr, "Error: #{result["error"] || "Agent run failed"}")

              _ ->
                IO.puts(Jason.encode!(result))
            end

            if result["ok"] == true, do: 0, else: 1

          {:error, _} ->
            failure(output, "Run submission failed")

          _ ->
            failure(output, "Run submission returned no run ID")
        end
      after
        Client.close(conn)
      end
    else
      _ -> failure(output, "Cannot connect to the Lemon runtime")
    end
  end

  defp session(conn, opts, cwd) do
    cond do
      opts[:session] ->
        opts[:session]

      opts[:continue] ->
        case latest_session(conn, prefix(cwd), 0, nil) do
          nil ->
            raise Error, message: "No CLI session to continue in this directory", exit_code: 1

          entry ->
            entry["sessionKey"]
        end

      true ->
        prefix(cwd) <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    end
  end

  defp latest_session(conn, prefix, offset, best) do
    case Client.call(conn, "sessions.list", %{
           "agentId" => "default",
           "limit" => 100,
           "offset" => offset,
           "archived" => false
         }) do
      {:ok, %{"sessions" => sessions, "total" => total}} ->
        best =
          Enum.reduce(sessions, best, fn entry, current ->
            if String.starts_with?(entry["sessionKey"] || "", prefix) and
                 (is_nil(current) or (entry["updatedAtMs"] || 0) > (current["updatedAtMs"] || 0)),
               do: entry,
               else: current
          end)

        next = offset + length(sessions)

        if sessions != [] and next < total,
          do: latest_session(conn, prefix, next, best),
          else: best

      _ ->
        raise Error, message: "Cannot find a session to continue", exit_code: 1
    end
  end

  defp prefix(cwd),
    do:
      "agent:default:cli-" <>
        (:crypto.hash(:sha256, cwd) |> Base.encode16(case: :lower) |> binary_part(0, 16)) <> "-"

  defp tools(policy, _key, nil), do: policy

  defp tools(policy, key, names),
    do: Map.put(policy, key, String.split(names, ",", trim: true) |> Enum.map(&String.trim/1))

  defp drain(conn, run_id, output, approval, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    case Client.next_event(conn, remaining) do
      {:ok, frame} ->
        payload = frame["payload"] || %{}

        if payload["runId"] == run_id do
          emit(output, %{"type" => "event", "event" => frame["event"], "payload" => payload})

          cond do
            frame["event"] == "exec.approval.requested" ->
              decision = if approval == "allow", do: "approve_once", else: "deny"

              case Client.call(conn, "exec.approval.resolve", %{
                     "approvalId" => payload["approvalId"],
                     "decision" => decision
                   }) do
                {:ok, _} ->
                  drain(conn, run_id, output, approval, deadline)

                _ ->
                  _ = Client.call(conn, "chat.abort", %{"runId" => run_id})
                  %{"ok" => false, "error" => "Could not resolve tool approval"}
              end

            payload["type"] == "completed" ->
              case Client.call(conn, "agent.wait", %{"runId" => run_id, "timeoutMs" => 1000}) do
                {:ok, result} ->
                  # agent.wait retains the internal usage detail shape. The
                  # completed event is the canonical, normalized wire projection.
                  Map.merge(result, Map.take(payload, ["usage", "model", "durationMs"]))

                _ ->
                  Map.merge(Map.take(payload, ["usage", "model", "durationMs"]), %{
                    "ok" => false,
                    "error" =>
                      if(payload["ok"] == false,
                        do: "Agent run failed",
                        else: "Could not retrieve completed run"
                      )
                  })
              end

            true ->
              drain(conn, run_id, output, approval, deadline)
          end
        else
          drain(conn, run_id, output, approval, deadline)
        end

      {:error, reason} ->
        _ = Client.call(conn, "chat.abort", %{"runId" => run_id})
        %{"ok" => false, "error" => to_string(reason)}
    end
  end

  defp emit("stream-json", event), do: IO.puts(Jason.encode!(event))
  defp emit(_, _), do: :ok

  defp failure(output, message) do
    if output == "text",
      do: IO.puts(:stderr, "Error: " <> message),
      else: IO.puts(Jason.encode!(%{"type" => "result", "ok" => false, "error" => message}))

    1
  end
end
