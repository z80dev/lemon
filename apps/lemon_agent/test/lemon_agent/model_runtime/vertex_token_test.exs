defmodule LemonAgent.ModelRuntime.VertexTokenTest do
  # Process environment (GOOGLE_APPLICATION_CREDENTIALS, PATH) is global.
  use ExUnit.Case, async: false

  alias LemonAgent.ModelRuntime.{Credentials, VertexToken}

  setup do
    tmp = Path.join(System.tmp_dir!(), "vertex_token_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    previous = Map.new(~w(GOOGLE_APPLICATION_CREDENTIALS PATH), &{&1, System.get_env(&1)})
    System.delete_env("GOOGLE_APPLICATION_CREDENTIALS")

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  test "a service account token is minted once and cached until shortly before expiry" do
    json = service_account_json("cached@example.iam.gserviceaccount.com")
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      form = URI.decode_query(body)
      assert form["grant_type"] == "urn:ietf:params:oauth:grant-type:jwt-bearer"
      [_, claims, _] = String.split(form["assertion"], ".")
      claims = claims |> Base.url_decode64!(padding: false) |> Jason.decode!()
      send(test_pid, {:minted, claims["iss"]})
      Req.Test.json(conn, %{"access_token" => "ya29.minted", "expires_in" => 3600})
    end)

    opts = [req_options: [plug: {Req.Test, __MODULE__}]]

    assert {:ok, "ya29.minted"} = VertexToken.access_token(%{service_account_json: json}, opts)
    assert {:ok, "ya29.minted"} = VertexToken.access_token(%{service_account_json: json}, opts)
    assert_received {:minted, "cached@example.iam.gserviceaccount.com"}
    refute_received {:minted, _}
  end

  test "an unreadable configured service account refuses every ambient source", %{tmp: tmp} do
    marker = fake_gcloud(tmp, "echo ya29.gcloud")
    System.put_env("GOOGLE_APPLICATION_CREDENTIALS", Path.join(tmp, "missing.json"))

    assert {:error, :service_account_unavailable} =
             VertexToken.access_token(%{credential_error: :service_account_unavailable},
               gcloud: Path.join(tmp, "gcloud")
             )

    refute File.exists?(marker)
  end

  test "GOOGLE_APPLICATION_CREDENTIALS is used before gcloud", %{tmp: tmp} do
    marker = fake_gcloud(tmp, "echo ya29.gcloud")
    path = Path.join(tmp, "sa.json")
    File.write!(path, "{")
    System.put_env("GOOGLE_APPLICATION_CREDENTIALS", path)

    assert {:error, :invalid_service_account} =
             VertexToken.access_token(%{}, gcloud: Path.join(tmp, "gcloud"))

    refute File.exists?(marker)
  end

  test "gcloud runs once with a deadline and its token is cached", %{tmp: tmp} do
    marker = fake_gcloud(tmp, "echo ran >> '#{Path.join(tmp, "runs")}'\necho ya29.from-gcloud")
    gcloud = Path.join(tmp, "gcloud")

    assert {:ok, "ya29.from-gcloud"} = VertexToken.access_token(%{}, gcloud: gcloud)
    assert {:ok, "ya29.from-gcloud"} = VertexToken.access_token(%{}, gcloud: gcloud)
    assert File.exists?(marker)
    assert File.read!(Path.join(tmp, "runs")) == "ran\n"
  end

  test "gcloud failures are credential-free atoms", %{tmp: tmp} do
    fake_gcloud(tmp, "echo 'secret diagnostic' >&2\nexit 1")

    assert {:error, :gcloud_failed} =
             VertexToken.access_token(%{}, gcloud: Path.join(tmp, "gcloud"))

    assert {:error, :gcloud_not_found} =
             VertexToken.access_token(%{}, gcloud: Path.join(tmp, "absent"))

    refute VertexToken.error_message(:gcloud_failed) =~ "secret"
  end

  test "the credential callback returns the minted token for google_vertex requests" do
    json = service_account_json("callback@example.iam.gserviceaccount.com")

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"access_token" => "ya29.callback", "expires_in" => 3600})
    end)

    previous_defaults = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})

    try do
      providers = %{"google_vertex" => %{service_account_json: json}}
      assert Credentials.resolve_provider_api_key(:google_vertex, providers) == "ya29.callback"
    after
      Req.default_options(previous_defaults)
      Req.Test.set_req_test_to_private(%{})
    end
  end

  test "a refused mint resolves to the empty refusal, never another key" do
    providers = %{
      "google_vertex" => %{service_account_json: "{", api_key: "inline-key-must-not-win"}
    }

    assert Credentials.resolve_provider_api_key(:google_vertex, providers) == ""
  end

  defp fake_gcloud(tmp, body) do
    marker = Path.join(tmp, "gcloud-ran")
    path = Path.join(tmp, "gcloud")
    File.write!(path, "#!/bin/sh\n: > '#{marker}'\n#{body}\n")
    File.chmod!(path, 0o700)
    marker
  end

  defp service_account_json(email) do
    key = :public_key.generate_key({:rsa, 1024, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])

    Jason.encode!(%{
      "client_email" => email,
      "private_key" => pem,
      "token_uri" => "https://oauth2.example.test/token"
    })
  end
end
