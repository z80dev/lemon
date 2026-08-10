defmodule LemonCore.HttpcTest do
  @moduledoc """
  Tests for the Httpc module.

  These exercise `Httpc.request/4` against `LemonCore.HttpStub`, a loopback
  HTTP server started per suite, so the default run is offline-deterministic.
  The one case that is only meaningful against the real internet is tagged
  `:external` and excluded by default (see `test/test_helper.exs`).
  """
  use ExUnit.Case, async: false

  alias LemonCore.Httpc
  alias LemonCore.HttpStub

  @httpbin_url "http://httpbin.org"

  setup_all do
    {:ok, base_url, listen_socket} = HttpStub.start()
    on_exit(fn -> :gen_tcp.close(listen_socket) end)
    {:ok, base_url: base_url}
  end

  # `:timeout` belongs in http_opts; httpc logs "Invalid option" if passed in opts.
  defp get(url, headers \\ [], http_opts \\ [timeout: 5_000], opts \\ []) do
    Httpc.request(:get, {String.to_charlist(url), headers}, http_opts, opts)
  end

  defp to_string_body(body) when is_list(body), do: List.to_string(body)
  defp to_string_body(body) when is_binary(body), do: body

  describe "ensure_started/0" do
    test "returns :ok" do
      assert :ok = Httpc.ensure_started()
    end

    test "starts inets and ssl applications" do
      Httpc.ensure_started()

      assert Application.started_applications()
             |> Enum.any?(fn {app, _, _} -> app == :inets end)

      assert Application.started_applications()
             |> Enum.any?(fn {app, _, _} -> app == :ssl end)
    end

    test "is idempotent" do
      assert :ok = Httpc.ensure_started()
      assert :ok = Httpc.ensure_started()
      assert :ok = Httpc.ensure_started()
    end
  end

  describe "request/4 - module interface" do
    test "exposes request/4" do
      assert Code.ensure_loaded?(Httpc)
      assert function_exported?(Httpc, :request, 4)
    end
  end

  describe "request/4 - GET requests" do
    test "makes a successful GET request", %{base_url: base_url} do
      assert {:ok, {{_, status_code, _}, headers, body}} = get("#{base_url}/get")
      assert status_code == 200
      assert is_list(headers)
      assert is_binary(body) or is_list(body)
    end

    test "GET request returns the served body", %{base_url: base_url} do
      assert {:ok, {{_, 200, _}, _headers, body}} = get("#{base_url}/get")

      body_str = to_string_body(body)
      assert body_str =~ "lemon_core"
      assert body_str =~ ~s("method": "GET")
    end
  end

  describe "request/4 - POST requests" do
    test "makes a successful POST request with a body", %{base_url: base_url} do
      request =
        {String.to_charlist("#{base_url}/post"), [], ~c"application/json",
         ~c"{\"test\": \"data\"}"}

      assert {:ok, {{_, status_code, _}, _headers, _body}} =
               Httpc.request(:post, request, [timeout: 5_000], [])

      assert status_code == 200
    end

    test "POST request echoes back the sent data", %{base_url: base_url} do
      request =
        {String.to_charlist("#{base_url}/post"), [], ~c"application/json",
         ~c"{\"key\": \"value\"}"}

      assert {:ok, {{_, 200, _}, _headers, response_body}} =
               Httpc.request(:post, request, [timeout: 5_000], [])

      response_str = to_string_body(response_body)
      assert response_str =~ "key"
      assert response_str =~ "value"
    end
  end

  describe "request/4 - other HTTP methods" do
    test "PUT request", %{base_url: base_url} do
      request =
        {String.to_charlist("#{base_url}/put"), [], ~c"application/json",
         ~c"{\"update\": \"value\"}"}

      assert {:ok, {{_, 200, _}, _headers, _body}} =
               Httpc.request(:put, request, [timeout: 5_000], [])
    end

    test "PATCH request", %{base_url: base_url} do
      request =
        {String.to_charlist("#{base_url}/patch"), [], ~c"application/json",
         ~c"{\"patch\": \"data\"}"}

      assert {:ok, {{_, 200, _}, _headers, _body}} =
               Httpc.request(:patch, request, [timeout: 5_000], [])
    end

    test "DELETE request", %{base_url: base_url} do
      request = {String.to_charlist("#{base_url}/delete"), []}

      assert {:ok, {{_, 200, _}, _headers, _body}} =
               Httpc.request(:delete, request, [timeout: 5_000], [])
    end

    test "HEAD request returns headers and no body", %{base_url: base_url} do
      request = {String.to_charlist("#{base_url}/get"), []}

      assert {:ok, {{_, 200, _}, headers, body}} =
               Httpc.request(:head, request, [timeout: 5_000], [])

      assert is_list(headers)
      assert to_string_body(body) == ""
    end
  end

  describe "request/4 - error cases" do
    test "returns an error when the connection is refused" do
      result = get(HttpStub.refused_url())

      assert match?({:error, _}, result)
    end

    test "returns an error for a malformed URL" do
      result = get("not-a-valid-url")

      assert match?({:error, _}, result) or match?({:error, :bad_request, _}, result)
    end

    test "handles 404 status code", %{base_url: base_url} do
      assert {:ok, {{_, 404, _}, _headers, _body}} = get("#{base_url}/status/404")
    end

    test "handles 500 status code", %{base_url: base_url} do
      assert {:ok, {{_, 500, _}, _headers, _body}} = get("#{base_url}/status/500")
    end

    test "respects timeout option", %{base_url: base_url} do
      # The stub holds the response well past the client's 100ms budget.
      result = get("#{base_url}/delay/2", [], [timeout: 100], [])

      assert match?({:error, :timeout}, result) or
               match?({:error, {:timeout, _}}, result) or
               match?({:error, :connect_timeout}, result)
    end
  end

  describe "request/4 - headers" do
    test "sends custom headers", %{base_url: base_url} do
      headers = [{~c"X-Custom-Header", ~c"custom-value"}]

      assert {:ok, {{_, 200, _}, _headers, body}} = get("#{base_url}/headers", headers)

      body_str = to_string_body(body)
      assert body_str =~ "x-custom-header"
      assert body_str =~ "custom-value"
    end

    test "sends User-Agent header", %{base_url: base_url} do
      headers = [{~c"User-Agent", ~c"lemon-core-test"}]

      assert {:ok, {{_, 200, _}, _headers, body}} = get("#{base_url}/user-agent", headers)

      body_str = to_string_body(body)
      assert body_str =~ "user-agent"
      assert body_str =~ "lemon-core-test"
    end
  end

  describe "request/4 - query parameters" do
    test "sends query parameters", %{base_url: base_url} do
      assert {:ok, {{_, 200, _}, _headers, body}} = get("#{base_url}/get?foo=bar&baz=qux")

      body_str = to_string_body(body)
      assert body_str =~ "foo"
      assert body_str =~ "bar"
      assert body_str =~ "baz"
      assert body_str =~ "qux"
    end
  end

  describe "request/4 - http options" do
    test "accepts http_opts parameter", %{base_url: base_url} do
      http_opts = [timeout: 5_000, connect_timeout: 5_000]

      assert {:ok, {{_, 200, _}, _headers, _body}} = get("#{base_url}/get", [], http_opts)
    end

    test "accepts opts parameter", %{base_url: base_url} do
      assert {:ok, {{_, 200, _}, _headers, body}} =
               get("#{base_url}/get", [], [timeout: 5_000], body_format: :binary)

      assert is_binary(body)
    end
  end

  describe "real network" do
    # Kept so the "does this actually work against the public internet" check
    # isn't lost, but excluded by default: run with `mix test --include external`.
    @tag :external
    @tag :integration
    test "reaches httpbin.org over the real network" do
      assert {:ok, {{_, 200, _}, _headers, body}} =
               get("#{@httpbin_url}/get", [], timeout: 30_000)

      assert to_string_body(body) =~ "httpbin.org"
    end
  end
end
