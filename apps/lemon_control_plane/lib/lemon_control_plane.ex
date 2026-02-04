defmodule LemonControlPlane do
  @moduledoc """
  OpenClaw-compatible Gateway WebSocket/HTTP server for Lemon.

  LemonControlPlane provides a WebSocket and HTTP API for controlling and
  monitoring the Lemon agent system. It implements the OpenClaw Gateway
  protocol for compatibility with existing clients.

  ## Protocol Overview

  The control plane uses a frame-based protocol over WebSocket:

  - **Request frames** (`req`): Client-to-server method calls
  - **Response frames** (`res`): Server-to-client method responses
  - **Event frames** (`event`): Server-to-client async events
  - **Hello-OK frame** (`hello-ok`): Handshake completion

  ## Handshake

  Connections must begin with a `connect` method request. The server responds
  with a `hello-ok` frame containing server info, features, and initial snapshot.

  ## Authentication

  The control plane supports three roles:

  - `operator` - Default role for admin/operator clients
  - `node` - Role for paired nodes (browser, etc.)
  - `device` - Role for paired devices

  Each role has associated scopes that control method access:

  - `operator.admin` - Administrative operations
  - `operator.read` - Read-only operations
  - `operator.write` - Write operations
  - `operator.approvals` - Approval management
  - `operator.pairing` - Node/device pairing

  ## Example

      # Start the server (typically via Application supervision)
      {:ok, _pid} = LemonControlPlane.Server.start_link(port: 4040)

      # WebSocket clients connect to ws://host:4040/ws
      # HTTP health check at GET /healthz

  ## Methods

  The following methods are available (subject to authorization):

  - `health` - Health check
  - `status` - System status
  - `agent` - Submit agent runs
  - `chat.send` - Send chat messages
  - `chat.abort` - Abort active runs
  - `sessions.*` - Session management
  - `skills.*` - Skill management
  - `cron.*` - Cron job management
  - And more...

  See `LemonControlPlane.Methods.Registry` for the full list.
  """

  @doc """
  Returns the current protocol version.
  """
  @spec protocol_version() :: pos_integer()
  def protocol_version, do: 1

  @doc """
  Returns the server version string.
  """
  @spec server_version() :: String.t()
  def server_version do
    Application.spec(:lemon_control_plane, :vsn)
    |> to_string()
  end

  @doc """
  Returns the git commit hash if available.
  """
  @spec git_commit() :: String.t() | nil
  def git_commit do
    Application.get_env(:lemon_control_plane, :git_commit)
  end
end
