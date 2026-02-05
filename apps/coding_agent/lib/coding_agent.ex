defmodule CodingAgent do
  @moduledoc """
  CodingAgent - An AI coding assistant built on top of AgentCore.

  This library provides a complete coding agent implementation with:
  - Session management with JSONL persistence
  - Core tools (read, write, edit, bash)
  - Context compaction and branch summarization
  - Pluggable UI abstraction
  - Settings management

  ## Quick Start

      # Start a new session
      {:ok, session} = CodingAgent.Session.start_link(
        cwd: File.cwd!(),
        model: Ai.Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      )

      # Subscribe to events
      unsubscribe = CodingAgent.Session.subscribe(session)

      # Send a prompt
      :ok = CodingAgent.Session.prompt(session, "Read the mix.exs file")

      # Events will be sent as {:session_event, session_id, event} messages

  ## Architecture

  The coding agent is built on these core components:

  - `CodingAgent.Session` - Main GenServer orchestrating the agent
  - `CodingAgent.SessionManager` - JSONL persistence with tree structure
  - `CodingAgent.Messages` - Message types and LLM conversion
  - `CodingAgent.Tools` - Tool registry (read, write, edit, bash)
  - `CodingAgent.BashExecutor` - Streaming shell execution
  - `CodingAgent.Compaction` - Context compaction and summarization
  - `CodingAgent.Config` - Path and environment configuration
  - `CodingAgent.SettingsManager` - Canonical settings adapter (TOML)
  - `CodingAgent.UI` - Pluggable UI abstraction
  """

  @doc """
  Start a new coding session.

  When the `:coding_agent` application is running, the session is started under
  `CodingAgent.SessionSupervisor` so it is independent from the caller. If the
  supervisor is not running, this falls back to `CodingAgent.Session.start_link/1`.

  ## Options

  - `:cwd` - Working directory (required)
  - `:model` - Ai.Types.Model struct (required)
  - `:system_prompt` - Custom system prompt (optional)
  - `:tools` - Custom tool list (optional, defaults to coding tools)
  - `:session_file` - Path to existing session file to resume (optional)

  ## Examples

      {:ok, session} = CodingAgent.start_session(
        cwd: "/path/to/project",
        model: Ai.Models.get_model(:anthropic, "claude-sonnet-4-20250514")
      )
  """
  @spec start_session(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_session(opts) do
    if Process.whereis(CodingAgent.SessionSupervisor) do
      CodingAgent.SessionSupervisor.start_session(opts)
    else
      CodingAgent.Session.start_link(opts)
    end
  end

  @doc """
  Start a new coding session under the `CodingAgent.SessionSupervisor`.

  Returns `{:error, :not_started}` if the supervisor is not running.
  """
  @spec start_supervised_session(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_supervised_session(opts) do
    if Process.whereis(CodingAgent.SessionSupervisor) do
      CodingAgent.SessionSupervisor.start_session(opts)
    else
      {:error, :not_started}
    end
  end

  @doc """
  Look up a supervised session by session ID.
  """
  @spec lookup_session(String.t()) :: {:ok, pid()} | :error
  defdelegate lookup_session(session_id), to: CodingAgent.SessionRegistry, as: :lookup

  @doc """
  Get the default coding tools for a working directory.

  ## Examples

      tools = CodingAgent.coding_tools("/path/to/project")
  """
  @spec coding_tools(String.t(), keyword()) :: [AgentCore.Types.AgentTool.t()]
  defdelegate coding_tools(cwd, opts \\ []), to: CodingAgent.Tools

  @doc """
  Get read-only tools for exploration.
  """
  @spec read_only_tools(String.t(), keyword()) :: [AgentCore.Types.AgentTool.t()]
  defdelegate read_only_tools(cwd, opts \\ []), to: CodingAgent.Tools

  @doc """
  Load settings for a working directory.

  Merges global settings (`~/.lemon/config.toml`) with project settings
  (`<project>/.lemon/config.toml`).
  """
  @spec load_settings(String.t()) :: CodingAgent.SettingsManager.t()
  defdelegate load_settings(cwd), to: CodingAgent.SettingsManager, as: :load
end
