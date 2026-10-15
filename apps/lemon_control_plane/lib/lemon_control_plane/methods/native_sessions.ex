defmodule LemonControlPlane.Methods.NativeSessions do
  @moduledoc false

  @not_found [:session_not_found, :entry_not_found]
  @conflict [
    :busy,
    :confirmation_required,
    :stale_confirmation,
    :checkpoint_scope_mismatch,
    :entry_not_on_active_branch
  ]
  @invalid [
    :not_user_message,
    :unsupported_session,
    :unsupported_file_type,
    :invalid_partial_restore
  ]

  def target(params) when is_map(params) do
    with {:ok, key} <- string(params, "sessionKey", 1024),
         {:ok, cwd} <- string(params, "cwd", 4096) do
      {:ok, key, cwd}
    end
  end

  def target(_), do: invalid("sessionKey and cwd are required")

  def string(params, field, max) do
    case Map.get(params, field) do
      value when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= max ->
        if String.valid?(value) and String.trim(value) != "" and
             not String.contains?(value, <<0>>) do
          {:ok, value}
        else
          invalid("#{field} must be a non-empty string without NUL bytes")
        end

      _ ->
        invalid("#{field} must be a non-empty string of at most #{max} bytes")
    end
  end

  def boolean(params, field, default) do
    case Map.get(params, field, default) do
      value when is_boolean(value) -> {:ok, value}
      _ -> invalid("#{field} must be a boolean")
    end
  end

  def integer(params, field, default, min, max) do
    case Map.get(params, field, default) do
      value when is_integer(value) and value >= min and value <= max -> {:ok, value}
      _ -> invalid("#{field} must be an integer between #{min} and #{max}")
    end
  end

  def invalid(message), do: {:error, {:invalid_params, message, nil}}

  def failure(reason) when reason in @not_found do
    {:error,
     {:not_found, "Native session entry not found", %{"reason" => Atom.to_string(reason)}}}
  end

  def failure(:checkpoint_missing) do
    {:error,
     {:conflict, "Some file mutations lack recoverable checkpoints; use history-only rewind",
      %{"reason" => "checkpoint_missing"}}}
  end

  def failure(:unrestorable_effects) do
    {:error,
     {:conflict,
      "Shell effects cannot be reverted; review and explicitly allow partial file restoration",
      %{"reason" => "unrestorable_effects"}}}
  end

  def failure(:partial_restore_unreviewable) do
    {:error,
     {:conflict,
      "Select a more recent turn with fully reviewable shell commands before partial restoration",
      %{"reason" => "partial_restore_unreviewable"}}}
  end

  def failure(reason) when reason in @conflict do
    {:error,
     {:conflict, "Native session operation requires a fresh preview or idle session",
      %{"reason" => Atom.to_string(reason)}}}
  end

  def failure(reason) when reason in @invalid do
    {:error,
     {:invalid_params, "Native session operation is not supported for this target",
      %{"reason" => Atom.to_string(reason)}}}
  end

  def failure(reason) when reason in [:session_store_unavailable, :unavailable] do
    {:error,
     {:unavailable, "Native session runtime unavailable", %{"reason" => Atom.to_string(reason)}}}
  end

  def failure(:outcome_unknown) do
    {:error,
     {:unavailable, "Native session mutation outcome is unknown; reconcile before retrying",
      %{"reason" => "outcome_unknown", "retrySafe" => false}}}
  end

  def failure(:restore_failed) do
    {:error,
     {:internal_error, "Native session file restore failed", %{"reason" => "restore_failed"}}}
  end

  def failure(:restore_rollback_failed) do
    {:error,
     {:internal_error, "Native session file restore and rollback failed; files may have changed",
      %{"reason" => "restore_rollback_failed", "retrySafe" => false}}}
  end

  def failure(_), do: {:error, {:internal_error, "Native session operation failed", nil}}
end
