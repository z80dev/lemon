defmodule LemonControlPlane.Methods.ContentScopeSystemTest do
  @moduledoc """
  `operator.read` is metadata-only for profile reads: persona/system prompt
  text and free-form profile descriptions need `operator.content`. MCP
  authentication headers never cross the wire at all.
  """
  use ExUnit.Case, async: false

  alias LemonControlPlane.Methods.{ProfilesCreate, Registry}

  @prose "The merger closes Friday at 41 dollars per share"
  @unlabelled "PROMPT_SECRET_7Q2X9"
  @content "#{@prose}; reference #{@unlabelled}"
  @header_secret "HEADER_CRED_5K8M1"

  @read_ctx %{auth: %{role: :operator, scopes: [:read]}}
  @content_ctx %{auth: %{role: :operator, scopes: [:read, :content]}}

  setup do
    root = Path.join(System.tmp_dir!(), "lemon-cs-system-#{System.unique_integer([:positive])}")
    state = Path.join(root, "state")
    File.mkdir_p!(state)
    previous_paths = Application.get_env(:lemon_core, :paths)

    Application.put_env(:lemon_core, :paths,
      home_state_dir: state,
      global_config: Path.join(state, "config.toml")
    )

    on_exit(fn ->
      if previous_paths,
        do: Application.put_env(:lemon_core, :paths, previous_paths),
        else: Application.delete_env(:lemon_core, :paths)

      File.rm_rf(root)
    end)

    assert {:ok, _} =
             ProfilesCreate.handle(
               %{
                 "id" => "persona",
                 "name" => "Persona",
                 "description" => @content,
                 "systemPrompt" => @content,
                 "model" => "openai:gpt-4o",
                 "mcpServers" => [
                   %{
                     "name" => "docs",
                     "url" => "https://mcp.example.com/mcp",
                     "headers" => %{"Authorization" => "Bearer #{@header_secret}"}
                   }
                 ]
               },
               @content_ctx
             )

    :ok
  end

  defp refute_content(result) do
    encoded = Jason.encode!(result) <> inspect(result)
    refute encoded =~ @prose
    refute encoded =~ @unlabelled
    refute encoded =~ @header_secret
  end

  test "profiles.list withholds persona text from read-only operators" do
    assert {:ok, result} = Registry.dispatch("profiles.list", %{}, @read_ctx)
    refute_content(result)
    assert result["contentWithheld"] == true

    assert [%{"id" => "persona", "name" => "Persona", "model" => "openai:gpt-4o"} = p] =
             result["profiles"]

    assert [%{"name" => "docs"}] = p["mcpServers"]
    assert is_binary(p["mcpConfigFingerprint"])
    assert result["count"] == 1

    assert {:ok, full} = Registry.dispatch("profiles.list", %{}, @content_ctx)
    assert full["contentWithheld"] == false
    assert [%{"systemPrompt" => @content, "description" => @content}] = full["profiles"]
    refute Jason.encode!(full) =~ @header_secret
  end

  test "profiles.get withholds persona text from read-only operators" do
    assert {:ok, result} = Registry.dispatch("profiles.get", %{"id" => "persona"}, @read_ctx)
    refute_content(result)
    assert result["contentWithheld"] == true
    assert %{"id" => "persona", "node" => "local"} = result["profile"]
    assert result["summary"]["profileId"] == "persona"

    assert {:ok, full} = Registry.dispatch("profiles.get", %{"id" => "persona"}, @content_ctx)
    assert full["contentWithheld"] == false
    assert full["profile"]["systemPrompt"] == @content
    refute Jason.encode!(full) =~ @header_secret
  end

  test "profiles.roster withholds descriptions from read-only operators" do
    assert {:ok, result} = Registry.dispatch("profiles.roster", %{}, @read_ctx)
    refute_content(result)
    assert result["contentWithheld"] == true
    assert [%{"id" => "persona", "availability" => "local"}] = result["profiles"]
    assert result["availabilityCounts"] == %{"local" => 1}

    assert {:ok, full} = Registry.dispatch("profiles.roster", %{}, @content_ctx)
    assert full["contentWithheld"] == false
    assert [%{"description" => @content}] = full["profiles"]
  end
end
