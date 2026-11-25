defmodule LemonAutomation.ChatCommands.RemindersTest do
  use ExUnit.Case, async: true

  alias LemonAutomation.ChatCommands.Reminders

  # Cron manager stand-in. Reminders calls it synchronously from the caller, so
  # the job table lives in the test process dictionary.
  defmodule FakeCron do
    @key {__MODULE__, :jobs}

    def seed(jobs), do: Process.put(@key, jobs)
    def jobs, do: Process.get(@key, [])

    def add(params) do
      send(self(), {:cron_add, params})

      job =
        params
        |> Map.take([:name, :schedule, :timezone, :once, :agent_id, :session_key, :meta])
        |> Map.merge(%{
          id: "job_#{System.unique_integer([:positive])}",
          enabled: true,
          next_run_at_ms: 1_790_000_000_000
        })

      seed([job | jobs()])
      {:ok, job}
    end

    def list, do: jobs()

    def remove(id) do
      if Enum.any?(jobs(), &(&1.id == id)) do
        seed(Enum.reject(jobs(), &(&1.id == id)))
        send(self(), {:cron_remove, id})
        :ok
      else
        {:error, :not_found}
      end
    end
  end

  defmodule RejectingCron do
    def add(_params), do: {:error, {:invalid_schedule, "bad cron"}}
  end

  # A cron manager that is not running.
  defmodule StoppedCron do
    def add(_params), do: exit({:noproc, {GenServer, :call, [__MODULE__, :add]}})
  end

  @chat "agent:default:telegram:default:dm:42"
  @topic "agent:default:telegram:default:group:-100:thread:7"
  @other_chat "agent:default:telegram:default:dm:43"
  @now ~N[2026-09-27 10:15:30]

  defp opts(session_key, extra \\ []),
    do: Keyword.merge([session_key: session_key, cron_module: FakeCron, now: @now], extra)

  defp job(id, session_key, attrs \\ %{}) do
    Map.merge(
      %{
        id: id,
        name: "Reminder: #{id}",
        enabled: true,
        session_key: session_key,
        next_run_at_ms: 1_790_000_000_000,
        meta: %{"reminder" => true, "reminder_text" => "text #{id}"}
      },
      attrs
    )
  end

  describe "create/2" do
    test "adds a local-time cron job bound to the chat's session and confirms it" do
      reply = Reminders.create("in 20m check oven", opts(@chat, agent_id: "ops"))

      assert_received {:cron_add, params}
      assert params.schedule == "36 10 27 9 *"
      assert params.once == true
      assert params.timezone == "local"
      assert params.session_key == @chat
      assert params.agent_id == "ops"
      assert params.name == "Reminder: check oven"
      refute Map.has_key?(params, :deliver_to)
      assert params.prompt =~ "check oven"

      assert %{"reminder" => true, "reminder_text" => "check oven", "created_via" => "telegram"} =
               params.meta

      [%{id: id}] = FakeCron.jobs()
      assert reply =~ id
      assert reply =~ "once at Sun 2026-09-27 10:36"
      assert reply =~ ~r/Next run: \w{3} \d{4}-\d{2}-\d{2} \d{2}:\d{2}/
    end

    test "recurring reminders are not one-shot and default the agent to the session's" do
      Reminders.create("every weekday 8:30 daily brief", opts(@chat))

      assert_received {:cron_add, %{schedule: "30 8 * * 1-5", once: false, agent_id: "default"}}
    end

    test "long text is truncated in the job name but kept whole in meta" do
      what = String.duplicate("a", 100)
      Reminders.create("in 5m " <> what, opts(@chat))

      assert_received {:cron_add, params}
      assert String.length(params.name) <= String.length("Reminder: ") + 60
      assert params.meta["reminder_text"] == what
    end

    test "a parse error replies with usage and creates nothing" do
      reply = Reminders.create("every 7m stretch", opts(@chat))

      assert reply =~ "Usage: /remind"
      refute_received {:cron_add, _}
    end

    test "a stopped scheduler or a rejected job is reported" do
      assert Reminders.create("in 5m x", opts(@chat, cron_module: StoppedCron)) =~
               "unavailable"

      assert Reminders.create("in 5m x", opts(@chat, cron_module: RejectingCron)) =~
               "bad cron"
    end
  end

  describe "list/1" do
    test "shows only this chat's enabled reminders, ignoring agent and sub-session" do
      FakeCron.seed([
        job("mine", @chat),
        job("mine_other_agent", "agent:ops:telegram:default:dm:42:sub:abc"),
        job("paused", @chat, %{enabled: false}),
        job("not_reminder", @chat, %{meta: %{"heartbeat" => true}}),
        job("atom_meta", @chat, %{meta: %{reminder: true, reminder_text: "atom text"}}),
        job("foreign", @other_chat),
        job("topic", @topic)
      ])

      reply = Reminders.list(opts(@chat))

      assert reply =~ "mine - "
      assert reply =~ "text mine"
      assert reply =~ "mine_other_agent"
      assert reply =~ "atom text"
      refute reply =~ "paused"
      refute reply =~ "not_reminder"
      refute reply =~ "foreign"
      refute reply =~ "topic"
    end

    test "topics are separate chats" do
      FakeCron.seed([
        job("topic", @topic),
        job("root", "agent:default:telegram:default:group:-100")
      ])

      reply = Reminders.list(opts(@topic))

      assert reply =~ "topic"
      refute reply =~ "root"
    end

    test "an empty chat gets a friendly message" do
      FakeCron.seed([job("foreign", @other_chat)])
      assert Reminders.list(opts(@chat)) =~ "No reminders"
    end
  end

  describe "cancel/2" do
    test "removes a reminder from this chat" do
      FakeCron.seed([job("mine", @chat)])

      assert Reminders.cancel("mine", opts(@chat)) =~ "cancelled"
      assert_received {:cron_remove, "mine"}
      assert FakeCron.jobs() == []
    end

    test "refuses another chat's reminder and non-reminder jobs" do
      FakeCron.seed([
        job("foreign", @other_chat),
        job("heartbeat", @chat, %{meta: %{"heartbeat" => true}})
      ])

      assert Reminders.cancel("foreign", opts(@chat)) =~ "not found"
      assert Reminders.cancel("heartbeat", opts(@chat)) =~ "not found"
      refute_received {:cron_remove, _}
      assert length(FakeCron.jobs()) == 2
    end

    test "requires an id" do
      assert Reminders.cancel("  ", opts(@chat)) =~ "Usage: /unremind <id>"
    end
  end
end
