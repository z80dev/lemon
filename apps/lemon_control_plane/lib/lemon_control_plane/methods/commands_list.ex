defmodule LemonControlPlane.Methods.CommandsList do
  @moduledoc """
  Handler for the read-only `commands.list` method: the file-defined slash
  commands the daemon would expand for `cwd`.

  The list is the agent runtime's `slash_commands/1` projection (for the
  native runtime, `CodingAgent.Commands.list/1`), read fresh on every call, so
  clients show exactly the commands the daemon expands — including its
  configured agent directory — and never rescan command roots themselves.
  Descriptions and argument hints are bounded, single-line discovery metadata;
  names are returned verbatim because clients submit them back as `/name`.
  An unavailable runtime is `UNAVAILABLE`, never an empty list.
  """

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Methods.SkillsSupport
  alias LemonControlPlane.Protocol.Errors
  alias LemonCore.AgentRuntime

  @max_commands 1_000
  @max_cwd_bytes 4_096
  @max_description 600
  @max_argument_hint 200

  @impl true
  def name, do: "commands.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    with {:ok, cwd} <- cwd(params || %{}) do
      case AgentRuntime.call(:slash_commands, [cwd], :unavailable) do
        commands when is_list(commands) ->
          {:ok,
           %{
             "commands" => commands |> Enum.take(@max_commands) |> Enum.map(&project/1),
             "truncated" => length(commands) > @max_commands
           }}

        _unavailable ->
          {:error, Errors.unavailable("Slash commands are unavailable")}
      end
    end
  end

  defp cwd(%{"cwd" => cwd}) when is_binary(cwd) and byte_size(cwd) <= @max_cwd_bytes do
    if Path.type(cwd) == :absolute and not String.contains?(cwd, <<0>>),
      do: {:ok, cwd},
      else: bad_cwd()
  end

  defp cwd(_params), do: bad_cwd()

  defp bad_cwd, do: {:error, Errors.invalid_request("cwd must be an absolute path")}

  defp project(command) do
    %{
      "name" => command.name,
      "description" => SkillsSupport.text(command.description, @max_description) || "",
      "argumentHint" => SkillsSupport.text(command.argument_hint, @max_argument_hint)
    }
  end
end
