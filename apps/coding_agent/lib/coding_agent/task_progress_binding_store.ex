defmodule CodingAgent.TaskProgressBindingStore do
  @moduledoc """
  ETS-backed transient binding store for mapping async task ids and child run ids
  back to the original parent task surface.
  """

  alias CodingAgent.TaskProgressBindingServer

  @default_ttl_seconds 86_400

  @required_fields [
    :task_id,
    :child_run_id,
    :parent_run_id,
    :parent_session_key,
    :parent_agent_id,
    :root_action_id,
    :surface
  ]

  @spec new_binding(map()) :: :ok
  def new_binding(attrs) when is_map(attrs) do
    ensure_tables()

    binding =
      attrs
      |> ensure_required_fields!()
      |> Map.put_new(:inserted_at_ms, System.system_time(:millisecond))
      |> Map.put_new(:status, :running)
      |> validate_optional_fields!()

    TaskProgressBindingServer.put_binding(CodingAgent.TaskProgressBindingServer, binding)
  end

  @spec get_by_task_id(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_by_task_id(task_id) when is_binary(task_id) do
    ensure_tables()
    TaskProgressBindingServer.get_by_task_id(CodingAgent.TaskProgressBindingServer, task_id)
  end

  @spec get_by_child_run_id(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_by_child_run_id(child_run_id) when is_binary(child_run_id) do
    ensure_tables()
    TaskProgressBindingServer.get_by_child_run_id(CodingAgent.TaskProgressBindingServer, child_run_id)
  end

  @spec mark_completed(String.t()) :: :ok
  def mark_completed(child_run_id) when is_binary(child_run_id) do
    ensure_tables()
    TaskProgressBindingServer.mark_completed(CodingAgent.TaskProgressBindingServer, child_run_id)
  end

  @spec delete_by_child_run_id(String.t()) :: :ok
  def delete_by_child_run_id(child_run_id) when is_binary(child_run_id) do
    ensure_tables()
    TaskProgressBindingServer.delete_binding(CodingAgent.TaskProgressBindingServer, child_run_id)
  end

  @spec list_all() :: [map()]
  def list_all do
    ensure_tables()
    TaskProgressBindingServer.list_all(CodingAgent.TaskProgressBindingServer)
  end

  @spec cleanup_expired(non_neg_integer()) :: {:ok, non_neg_integer()}
  def cleanup_expired(ttl_seconds \\ @default_ttl_seconds)
      when is_integer(ttl_seconds) and ttl_seconds >= 0 do
    ensure_tables()
    TaskProgressBindingServer.cleanup(CodingAgent.TaskProgressBindingServer, ttl_seconds)
  end

  defp ensure_tables do
    TaskProgressBindingServer.ensure_tables(CodingAgent.TaskProgressBindingServer)
  end

  defp ensure_required_fields!(attrs) do
    Enum.each(@required_fields, fn field ->
      value = Map.get(attrs, field)

      cond do
        value in [nil, ""] ->
          raise ArgumentError, "missing required task progress binding field #{inspect(field)}"

        field == :surface and valid_surface?(value) ->
          :ok

        field == :surface ->
          raise ArgumentError,
                "invalid task progress binding field :surface: expected {:status_task, binary} or :status, got #{inspect(value)}"

        not is_binary(value) ->
          raise ArgumentError,
                "invalid task progress binding field #{inspect(field)}: expected binary, got #{inspect(value)}"

        true ->
          :ok
      end
    end)

    attrs
  end

  defp validate_optional_fields!(attrs) do
    inserted_at_ms = Map.get(attrs, :inserted_at_ms)
    status = Map.get(attrs, :status)

    if not is_integer(inserted_at_ms) do
      raise ArgumentError,
            "invalid task progress binding field :inserted_at_ms: expected integer, got #{inspect(inserted_at_ms)}"
    end

    unless status in [:running, :completed] do
      raise ArgumentError,
            "invalid task progress binding field :status: expected :running or :completed, got #{inspect(status)}"
    end

    attrs
  end

  defp valid_surface?(:status), do: true
  defp valid_surface?({:status_task, task_id}) when is_binary(task_id) and task_id != "", do: true
  defp valid_surface?(_), do: false

end
