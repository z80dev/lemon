defmodule LemonMedia.Providers.DeepgramStreamTest do
  use ExUnit.Case, async: true

  alias LemonMedia.Providers.DeepgramStream

  @connect_opts [api_key: "test-key", name: :test_stream]

  test "Deepgram connections verify the server certificate and hostname" do
    url = "wss://api.deepgram.com/v1/listen?x=1"
    assert {:ok, ^url, opts} = DeepgramStream.connect_options(url, @connect_opts)

    assert opts[:insecure] == false
    assert [{"Authorization", "Token test-key"}] = opts[:extra_headers]
    ssl = Keyword.fetch!(opts, :ssl_options)
    assert ssl[:verify] == :verify_peer
    assert [_ | _] = ssl[:cacerts]
    assert ssl[:server_name_indication] == ~c"api.deepgram.com"
    assert [match_fun: _] = ssl[:customize_hostname_check]
  end

  test "a plaintext Deepgram URL is refused before the API key is sent" do
    assert DeepgramStream.connect_options("ws://api.deepgram.com/v1/listen", @connect_opts) ==
             {:error, :insecure_web_socket_url}
  end

  test "interim and alternate final results retain the call-facing shape" do
    state = %{on_transcript: &send(self(), {:transcript, &1})}
    interim = %{"type" => "Results", "is_final" => false, "channel" => %{}}

    assert {:ok, ^state} = DeepgramStream.handle_frame({:text, Jason.encode!(interim)}, state)
    assert_received {:transcript, ^interim}

    final = %{"type" => "Final", "transcript" => "hello", "confidence" => 0.9}
    assert {:ok, ^state} = DeepgramStream.handle_frame({:text, Jason.encode!(final)}, state)

    assert_received {:transcript,
                     %{
                       "is_final" => true,
                       "channel" => %{
                         "alternatives" => [%{"transcript" => "hello", "confidence" => 0.9}]
                       }
                     }}
  end
end
