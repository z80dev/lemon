defmodule LemonCli.UpdateCommand do
  @moduledoc """
  Shared registry-driven update command for source and packaged launchers.

  Managed releases support `check`, `plan`, `apply`, `history`, and `rollback`.
  Source checkouts support the read-only `check` and `history` surfaces; binary
  plan/apply/rollback operations fail closed with `git pull` guidance because
  a checkout is not an installer-managed target.
  """

  alias LemonCli.CommandRegistry
  alias LemonCore.Update.Remote

  @spec run([String.t()]) :: 0 | 1 | 2
  def run(args) do
    with {:ok, command, opts} <- parse(args),
         :ok <- validate_mode(command) do
      ensure_started()
      execute(command, opts)
    else
      {:error, :usage} -> usage_error()
      {:error, :source_managed_only} -> source_managed_only()
    end
  end

  defp parse(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [
          json: :boolean,
          channel: :string,
          version: :string,
          confirm: :string,
          receipt: :string,
          limit: :integer,
          check: :boolean,
          rollback: :boolean
        ]
      )

    check? = opts[:check] == true
    rollback? = opts[:rollback] == true

    command =
      cond do
        positional == [] and check? and not rollback? ->
          "check"

        positional == [] and rollback? and not check? ->
          "rollback"

        positional == [] and not check? and not rollback? ->
          "plan"

        length(positional) == 1 and not check? and not rollback? and
            hd(positional) in ~w(check plan apply history rollback) ->
          hd(positional)

        true ->
          nil
      end

    if invalid == [] and command, do: {:ok, command, opts}, else: {:error, :usage}
  end

  defp validate_mode(command) do
    if launcher() == :source and command in ~w(plan apply rollback),
      do: {:error, :source_managed_only},
      else: :ok
  end

  defp execute("check", opts), do: call(:check, fn -> Remote.check(remote_opts(opts)) end, opts)
  defp execute("plan", opts), do: call(:plan, fn -> Remote.plan(remote_opts(opts)) end, opts)

  defp execute("apply", opts) do
    call(:apply, fn -> Remote.apply(remote_opts(opts)) end, opts)
  end

  defp execute("history", opts) do
    call(:history, fn -> Remote.history(remote_opts(opts)) end, opts)
  end

  defp execute("rollback", opts) do
    call(:rollback, fn -> Remote.rollback(remote_opts(opts)) end, opts)
  end

  defp call(action, fun, opts) do
    case fun.() do
      {:ok, result} ->
        report(action, result, opts[:json] || false)
        0

      {:error, reason} ->
        report_error(reason, opts[:json] || false)
        1
    end
  end

  defp remote_opts(opts) do
    []
    |> maybe_put(:channel, opts[:channel])
    |> maybe_put(:version, opts[:version])
    |> maybe_put(:confirm, opts[:confirm])
    |> maybe_put(:receipt, opts[:receipt])
    |> maybe_put(:limit, opts[:limit])
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp report(action, result, true) do
    result
    |> sanitize_result()
    |> then(&%{"action" => to_string(action), "ok" => true, "result" => &1})
    |> Jason.encode!()
    |> IO.puts()
  end

  defp report(:check, info, false) do
    IO.puts("Current: #{info.current}")
    IO.puts("Latest:  #{info.latest || "unknown"}")
    IO.puts(if info.update_available?, do: "Update available.", else: "Up to date.")
  end

  defp report(:plan, plan, false) do
    IO.puts("Update plan: #{plan.current} -> #{plan.target}")
    IO.puts("Channel: #{plan.channel}  Profile: #{plan.profile}  Platform: #{plan.platform}")
    IO.puts("Plan digest: #{plan.digest}")

    if plan.action == "apply" do
      IO.puts("Apply with: lemon update apply --confirm #{plan.digest}")
    else
      IO.puts("No update will be applied.")
    end
  end

  defp report(:apply, %{staged: nil} = result, false) do
    IO.puts("Already up to date (#{result.current}).")
  end

  defp report(:apply, result, false) do
    IO.puts("Staged #{result.staged}. Restart Lemon to use it.")
    IO.puts("Receipt: #{result.receipt["id"]}")
    IO.puts("Rollback digest: #{result.receipt["rollback_digest"]}")
  end

  defp report(:history, receipts, false) do
    if receipts == [] do
      IO.puts("No update receipts.")
    else
      Enum.each(receipts, fn receipt ->
        IO.puts(
          "#{receipt["id"]}  #{receipt["action"]}  #{receipt["status"]}  " <>
            "#{receipt["from_version"]} -> #{receipt["to_version"]}"
        )
      end)
    end
  end

  defp report(:rollback, result, false) do
    IO.puts("Rolled back to #{result.active}. Restart Lemon to use it.")
    IO.puts("Receipt: #{result.receipt["id"]}")
  end

  defp sanitize_result(result) when is_map(result) do
    result
    |> Map.drop([:path, "path"])
    |> Map.new(fn {key, value} -> {to_string(key), sanitize_result(value)} end)
  end

  defp sanitize_result(result) when is_list(result), do: Enum.map(result, &sanitize_result/1)
  defp sanitize_result(result), do: result

  defp report_error(reason, json?) do
    error = error_payload(reason)

    if json? do
      IO.puts(:stderr, Jason.encode!(%{"ok" => false, "error" => error}))
    else
      IO.puts(:stderr, "Update failed (#{error["kind"]}): #{error["message"]}")
    end
  end

  defp error_payload({:confirmation_required, digest}) do
    %{
      "kind" => "confirmation_required",
      "message" => "Run a fresh plan and provide its exact digest.",
      "confirm" => digest
    }
  end

  defp error_payload(reason) do
    kind = reason_kind(reason)
    %{"kind" => to_string(kind), "message" => safe_message(kind)}
  end

  defp reason_kind({kind, _detail}) when is_atom(kind), do: kind
  defp reason_kind({kind, _a, _b}) when is_atom(kind), do: kind
  defp reason_kind(kind) when is_atom(kind), do: kind
  defp reason_kind(_reason), do: :update_failed

  defp safe_message(:confirmation_mismatch), do: "The confirmation digest is stale or incorrect."
  defp safe_message(:plan_expired), do: "The update plan expired; create a fresh plan."
  defp safe_message(:unsupported_layout), do: "This is not an installer-managed Lemon release."
  defp safe_message(:update_locked), do: "Another update operation is active."
  defp safe_message(:receipt_not_found), do: "The update receipt was not found."

  defp safe_message(:stale_current_version),
    do: "The active version no longer matches the receipt."

  defp safe_message(:archive_path_escape), do: "The release archive contains an unsafe path."

  defp safe_message(:archive_unsafe_entry_type),
    do: "The release archive contains an unsafe entry type."

  defp safe_message(:checksum_mismatch), do: "The downloaded artifact checksum did not match."
  defp safe_message(:artifact_size_mismatch), do: "The downloaded artifact size did not match."

  defp safe_message(:staged_version_mismatch),
    do: "The staged launcher reported the wrong version."

  defp safe_message(_kind), do: "The update operation was refused safely."

  defp usage_error do
    IO.write(:stderr, CommandRegistry.help("update"))
    2
  end

  defp source_managed_only do
    IO.puts(
      :stderr,
      "Source checkouts cannot plan, apply, or roll back release artifacts. " <>
        "Update the checkout with your reviewed git pull workflow; use `lemon update check` for published-version visibility."
    )

    1
  end

  defp launcher do
    case System.get_env("LEMON_CLI_LAUNCHER") do
      "source" -> :source
      _ -> :release
    end
  end

  defp ensure_started do
    Enum.each([:crypto, :ssl, :inets, :jason, :lemon_core], &Application.ensure_all_started/1)
  end
end
