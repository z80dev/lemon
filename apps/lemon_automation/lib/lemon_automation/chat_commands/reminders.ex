defmodule LemonAutomation.ChatCommands.Reminders do
  @moduledoc """
  Channel-agnostic `/remind`, `/reminders`, and `/unremind` handling, reached
  from channel transports through `LemonCore.AutomationCommands`.

  Reminders are ordinary one-shot or recurring cron jobs created through the
  same `LemonAutomation.CronManager` API the agent `cron` tool uses. The job's
  `session_key` is the originating chat's session key, so cron delivery sends
  the result back to that chat/topic without an explicit `deliver_to`. Tests
  pass a cron manager stand-in as `:cron_module`.

  Every public function returns the reply text for the chat.
  """

  alias LemonAutomation.ChatCommands.ReminderParser
  alias LemonAutomation.CronManager
  alias LemonCore.SessionKey

  @name_max 60
  @unavailable "The reminder scheduler is unavailable right now."

  @doc """
  Create a reminder from `<when> <what>`.

  Options:
    * `:session_key` (required) - the chat's session key; delivery targets it
    * `:agent_id` - agent that runs the reminder (defaults to the session key's agent)
    * `:created_via` - channel name stored in job meta (default `"telegram"`)
    * `:now` - local `NaiveDateTime` used by the parser
    * `:cron_module` - cron manager stand-in for tests
  """
  @spec create(String.t() | nil, keyword()) :: String.t()
  def create(args_text, opts) do
    session_key = Keyword.fetch!(opts, :session_key)

    with {:ok, parsed} <- ReminderParser.parse(args_text || "", Keyword.take(opts, [:now])),
         {:ok, job} <- call_cron(:add, [add_params(parsed, session_key, opts)], opts) do
      created_text(job, parsed)
    else
      {:error, :not_available} -> @unavailable
      {:error, message} when is_binary(message) -> message
      {:error, reason} -> "Could not create the reminder: #{format_reason(reason)}"
    end
  end

  @doc """
  List this chat's enabled reminders.

  Options: `:session_key` (required), `:cron_module`.
  """
  @spec list(keyword()) :: String.t()
  def list(opts) do
    session_key = Keyword.fetch!(opts, :session_key)

    case chat_reminders(session_key, opts) do
      {:ok, jobs} ->
        case Enum.filter(jobs, &(Map.get(&1, :enabled) == true)) do
          [] ->
            "No reminders in this chat. Create one with /remind <when> <what>."

          enabled ->
            lines =
              enabled
              |> Enum.sort_by(&(Map.get(&1, :next_run_at_ms) || :infinity))
              |> Enum.map(&job_line/1)

            Enum.join(["Reminders" | lines] ++ ["Cancel with /unremind <id>."], "\n")
        end

      {:error, :not_available} ->
        @unavailable
    end
  end

  @doc """
  Cancel a reminder by id. Only reminders created in this chat can be cancelled.

  Options: `:session_key` (required), `:cron_module`.
  """
  @spec cancel(String.t() | nil, keyword()) :: String.t()
  def cancel(id, opts) do
    session_key = Keyword.fetch!(opts, :session_key)

    case String.trim(id || "") do
      "" ->
        "Usage: /unremind <id> (see /reminders for ids)"

      id ->
        with {:ok, jobs} <- chat_reminders(session_key, opts),
             %{} <- Enum.find(jobs, &(Map.get(&1, :id) == id)),
             :ok <- call_cron(:remove, [id], opts) do
          "Reminder #{id} cancelled."
        else
          {:error, :not_available} -> @unavailable
          _ -> "Reminder not found: #{id}"
        end
    end
  end

  # --- internals ------------------------------------------------------------

  defp add_params(parsed, session_key, opts) do
    %{
      name: "Reminder: " <> truncate(parsed.text),
      schedule: parsed.schedule,
      timezone: "local",
      once: parsed.once,
      agent_id: opts[:agent_id] || SessionKey.agent_id(session_key) || "default",
      session_key: session_key,
      prompt:
        "Reminder for the user: #{parsed.text}. Write the reminder message now in one " <>
          "or two short sentences; if it asks for information (e.g. a brief or a check), " <>
          "do that work and include the result.",
      meta: %{
        "reminder" => true,
        "reminder_text" => parsed.text,
        "reminder_description" => parsed.description,
        "created_via" => Keyword.get(opts, :created_via, "telegram")
      }
    }
  end

  defp created_text(job, parsed) do
    id = Map.get(job, :id)

    Enum.join(
      [
        "Reminder set: #{parsed.text}",
        "When: #{parsed.description}",
        "Next run: #{format_next_run(Map.get(job, :next_run_at_ms))}",
        "ID: #{id} (cancel with /unremind #{id})"
      ],
      "\n"
    )
  end

  defp job_line(job) do
    meta = Map.get(job, :meta) || %{}
    description = meta_value(meta, "reminder_description") || Map.get(job, :name)
    text = meta_value(meta, "reminder_text")
    label = if text, do: "#{description}: #{text}", else: to_string(description)

    "#{Map.get(job, :id)} - #{label} (next: #{format_next_run(Map.get(job, :next_run_at_ms))})"
  end

  defp chat_reminders(session_key, opts) do
    case call_cron(:list, [], opts) do
      jobs when is_list(jobs) ->
        {:ok, Enum.filter(jobs, &(reminder?(&1) and same_chat?(&1, session_key)))}

      _ ->
        {:error, :not_available}
    end
  end

  defp reminder?(job) do
    meta = Map.get(job, :meta)
    is_map(meta) and meta_value(meta, "reminder") == true
  end

  # Chat identity ignores the agent id and sub-session: a reminder belongs to
  # the chat/topic it was created in.
  defp same_chat?(job, session_key) do
    case {chat_identity(Map.get(job, :session_key)), chat_identity(session_key)} do
      {nil, _} -> false
      {identity, identity} -> true
      _ -> false
    end
  end

  defp chat_identity(session_key) when is_binary(session_key) do
    case SessionKey.parse(session_key) do
      %{kind: :channel_peer} = parsed ->
        {parsed.channel_id, parsed.account_id, parsed.peer_id, parsed.thread_id}

      _ ->
        nil
    end
  end

  defp chat_identity(_session_key), do: nil

  defp meta_value(meta, "reminder"), do: Map.get(meta, "reminder", Map.get(meta, :reminder))

  defp meta_value(meta, "reminder_text"),
    do: Map.get(meta, "reminder_text", Map.get(meta, :reminder_text))

  defp meta_value(meta, "reminder_description"),
    do: Map.get(meta, "reminder_description", Map.get(meta, :reminder_description))

  defp format_next_run(ms) when is_integer(ms) do
    ms
    |> :calendar.system_time_to_local_time(:millisecond)
    |> NaiveDateTime.from_erl!()
    |> ReminderParser.format_naive()
  end

  defp format_next_run(_ms), do: "not scheduled"

  defp truncate(text) do
    text = String.replace(text, ~r/\s+/u, " ")

    if String.length(text) > @name_max do
      String.slice(text, 0, @name_max - 1) <> "…"
    else
      text
    end
  end

  defp format_reason({tag, message})
       when tag in [:invalid_schedule, :invalid_target] and is_binary(message),
       do: message

  defp format_reason(reason), do: inspect(reason)

  # A scheduler that is not running (or does not answer) leaves the chat with
  # the unavailable reply.
  defp call_cron(function, args, opts) do
    apply(Keyword.get(opts, :cron_module, CronManager), function, args)
  catch
    :exit, _reason -> {:error, :not_available}
  end
end
