defmodule CodingAgent.Tools.Bash do
  @moduledoc """
  Bash command execution tool for the coding agent.

  Provides shell command execution with streaming output support and
  cancellation via abort signals.
  """

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent
  alias CodingAgent.BashExecutor

  @default_timeout_ms 60_000

  @doc """
  Returns the bash tool definition.

  ## Parameters

    * `cwd` - The working directory for command execution
    * `opts` - Optional keyword list of options (reserved for future use)

  ## Returns

  An `AgentTool` struct configured for bash command execution.
  """
  @spec tool(cwd :: String.t(), opts :: keyword()) :: AgentTool.t()
  def tool(cwd, opts \\ []) do
    %AgentTool{
      name: "bash",
      description:
        "Execute a bash command. The command runs in a shell with the working directory set to the project root.",
      label: "Run Command",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "command" => %{"type" => "string", "description" => "The bash command to execute"},
          "pty" => %{
            "type" => "boolean",
            "description" =>
              "Run in PTY mode when the command needs a real terminal (e.g. sudo, ssh, top, less); default: false"
          }
        },
        "required" => ["command"]
      },
      execute: &execute(&1, &2, &3, &4, cwd, opts)
    }
  end

  @doc """
  Execute a bash command.

  ## Parameters

    * `tool_call_id` - Unique identifier for this tool invocation
    * `params` - Map containing "command" (required)
    * `signal` - Abort signal reference for cancellation (can be nil)
    * `on_update` - Callback function for streaming partial results (can be nil)
    * `cwd` - Working directory for command execution
    * `opts` - Additional options (reserved for future use)

  ## Returns

    * `AgentToolResult.t()` on success
    * `{:error, term()}` on failure
  """
  @spec execute(
          tool_call_id :: String.t(),
          params :: map(),
          signal :: reference() | nil,
          on_update :: (AgentToolResult.t() -> :ok) | nil,
          cwd :: String.t(),
          opts :: keyword()
        ) :: AgentToolResult.t() | {:error, term()}
  def execute(_tool_call_id, params, signal, on_update, cwd, opts) do
    # Check abort signal before starting
    if signal && AbortSignal.aborted?(signal) do
      %AgentToolResult{
        content: [%TextContent{text: "Command cancelled."}]
      }
    else
      do_execute(params, signal, on_update, cwd, opts)
    end
  end

  defp do_execute(params, signal, on_update, cwd, opts) do
    command = Map.fetch!(params, "command")
    use_pty = Map.get(params, "pty", false)

    # Set up streaming callback if on_update is provided
    {accumulator_pid, streaming_callback} = build_streaming_callback(on_update)

    timeout_ms =
      Keyword.get(opts, :timeout_ms, Keyword.get(opts, :bash_timeout_ms, @default_timeout_ms))

    executor_opts =
      [
        on_chunk: streaming_callback,
        signal: signal,
        timeout: timeout_ms,
        pty: use_pty
      ]

    try do
      case BashExecutor.execute(command, cwd, executor_opts) do
        {:ok, result} ->
          format_result(result)

        {:error, reason} ->
          %AgentToolResult{
            content: [%TextContent{text: "Error executing command: #{inspect(reason)}"}]
          }
      end
    after
      # Stop the accumulator Agent to prevent memory leaks
      if accumulator_pid, do: Agent.stop(accumulator_pid)
    end
  end

  defp build_streaming_callback(nil), do: {nil, nil}

  defp build_streaming_callback(on_update) do
    # Use an Agent to accumulate output for streaming updates
    {:ok, accumulator} = Agent.start_link(fn -> "" end)

    callback = fn chunk ->
      accumulated =
        Agent.get_and_update(accumulator, fn acc ->
          new_acc = acc <> chunk
          {new_acc, new_acc}
        end)

      on_update.(%AgentToolResult{
        content: [%TextContent{text: accumulated}]
      })
    end

    {accumulator, callback}
  end

  defp format_result(%BashExecutor.Result{} = result) do
    cond do
      result.cancelled ->
        # Cancelled via abort signal
        output_text =
          if result.output && result.output != "" do
            "Command cancelled.\n\n#{result.output}"
          else
            "Command cancelled."
          end

        %AgentToolResult{
          content: [%TextContent{text: output_text}],
          details: build_details(result)
        }

      result.exit_code == 0 ->
        # Success
        output = result.output || ""

        text =
          if result.truncated && result.full_output_path do
            "#{output}\n\n[Full output saved to: #{result.full_output_path}]"
          else
            output
          end

        %AgentToolResult{
          content: [%TextContent{text: text}],
          details: build_details(result)
        }

      true ->
        # Non-zero exit code (still success, just report the code)
        output = result.output || ""

        text =
          cond do
            result.truncated && result.full_output_path ->
              "#{output}\n\n[Full output saved to: #{result.full_output_path}]\n\nCommand exited with code #{result.exit_code}"

            output != "" ->
              "#{output}\n\nCommand exited with code #{result.exit_code}"

            true ->
              "Command exited with code #{result.exit_code}"
          end

        %AgentToolResult{
          content: [%TextContent{text: text}],
          details: build_details(result)
        }
    end
  end

  defp build_details(%BashExecutor.Result{} = result) do
    details = %{
      exit_code: result.exit_code,
      truncated: result.truncated
    }

    if result.full_output_path do
      Map.put(details, :full_output_path, result.full_output_path)
    else
      details
    end
  end
end
