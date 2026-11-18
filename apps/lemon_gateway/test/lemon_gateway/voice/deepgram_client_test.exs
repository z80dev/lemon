defmodule LemonGateway.Voice.DeepgramClientTest do
  use ExUnit.Case, async: true

  alias LemonGateway.Voice.DeepgramClient

  test "Deepgram connections verify the server certificate and hostname" do
    url = "wss://api.deepgram.com/v1/listen?x=1"
    assert {:ok, ^url, opts} = DeepgramClient.connect_options(url, "CA123")

    assert opts[:insecure] == false
    assert [{"Authorization", "Token " <> _}] = opts[:extra_headers]
    ssl = Keyword.fetch!(opts, :ssl_options)
    assert ssl[:verify] == :verify_peer
    assert [_ | _] = ssl[:cacerts]
    assert ssl[:server_name_indication] == ~c"api.deepgram.com"
    assert [match_fun: _] = ssl[:customize_hostname_check]
  end

  test "a plaintext Deepgram URL is refused before the API key is sent" do
    assert DeepgramClient.connect_options("ws://api.deepgram.com/v1/listen", "CA123") ==
             {:error, :insecure_web_socket_url}
  end
end
