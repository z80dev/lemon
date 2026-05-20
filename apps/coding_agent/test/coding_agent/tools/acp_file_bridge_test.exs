defmodule CodingAgent.Tools.ACPFileBridgeTest do
  use ExUnit.Case, async: true

  alias AgentCore.Types.AgentToolResult
  alias Ai.Types.TextContent
  alias CodingAgent.Tools.{Edit, Patch, Write}

  @moduletag :tmp_dir

  test "write routes file content through the ACP client filesystem", %{tmp_dir: tmp_dir} do
    run_id = unique_run_id("write")
    path = Path.join(tmp_dir, "client-write.txt")
    :ok = LemonCore.Bus.subscribe(LemonCore.Bus.run_topic(run_id))

    task =
      Task.async(fn ->
        Write.execute("call_1", %{"path" => path, "content" => "from client"}, nil, nil, tmp_dir,
          run_id: run_id,
          acp_client_fs_write_text_file: true
        )
      end)

    params = reply_acp_request("fs/write_text_file", %{"result" => nil})

    assert params["path"] == path
    assert params["content"] == "from client"

    assert %AgentToolResult{content: [%TextContent{text: text}], details: details} =
             Task.await(task)

    assert text =~ "Successfully wrote"
    assert details.acp_client == true
    refute File.exists?(path)
  end

  test "edit reads and writes through the ACP client filesystem", %{tmp_dir: tmp_dir} do
    run_id = unique_run_id("edit")
    path = Path.join(tmp_dir, "client-edit.txt")
    :ok = LemonCore.Bus.subscribe(LemonCore.Bus.run_topic(run_id))

    task =
      Task.async(fn ->
        Edit.execute(
          "call_1",
          %{"path" => path, "old_text" => "world", "new_text" => "BEAM"},
          nil,
          nil,
          tmp_dir,
          run_id: run_id,
          acp_client_fs_read_text_file: true,
          acp_client_fs_write_text_file: true
        )
      end)

    read_params =
      reply_acp_request("fs/read_text_file", %{
        "result" => %{"content" => "hello world\n"}
      })

    write_params = reply_acp_request("fs/write_text_file", %{"result" => nil})

    assert read_params["path"] == path
    assert write_params["path"] == path
    assert write_params["content"] == "hello BEAM\n"

    assert %AgentToolResult{content: [%TextContent{text: text}], details: details} =
             Task.await(task)

    assert text =~ "Successfully replaced"
    assert text =~ "hello world"
    assert text =~ "hello BEAM"
    assert details.acp_client == true
  end

  test "patch applies updates through the ACP client filesystem", %{tmp_dir: tmp_dir} do
    run_id = unique_run_id("patch")
    :ok = LemonCore.Bus.subscribe(LemonCore.Bus.run_topic(run_id))

    patch_text = """
    *** Update File: client-patch.txt
    @@ context
     line 1
    -line 2
    +line two
     line 3
    """

    task =
      Task.async(fn ->
        Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir,
          run_id: run_id,
          acp_client_fs_read_text_file: true,
          acp_client_fs_write_text_file: true
        )
      end)

    read_params =
      reply_acp_request("fs/read_text_file", %{
        "result" => %{"content" => "line 1\nline 2\nline 3"}
      })

    write_params = reply_acp_request("fs/write_text_file", %{"result" => nil})
    expected_path = Path.join(tmp_dir, "client-patch.txt")

    assert read_params["path"] == expected_path
    assert write_params["path"] == expected_path
    assert write_params["content"] == "line 1\nline two\nline 3"

    assert %AgentToolResult{content: [%TextContent{text: text}], details: details} =
             Task.await(task)

    assert text =~ "Patch applied successfully"
    assert details.acp_client == true
    assert details.additions == 1
    assert details.removals == 1
  end

  test "patch deletes through the ACP client filesystem", %{tmp_dir: tmp_dir} do
    run_id = unique_run_id("patch_delete")
    :ok = LemonCore.Bus.subscribe(LemonCore.Bus.run_topic(run_id))

    patch_text = """
    *** Delete File: client-delete.txt
    """

    task =
      Task.async(fn ->
        Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir,
          run_id: run_id,
          acp_client_fs_read_text_file: true,
          acp_client_fs_write_text_file: true,
          acp_client_fs_delete_file: true
        )
      end)

    expected_path = Path.join(tmp_dir, "client-delete.txt")

    read_params =
      reply_acp_request("fs/read_text_file", %{
        "result" => %{"content" => "old\ncontent\n"}
      })

    delete_params = reply_acp_request("fs/delete_file", %{"result" => nil})

    assert read_params["path"] == expected_path
    assert delete_params["path"] == expected_path

    assert %AgentToolResult{content: [%TextContent{text: text}], details: details} =
             Task.await(task)

    assert text =~ "Patch applied successfully"
    assert details.acp_client == true
    assert details.additions == 0
    assert details.removals == 3
  end

  test "patch moves through the ACP client filesystem", %{tmp_dir: tmp_dir} do
    run_id = unique_run_id("patch_move")
    :ok = LemonCore.Bus.subscribe(LemonCore.Bus.run_topic(run_id))

    patch_text = """
    *** Update File: old-name.txt
    *** Move to: new-name.txt
    """

    task =
      Task.async(fn ->
        Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir,
          run_id: run_id,
          acp_client_fs_read_text_file: true,
          acp_client_fs_write_text_file: true,
          acp_client_fs_rename_file: true
        )
      end)

    rename_params = reply_acp_request("fs/rename_file", %{"result" => nil})

    assert rename_params["path"] == Path.join(tmp_dir, "old-name.txt")
    assert rename_params["targetPath"] == Path.join(tmp_dir, "new-name.txt")

    assert %AgentToolResult{content: [%TextContent{text: text}], details: details} =
             Task.await(task)

    assert text =~ "Patch applied successfully"
    assert details.acp_client == true
    assert details.changed == [Path.join(tmp_dir, "new-name.txt")]
  end

  test "patch rejects operations ACP filesystem cannot perform", %{tmp_dir: tmp_dir} do
    run_id = unique_run_id("patch_reject")

    patch_text = """
    *** Delete File: client-delete.txt
    """

    assert {:error, message} =
             Patch.execute("call_1", %{"patch_text" => patch_text}, nil, nil, tmp_dir,
               run_id: run_id,
               acp_client_fs_read_text_file: true,
               acp_client_fs_write_text_file: true
             )

    assert message =~ "ACP patch cannot delete files"
  end

  defp unique_run_id(prefix), do: "run_acp_#{prefix}_#{System.unique_integer([:positive])}"

  defp reply_acp_request(method, response) do
    receive do
      %LemonCore.Event{
        type: :acp_client_request,
        payload: %{method: ^method, params: params, reply_to: reply_to, ref: ref}
      } ->
        send(reply_to, {:acp_client_response, ref, response})
        params
    after
      1_000 -> flunk("timed out waiting for #{method}")
    end
  end
end
