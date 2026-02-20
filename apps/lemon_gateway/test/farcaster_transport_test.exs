defmodule LemonGateway.FarcasterTransportTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias LemonGateway.Store
  alias LemonGateway.Transports.Farcaster.FrameServer

  @action_path "/frames/farcaster/actions"
  @frame_image_url "https://example.test/frame.png"
  @session_table :farcaster_frame_sessions

  setup do
    farcaster_cfg = %{
      action_path: @action_path,
      image_url: @frame_image_url,
      verify_trusted_data: false
    }

    Process.put({LemonGateway.Transports.Farcaster, :config_override}, farcaster_cfg)
    clear_frame_sessions()

    on_exit(fn ->
      clear_frame_sessions()
      Process.delete({LemonGateway.Transports.Farcaster, :config_override})
    end)

    :ok
  end

  test "frame server GET action path returns HTML frame metadata" do
    conn =
      conn(:get, @action_path)
      |> FrameServer.call([])

    assert conn.status == 200

    assert conn
           |> get_resp_header("content-type")
           |> List.first()
           |> String.starts_with?("text/html")

    html = conn.resp_body

    assert frame_meta(html, "fc:frame") == "vNext"
    assert frame_meta(html, "fc:frame:post_url") == "http://www.example.com#{@action_path}"

    state = frame_state(html)
    assert state["status"] == "ready"
    assert is_binary(state["session_ref"])
    assert state["session_ref"] != ""

    query = frame_image_query(html)
    assert query["session_ref"] == state["session_ref"]
    assert query["status"] == "Frame ready. Enter a prompt."
  end

  test "frame server POST action path routes through CastHandler for queued and new-session states" do
    fid = 420_001

    queued_conn = post_action(action_payload(fid, 1, input_text: "ship it"))

    assert queued_conn.status == 200
    queued_state = frame_state(queued_conn.resp_body)

    assert queued_state["status"] == "queued"
    assert queued_state["fid"] == fid
    assert queued_state["last_prompt"] == "ship it"
    assert is_binary(queued_state["last_run_id"])
    assert queued_conn.resp_body =~ "Queued run"

    new_session_conn = post_action(action_payload(fid, 2, state: queued_state))

    assert new_session_conn.status == 200
    new_session_state = frame_state(new_session_conn.resp_body)

    assert new_session_state["status"] == "new_session"
    assert new_session_state["fid"] == fid
    assert is_binary(new_session_state["session_ref"])
    assert new_session_state["session_ref"] != queued_state["session_ref"]
    assert new_session_conn.resp_body =~ "Started a fresh session."
  end

  test "frame state keeps session continuity when button 1 is used on follow-up action" do
    fid = 420_002

    first_conn = post_action(action_payload(fid, 1, input_text: "continue this"))

    assert first_conn.status == 200
    first_state = frame_state(first_conn.resp_body)

    assert first_state["status"] == "queued"
    assert is_binary(first_state["session_ref"])
    assert first_state["session_ref"] != ""
    assert is_binary(first_state["session_sig"])
    assert first_state["session_sig"] != ""

    follow_up_conn = post_action(action_payload(fid, 1, state: first_state))

    assert follow_up_conn.status == 200
    follow_up_state = frame_state(follow_up_conn.resp_body)

    assert follow_up_state["status"] == "queued"
    assert follow_up_state["session_ref"] == first_state["session_ref"]
    assert follow_up_state["last_prompt"] == "continue this"
  end

  test "frame image URL query includes session_ref and status" do
    fid = 420_003

    conn = post_action(action_payload(fid, 2))

    assert conn.status == 200

    state = frame_state(conn.resp_body)
    assert state["status"] == "new_session"

    query = frame_image_query(conn.resp_body)
    assert query["session_ref"] == state["session_ref"]
    assert query["status"] == "Started a fresh session."
  end

  test "non-action path returns 404" do
    get_conn =
      conn(:get, "/frames/farcaster/not-actions")
      |> FrameServer.call([])

    assert get_conn.status == 404

    post_conn =
      conn(:post, "/frames/farcaster/not-actions", Jason.encode!(%{}))
      |> put_req_header("content-type", "application/json")
      |> FrameServer.call([])

    assert post_conn.status == 404
  end

  defp post_action(payload) do
    conn(:post, @action_path, Jason.encode!(payload))
    |> put_req_header("content-type", "application/json")
    |> FrameServer.call([])
  end

  defp action_payload(fid, button_index, opts \\ []) do
    state = Keyword.get(opts, :state)
    input_text = Keyword.get(opts, :input_text)

    untrusted_data =
      %{
        "fid" => fid,
        "buttonIndex" => button_index
      }
      |> maybe_put("state", state)
      |> maybe_put("inputText", input_text)

    %{
      "untrustedData" => untrusted_data,
      "trustedData" => %{"messageBytes" => "test-message-bytes"}
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp frame_state(html) do
    html
    |> frame_meta("fc:frame:state")
    |> Jason.decode!()
  end

  defp frame_image_query(html) do
    html
    |> frame_meta("fc:frame:image")
    |> URI.parse()
    |> Map.get(:query, "")
    |> URI.decode_query()
  end

  defp frame_meta(html, property) do
    pattern = ~r/<meta\s+property="#{Regex.escape(property)}"\s+content="([^"]*)"\s*\/>/

    case Regex.run(pattern, html, capture: :all_but_first) do
      [content] -> html_unescape(content)
      _ -> flunk("missing frame meta #{property}")
    end
  end

  defp html_unescape(value) when is_binary(value) do
    value
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
  end

  defp clear_frame_sessions do
    @session_table
    |> Store.list()
    |> Enum.each(fn {key, _value} ->
      Store.delete(@session_table, key)
    end)
  rescue
    _ -> :ok
  end
end
