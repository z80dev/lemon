defmodule LemonAutomation.CronJobTest do
  use ExUnit.Case, async: true

  alias LemonAutomation.CronJob

  defp required_attrs do
    %{
      id: "cron_test_1",
      name: "Daily Check",
      schedule: "0 9 * * *",
      agent_id: "agent_1",
      session_key: "agent:agent_1:main",
      prompt: "Run daily checks"
    }
  end

  defp new_job(attrs \\ %{}) do
    CronJob.new(Map.merge(required_attrs(), attrs))
  end

  describe "new/1" do
    test "creates a job from mixed atom/string keys with defaults and timestamps" do
      before = LemonCore.Clock.now_ms()

      job =
        CronJob.new(%{
          "name" => "Mixed Input Job",
          :schedule => "*/5 * * * *",
          "agent_id" => "agent_mixed",
          :session_key => "agent:agent_mixed:main",
          "prompt" => "ping",
          "enabled" => false,
          :timezone => "America/New_York",
          "jitter_sec" => 9,
          :timeout_ms => 120_000,
          "meta" => %{"source" => "mixed"}
        })

      after_ms = LemonCore.Clock.now_ms()

      assert is_binary(job.id)
      assert job.name == "Mixed Input Job"
      assert job.schedule == "*/5 * * * *"
      assert job.enabled == false
      assert job.agent_id == "agent_mixed"
      assert job.session_key == "agent:agent_mixed:main"
      assert job.prompt == "ping"
      assert job.timezone == "America/New_York"
      assert job.jitter_sec == 9
      assert job.timeout_ms == 120_000
      assert job.meta == %{"source" => "mixed"}
      assert job.created_at_ms >= before
      assert job.created_at_ms <= after_ms
      assert job.updated_at_ms == job.created_at_ms
      assert job.last_run_at_ms == nil
      assert job.next_run_at_ms == nil
    end

    test "uses explicit id when provided" do
      job = new_job(%{id: "cron_custom_id"})
      assert job.id == "cron_custom_id"
    end
  end

  describe "update/2" do
    test "updates mutable fields from mixed keys and preserves immutable fields" do
      job = new_job(%{id: "cron_update"})
      before = LemonCore.Clock.now_ms()

      updated =
        CronJob.update(job, %{
          :name => "Updated Name",
          "schedule" => "15 * * * *",
          :enabled => false,
          "prompt" => "new prompt",
          :timezone => "America/Chicago",
          "jitter_sec" => 30,
          :timeout_ms => 90_000,
          "meta" => %{"v" => 2},
          "id" => "cron_changed",
          :agent_id => "agent_changed",
          "session_key" => "agent:changed:main",
          :created_at_ms => 0
        })

      after_ms = LemonCore.Clock.now_ms()

      assert updated.name == "Updated Name"
      assert updated.schedule == "15 * * * *"
      assert updated.enabled == false
      assert updated.prompt == "new prompt"
      assert updated.timezone == "America/Chicago"
      assert updated.jitter_sec == 30
      assert updated.timeout_ms == 90_000
      assert updated.meta == %{"v" => 2}

      assert updated.id == job.id
      assert updated.agent_id == job.agent_id
      assert updated.session_key == job.session_key
      assert updated.created_at_ms == job.created_at_ms

      assert updated.updated_at_ms >= before
      assert updated.updated_at_ms <= after_ms
    end
  end

  describe "mark_run/2" do
    test "sets last_run_at_ms and refreshes updated_at_ms" do
      job = new_job()
      run_at_ms = 1_700_000_123_000
      before = LemonCore.Clock.now_ms()
      updated = CronJob.mark_run(job, run_at_ms)
      after_ms = LemonCore.Clock.now_ms()

      assert updated.last_run_at_ms == run_at_ms
      assert updated.updated_at_ms >= before
      assert updated.updated_at_ms <= after_ms
      assert updated.id == job.id
    end
  end

  describe "set_next_run/2" do
    test "sets and clears next_run_at_ms while updating updated_at_ms" do
      job = new_job()
      next_run_at_ms = 1_900_000_000_000

      before_set = LemonCore.Clock.now_ms()
      with_next = CronJob.set_next_run(job, next_run_at_ms)
      after_set = LemonCore.Clock.now_ms()

      assert with_next.next_run_at_ms == next_run_at_ms
      assert with_next.updated_at_ms >= before_set
      assert with_next.updated_at_ms <= after_set

      before_clear = LemonCore.Clock.now_ms()
      cleared = CronJob.set_next_run(with_next, nil)
      after_clear = LemonCore.Clock.now_ms()

      assert cleared.next_run_at_ms == nil
      assert cleared.updated_at_ms >= before_clear
      assert cleared.updated_at_ms <= after_clear
    end
  end

  describe "due?/1" do
    test "returns false when disabled" do
      now = LemonCore.Clock.now_ms()
      job = %{new_job() | enabled: false, next_run_at_ms: now - 10_000}
      refute CronJob.due?(job)
    end

    test "returns false when next_run_at_ms is nil" do
      job = %{new_job() | enabled: true, next_run_at_ms: nil}
      refute CronJob.due?(job)
    end

    test "returns true when enabled and next_run_at_ms is in the past" do
      now = LemonCore.Clock.now_ms()
      job = %{new_job() | enabled: true, next_run_at_ms: now - 10_000}
      assert CronJob.due?(job)
    end

    test "returns false when enabled and next_run_at_ms is in the future" do
      now = LemonCore.Clock.now_ms()
      job = %{new_job() | enabled: true, next_run_at_ms: now + 60_000}
      refute CronJob.due?(job)
    end
  end

  describe "to_map/1" do
    test "serializes all fields to a map" do
      job =
        struct!(new_job(%{id: "cron_map"}), %{
          enabled: false,
          timezone: "America/Los_Angeles",
          jitter_sec: 22,
          timeout_ms: 75_000,
          created_at_ms: 1_700_000_001_000,
          updated_at_ms: 1_700_000_002_000,
          last_run_at_ms: 1_700_000_003_000,
          next_run_at_ms: 1_700_000_004_000,
          meta: %{scope: "full"}
        })

      assert CronJob.to_map(job) == %{
               id: "cron_map",
               name: "Daily Check",
               schedule: "0 9 * * *",
               enabled: false,
               agent_id: "agent_1",
               session_key: "agent:agent_1:main",
               prompt: "Run daily checks",
               timezone: "America/Los_Angeles",
               jitter_sec: 22,
               timeout_ms: 75_000,
               created_at_ms: 1_700_000_001_000,
               updated_at_ms: 1_700_000_002_000,
               last_run_at_ms: 1_700_000_003_000,
               next_run_at_ms: 1_700_000_004_000,
               meta: %{scope: "full"}
             }
    end
  end

  describe "from_map/1" do
    test "restores a struct from atom-key map" do
      map = %{
        id: "cron_atom",
        name: "Atom Map Job",
        schedule: "*/10 * * * *",
        enabled: false,
        agent_id: "agent_atom",
        session_key: "agent:agent_atom:main",
        prompt: "atom prompt",
        timezone: "UTC",
        jitter_sec: 3,
        timeout_ms: 33_000,
        created_at_ms: 101,
        updated_at_ms: 202,
        last_run_at_ms: 303,
        next_run_at_ms: 404,
        meta: %{source: :atom}
      }

      assert CronJob.from_map(map) == %CronJob{
               id: "cron_atom",
               name: "Atom Map Job",
               schedule: "*/10 * * * *",
               enabled: false,
               agent_id: "agent_atom",
               session_key: "agent:agent_atom:main",
               prompt: "atom prompt",
               timezone: "UTC",
               jitter_sec: 3,
               timeout_ms: 33_000,
               created_at_ms: 101,
               updated_at_ms: 202,
               last_run_at_ms: 303,
               next_run_at_ms: 404,
               meta: %{source: :atom}
             }
    end

    test "restores from mixed keys and prefers atom keys when both are present" do
      map = %{
        "id" => "cron_string_id",
        "name" => "String Name",
        "schedule" => "* * * * *",
        "enabled" => true,
        "agent_id" => "agent_string",
        "session_key" => "agent:string:main",
        "prompt" => "string prompt",
        "timezone" => "America/New_York",
        "jitter_sec" => 99,
        "timeout_ms" => 200_000,
        "created_at_ms" => 222,
        "updated_at_ms" => 444,
        "last_run_at_ms" => 666,
        "next_run_at_ms" => 888,
        "meta" => %{"source" => "string"},
        :id => "cron_atom_id",
        :name => "Atom Name",
        :schedule => "0 * * * *",
        :enabled => false,
        :agent_id => "agent_atom",
        :session_key => "agent:atom:main",
        :prompt => "atom prompt",
        :timezone => "UTC",
        :jitter_sec => 1,
        :timeout_ms => 10_000,
        :created_at_ms => 111,
        :updated_at_ms => 333,
        :last_run_at_ms => 555,
        :next_run_at_ms => 777,
        :meta => %{source: :atom}
      }

      job = CronJob.from_map(map)

      assert job.id == "cron_atom_id"
      assert job.name == "Atom Name"
      assert job.schedule == "0 * * * *"
      assert job.enabled == false
      assert job.agent_id == "agent_atom"
      assert job.session_key == "agent:atom:main"
      assert job.prompt == "atom prompt"
      assert job.timezone == "UTC"
      assert job.jitter_sec == 1
      assert job.timeout_ms == 10_000
      assert job.created_at_ms == 111
      assert job.updated_at_ms == 333
      assert job.last_run_at_ms == 555
      assert job.next_run_at_ms == 777
      assert job.meta == %{source: :atom}
    end

    test "applies defaults for missing optional fields" do
      job =
        CronJob.from_map(%{
          "id" => "cron_defaults",
          "name" => "Defaults Job",
          "schedule" => "* * * * *",
          "agent_id" => "agent_defaults",
          "session_key" => "agent:defaults:main",
          "prompt" => "defaults prompt"
        })

      assert job.enabled == true
      assert job.timezone == "UTC"
      assert job.jitter_sec == 0
      assert job.timeout_ms == 300_000
      assert job.created_at_ms == nil
      assert job.updated_at_ms == nil
      assert job.last_run_at_ms == nil
      assert job.next_run_at_ms == nil
      assert job.meta == nil
    end
  end
end
