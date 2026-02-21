defmodule LemonCore.Id do
  @moduledoc """
  ID generation utilities for Lemon.

  Provides consistent ID generation for runs, sessions, and other entities.
  """

  @doc """
  Generate a random UUID v4.
  """
  @spec uuid() :: binary()
  def uuid do
    UUID.uuid4()
  end

  @doc """
  Generate a run ID.

  Run IDs are UUID v4 with a "run_" prefix for easy identification.

  ## Examples

      iex> id = LemonCore.Id.run_id()
      iex> String.starts_with?(id, "run_")
      true

  """
  @spec run_id() :: binary()
  def run_id do
    "run_#{uuid()}"
  end

  @doc """
  Generate a session ID.

  Session IDs are UUID v4 with a "sess_" prefix for easy identification.

  ## Examples

      iex> id = LemonCore.Id.session_id()
      iex> String.starts_with?(id, "sess_")
      true

  """
  @spec session_id() :: binary()
  def session_id do
    "sess_#{uuid()}"
  end

  @doc """
  Generate an approval ID.
  """
  @spec approval_id() :: binary()
  def approval_id do
    "appr_#{uuid()}"
  end

  @doc """
  Generate a cron job ID.
  """
  @spec cron_id() :: binary()
  def cron_id do
    "cron_#{uuid()}"
  end

  @doc """
  Generate a skill ID.
  """
  @spec skill_id() :: binary()
  def skill_id do
    "skill_#{uuid()}"
  end

  @doc """
  Generate an idempotency key for a scope and operation.

  ## Examples

      iex> key = LemonCore.Id.idempotency_key("messages", "send")
      iex> String.starts_with?(key, "messages:send:")
      true

  """
  @spec idempotency_key(scope :: binary(), operation :: binary()) :: binary()
  def idempotency_key(scope, operation) do
    "#{scope}:#{operation}:#{uuid()}"
  end
end
