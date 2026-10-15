defmodule CodingAgent.Tools.ErrorCopyTest do
  use ExUnit.Case, async: false

  alias CodingAgent.TaskStore
  alias CodingAgent.Tools.Task.{Result, Followup}

  test "failed task polling, retrieval and followup never render tuple reasons" do
    reason = {:provider_failed, %{private: :detail}}
    id = TaskStore.new_task()
    on_exit(fn -> TaskStore.delete_task(id) end)
    :ok = TaskStore.fail(id, reason)

    for result <- [
          Result.do_poll(%{"task_id" => id}),
          Result.do_get(%{"task_id" => id}),
          CodingAgent.Tools.Agent.execute(
            "poll",
            %{"action" => "poll", "task_id" => id},
            nil,
            nil,
            System.tmp_dir!(),
            []
          )
        ] do
      assert [%{text: text}] = result.content
      assert_plain(text)
    end

    text = Followup.task_auto_followup_text(%{}, id, nil, %{ok: false, error: reason, answer: ""})
    assert_plain(text)
  end

  test "unexpected edit tuple failures have a recovery hint" do
    run_id = "run-error-copy-#{System.unique_integer([:positive])}"
    :ok = LemonCore.ACPClientBridge.register(run_id)
    root = System.tmp_dir!()

    task =
      Task.async(fn ->
        CodingAgent.Tools.Edit.execute(
          "call",
          %{"path" => "client-file", "old_text" => "before", "new_text" => "after"},
          nil,
          nil,
          root,
          run_id: run_id,
          acp_client_fs_read_text_file: true,
          acp_client_fs_write_text_file: true
        )
      end)

    assert_receive {:acp_client_request, %{reply_to: reply_to, ref: ref}}

    send(
      reply_to,
      {:acp_client_response, ref,
       %{"error" => %{"message" => {:storage_failed, %{private: :detail}}}}}
    )

    assert {:error, text} = Task.await(task)
    assert text =~ "Re-read the file"
    refute text =~ "{"
    refute text =~ ":detail"
  end

  defp assert_plain(text) do
    assert text =~ "lemon doctor"
    refute text =~ "{"
    refute text =~ "%{"
    refute text =~ ":detail"
  end
end
