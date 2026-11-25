defmodule LemonMCP.Transport.StdioEnvTest do
  # Mutates the BEAM OS environment, so it cannot run concurrently.
  use ExUnit.Case, async: false

  alias LemonMCP.Transport.Stdio

  @inherited %{
    "LEMON_NODE_TOKEN" => "leak-node",
    "LEMON_SECRETS_MASTER_KEY" => "leak-master",
    "OPENAI_API_KEY" => "ordinary-provider-key"
  }

  setup do
    saved = Map.new(Map.keys(@inherited), &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)
  end

  test "stdio MCP servers inherit ordinary keys but never Lemon credentials or reserved overrides" do
    System.put_env(@inherited)
    owner = self()

    start_supervised!(
      {Stdio,
       command: "sh",
       args: ["-c", "env; echo __DONE__; cat"],
       env: %{"LEMON_ANTHROPIC_API_KEY" => "override", "MCP_EXTRA" => "kept"},
       message_handler: fn bytes -> send(owner, {:bytes, bytes}) end}
    )

    output = collect("")
    assert output =~ "OPENAI_API_KEY=ordinary-provider-key"
    assert output =~ "MCP_EXTRA=kept"

    for name <- ["LEMON_NODE_TOKEN", "LEMON_SECRETS_MASTER_KEY", "LEMON_ANTHROPIC_API_KEY"] do
      refute String.contains?(output, name <> "="), "MCP server inherited #{name}"
    end
  end

  defp collect(acc) do
    if acc =~ "__DONE__" do
      acc
    else
      assert_receive {:bytes, bytes}, 5_000
      collect(acc <> bytes)
    end
  end
end
