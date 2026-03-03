defmodule LemonCore.ModelPolicy.Migration do
  @moduledoc """
  Migration utilities for transitioning from legacy policy storage to ModelPolicy.

  Supports migrating:
  - Telegram default model preferences (`:telegram_default_model`)
  - Telegram default thinking preferences (`:telegram_default_thinking`)

  ## Usage

      # Migrate all Telegram policies
      LemonCore.ModelPolicy.Migration.migrate_telegram()

      # Dry run to see what would be migrated
      LemonCore.ModelPolicy.Migration.migrate_telegram(dry_run: true)

      # Check migration status
      LemonCore.ModelPolicy.Migration.status()
  """

  alias LemonCore.ModelPolicy
  alias LemonCore.ModelPolicy.Route

  require Logger

  @typedoc "Migration result statistics"
  @type result :: %{
          migrated: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: non_neg_integer(),
          details: [map()]
        }

  @doc """
  Migrates Telegram default model and thinking policies to the new ModelPolicy system.

  ## Options

    * `:dry_run` - When true, only reports what would be migrated without making changes.
    * `:channel_id` - The channel ID to use for the migration (default: "telegram")

  ## Returns

  A map with migration statistics:
  - `:migrated` - Number of policies successfully migrated
  - `:skipped` - Number of policies already existing or empty
  - `:errors` - Number of policies that failed to migrate
  - `:details` - Detailed list of each migration operation
  """
  @spec migrate_telegram(keyword()) :: result()
  def migrate_telegram(opts \\ []) do
    dry_run? = Keyword.get(opts, :dry_run, false)
    channel_id = Keyword.get(opts, :channel_id, "telegram")

    Logger.info("Starting Telegram policy migration (dry_run=#{dry_run?})")

    # Migrate model policies
    model_result = migrate_telegram_models(channel_id, dry_run?)

    # Migrate thinking policies
    thinking_result = migrate_telegram_thinking(channel_id, dry_run?)

    result = %{
      migrated: model_result.migrated + thinking_result.migrated,
      skipped: model_result.skipped + thinking_result.skipped,
      errors: model_result.errors + thinking_result.errors,
      details: model_result.details ++ thinking_result.details
    }

    Logger.info(
      "Migration complete: #{result.migrated} migrated, " <>
        "#{result.skipped} skipped, #{result.errors} errors"
    )

    result
  end

  @doc """
  Returns the migration status showing counts of legacy policies.
  """
  @spec status() :: %{
          telegram_models: non_neg_integer(),
          telegram_thinking: non_neg_integer(),
          model_policies: non_neg_integer()
        }
  def status do
    telegram_models = count_legacy_policies(:telegram_default_model)
    telegram_thinking = count_legacy_policies(:telegram_default_thinking)
    model_policies = length(ModelPolicy.list("telegram"))

    %{
      telegram_models: telegram_models,
      telegram_thinking: telegram_thinking,
      model_policies: model_policies
    }
  end

  @doc """
  Checks if there are any legacy Telegram policies that need migration.
  """
  @spec needs_migration?() :: boolean()
  def needs_migration? do
    status = status()
    status.telegram_models > 0 or status.telegram_thinking > 0
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp migrate_telegram_models(channel_id, dry_run?) do
    legacy_policies = list_legacy_policies(:telegram_default_model)

    Enum.reduce(legacy_policies, %{migrated: 0, skipped: 0, errors: 0, details: []}, fn
      {{account_id, chat_id, thread_id}, legacy_value}, acc ->
        model_id = extract_model_id(legacy_value)

        if is_nil(model_id) or model_id == "" do
          %{acc | skipped: acc.skipped + 1}
        else
          result =
            migrate_single_policy(
              channel_id,
              account_id,
              chat_id,
              thread_id,
              model_id,
              nil,
              dry_run?
            )

          update_migration_acc(acc, result, %{
            type: :model,
            account: account_id,
            chat: chat_id,
            thread: thread_id,
            model: model_id
          })
        end

      _, acc ->
        %{acc | skipped: acc.skipped + 1}
    end)
  end

  defp migrate_telegram_thinking(channel_id, dry_run?) do
    legacy_policies = list_legacy_policies(:telegram_default_thinking)

    Enum.reduce(legacy_policies, %{migrated: 0, skipped: 0, errors: 0, details: []}, fn
      {{account_id, chat_id, thread_id}, legacy_value}, acc ->
        thinking_level = extract_thinking_level(legacy_value)

        if is_nil(thinking_level) do
          %{acc | skipped: acc.skipped + 1}
        else
          # For thinking-only policies, we need to check if there's a model policy
          # at the same route. If so, we merge; if not, we skip (thinking needs a model)
          route = build_route(channel_id, account_id, chat_id, thread_id)

          result =
            case ModelPolicy.get(route) do
              nil ->
                # No model policy exists, skip thinking-only
                %{status: :skipped, reason: :no_model_policy}

              existing_policy ->
                # Merge thinking level into existing policy
                if dry_run? do
                  %{status: :migrated, dry_run: true}
                else
                  updated_policy = Map.put(existing_policy, :thinking_level, thinking_level)

                  case ModelPolicy.set(route, updated_policy) do
                    :ok -> %{status: :migrated}
                    {:error, reason} -> %{status: :error, reason: reason}
                  end
                end
            end

          update_migration_acc(acc, result, %{
            type: :thinking,
            account: account_id,
            chat: chat_id,
            thread: thread_id,
            thinking: thinking_level
          })
        end

      _, acc ->
        %{acc | skipped: acc.skipped + 1}
    end)
  end

  defp migrate_single_policy(channel_id, account_id, chat_id, thread_id, model_id, thinking_level, dry_run?) do
    route = build_route(channel_id, account_id, chat_id, thread_id)

    # Check if policy already exists
    if ModelPolicy.exists?(route) do
      %{status: :skipped, reason: :already_exists}
    else
      if dry_run? do
        %{status: :migrated, dry_run: true}
      else
        policy_opts = [
          set_by: "migration",
          reason: "Migrated from legacy telegram_default_model"
        ]

        policy_opts =
          if thinking_level do
            Keyword.put(policy_opts, :thinking_level, thinking_level)
          else
            policy_opts
          end

        policy = ModelPolicy.new_policy(model_id, policy_opts)

        case ModelPolicy.set(route, policy) do
          :ok -> %{status: :migrated}
          {:error, reason} -> %{status: :error, reason: reason}
        end
      end
    end
  end

  defp update_migration_acc(acc, %{status: :migrated} = result, detail) do
    detail = Map.merge(detail, %{status: :migrated, dry_run: Map.get(result, :dry_run, false)})

    %{
      acc
      | migrated: acc.migrated + 1,
        details: [detail | acc.details]
    }
  end

  defp update_migration_acc(acc, %{status: :skipped} = result, detail) do
    detail = Map.merge(detail, %{status: :skipped, reason: Map.get(result, :reason, :unknown)})

    %{
      acc
      | skipped: acc.skipped + 1,
        details: [detail | acc.details]
    }
  end

  defp update_migration_acc(acc, %{status: :error} = result, detail) do
    detail = Map.merge(detail, %{status: :error, reason: Map.get(result, :reason, :unknown)})

    %{
      acc
      | errors: acc.errors + 1,
        details: [detail | acc.details]
    }
  end

  defp build_route(channel_id, account_id, chat_id, thread_id) do
    # Convert integer IDs to strings for consistency
    peer_id = if chat_id, do: to_string(chat_id), else: nil
    thread_id_str = if thread_id, do: to_string(thread_id), else: nil

    Route.new(channel_id, account_id, peer_id, thread_id_str)
  end

  defp extract_model_id(%{model: model}) when is_binary(model), do: model
  defp extract_model_id(%{"model" => model}) when is_binary(model), do: model
  defp extract_model_id(model) when is_binary(model), do: model
  defp extract_model_id(_), do: nil

  defp extract_thinking_level(%{thinking_level: level}) when is_atom(level), do: level
  defp extract_thinking_level(%{thinking_level: level}) when is_binary(level), do: String.to_atom(level)
  defp extract_thinking_level(%{"thinking_level" => level}) when is_binary(level), do: String.to_atom(level)
  defp extract_thinking_level(%{"thinking_level" => level}) when is_atom(level), do: level
  defp extract_thinking_level(level) when is_atom(level), do: level
  defp extract_thinking_level(level) when is_binary(level), do: String.to_atom(level)
  defp extract_thinking_level(_), do: nil

  defp list_legacy_policies(table) do
    LemonCore.Store.list(table)
  rescue
    _ -> []
  end

  defp count_legacy_policies(table) do
    length(list_legacy_policies(table))
  rescue
    _ -> 0
  end
end
