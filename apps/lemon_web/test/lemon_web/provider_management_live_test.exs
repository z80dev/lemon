defmodule LemonWeb.ProviderManagementLiveTest do
  use ExUnit.Case, async: false

  @endpoint LemonWeb.Endpoint

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  import ExUnit.CaptureLog

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "provider_management_live_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    project = Path.join(root, "project")
    config_path = Path.join(root, "config.toml")
    File.mkdir_p!(Path.join(project, ".lemon"))
    File.write!(config_path, initial_config())

    web_keys = [
      :access_token,
      :provider_configuration_fun,
      :provider_configuration_project_dir,
      :provider_snapshot_fun
    ]

    previous_web = Map.new(web_keys, &{&1, Application.get_env(:lemon_web, &1)})
    previous_paths = Application.get_env(:lemon_core, :paths)
    token = "provider-management-#{System.unique_integer([:positive, :monotonic])}"

    Application.put_env(:lemon_web, :access_token, token)
    Application.put_env(:lemon_web, :provider_configuration_project_dir, project)
    Application.delete_env(:lemon_web, :provider_configuration_fun)
    Application.delete_env(:lemon_web, :provider_snapshot_fun)
    Application.put_env(:lemon_core, :paths, global_config: config_path)

    on_exit(fn ->
      Enum.each(previous_web, fn
        {key, nil} -> Application.delete_env(:lemon_web, key)
        {key, value} -> Application.put_env(:lemon_web, key, value)
      end)

      if is_nil(previous_paths),
        do: Application.delete_env(:lemon_core, :paths),
        else: Application.put_env(:lemon_core, :paths, previous_paths)

      File.rm_rf!(root)
    end)

    %{config_path: config_path, project: project, root: root, token: token}
  end

  test "route requires configured authentication, strips query tokens, and carries CSRF", ctx do
    Application.delete_env(:lemon_web, :access_token)

    assert get(build_conn(), "/manage/providers") |> response(503) ==
             "Management access token is not configured"

    Application.put_env(:lemon_web, :access_token, ctx.token)
    assert get(build_conn(), "/manage/providers?token=wrong") |> response(401) == "Unauthorized"

    conn = get(build_conn(), "/manage/providers?view=routing&token=#{ctx.token}")
    assert redirected_to(conn, 302) == "/manage/providers?view=routing"
    refute response(conn, 302) =~ ctx.token

    conn = conn |> recycle() |> get("/manage/providers?view=routing")
    html = html_response(conn, 200)
    assert html =~ "Provider routing"
    assert Regex.match?(~r/<meta name="csrf-token" content="[^"]+"\s*\/?>/, html)
    refute html =~ ctx.token
    refute html =~ ctx.root

    sessions_conn = get(build_conn(), "/manage?token=#{ctx.token}")
    assert redirected_to(sessions_conn, 302) == "/manage"
    sessions_html = sessions_conn |> recycle() |> get("/manage") |> html_response(200)
    assert sessions_html =~ ~s(href="/manage/providers")
  end

  test "fallback preview writes nothing and apply uses the exact revision", ctx do
    original = File.read!(ctx.config_path)
    {:ok, view, html} = live(authenticated_conn(ctx.token), "/manage/providers")

    assert html =~ "1 ordered"
    assert html =~ "zai"

    rendered =
      render_submit(view, "preview-fallback-add", %{
        "fallback" => %{"provider" => "anthropic"}
      })

    assert rendered =~ "Preview ready"
    assert rendered =~ "Append fallback anthropic"
    assert rendered =~ "2 fallback(s)"
    assert File.read!(ctx.config_path) == original

    rendered = render_submit(view, "apply-preview", %{"apply" => %{}})
    assert rendered =~ "change applied"
    assert rendered =~ "2 ordered"
    assert File.read!(ctx.config_path) =~ ~s(fallback_providers = ["zai","anthropic"])
  end

  test "destructive fallback removal refuses a mismatch and accepts exact confirmation", ctx do
    {:ok, view, _html} = live(authenticated_conn(ctx.token), "/manage/providers")

    rendered = render_click(view, "preview-fallback-remove", %{"provider" => "zai"})
    assert rendered =~ "Destructive change"
    assert rendered =~ "<code>zai</code>"

    rendered =
      render_submit(view, "apply-preview", %{"apply" => %{"confirmation" => "wrong"}})

    assert rendered =~ "Exact confirmation did not match"
    assert rendered =~ "Append" or rendered =~ "Remove fallback zai"
    assert File.read!(ctx.config_path) =~ "zai"

    rendered =
      render_submit(view, "apply-preview", %{"apply" => %{"confirmation" => "zai"}})

    assert rendered =~ "change applied"
    assert File.read!(ctx.config_path) =~ "fallback_providers = []"
  end

  test "pool create, update, activate, and delete flow stays preview-first", ctx do
    {:ok, view, _html} = live(authenticated_conn(ctx.token), "/manage/providers")

    rendered =
      render_submit(view, "preview-pool-upsert", %{
        "pool" => %{
          "pool" => "burst",
          "providers" => "openai, anthropic",
          "strategy" => "round_robin",
          "activate" => "true"
        }
      })

    assert rendered =~ "Create or update pool burst"
    refute rendered =~ "Destructive change"
    rendered = render_submit(view, "apply-preview", %{"apply" => %{}})
    assert rendered =~ "burst"
    assert rendered =~ "Active"

    rendered =
      render_submit(view, "preview-pool-upsert", %{
        "pool" => %{
          "pool" => "burst",
          "providers" => "anthropic, openai",
          "strategy" => "priority"
        }
      })

    assert rendered =~ "Destructive change"
    assert rendered =~ "<code>burst</code>"

    rendered =
      render_submit(view, "apply-preview", %{"apply" => %{"confirmation" => "burst"}})

    assert rendered =~ "change applied"
    assert File.read!(ctx.config_path) =~ ~s(providers = ["anthropic","openai"])

    rendered = render_click(view, "preview-pool-activate", %{"pool" => "primary"})
    assert rendered =~ "Create or update pool primary"

    rendered =
      render_submit(view, "apply-preview", %{"apply" => %{"confirmation" => "primary"}})

    assert rendered =~ "change applied"

    rendered = render_click(view, "preview-pool-delete", %{"pool" => "burst"})
    assert rendered =~ "Delete pool burst"

    rendered =
      render_submit(view, "apply-preview", %{"apply" => %{"confirmation" => "burst"}})

    assert rendered =~ "change applied"
    refute rendered =~ ~s(id="pool-burst")
  end

  test "credential references are never retained or rendered", ctx do
    secret_ref = "secret:web_secondary_#{System.unique_integer([:positive])}"
    {:ok, view, html} = live(authenticated_conn(ctx.token), "/manage/providers")
    refute html =~ secret_ref

    {rendered, log} =
      with_log(fn ->
        render_submit(view, "preview-credential", %{
          "credential" => %{
            "pool" => "primary",
            "provider" => "openai",
            "operation" => "add",
            "credential_ref" => secret_ref
          }
        })
      end)

    assert rendered =~ "never retained or rendered"
    assert log =~ "[FILTERED]"
    refute log =~ secret_ref
    refute rendered =~ secret_ref
    refute rendered =~ String.replace_prefix(secret_ref, "secret:", "")
    assert File.read!(ctx.config_path) |> then(&(not String.contains?(&1, secret_ref)))

    rendered =
      render_submit(view, "apply-preview", %{
        "apply" => %{"credential_ref" => "secret:different"}
      })

    assert rendered =~ "Re-enter the same credential reference"
    refute rendered =~ secret_ref

    rendered =
      render_submit(view, "apply-preview", %{
        "apply" => %{"credential_ref" => secret_ref}
      })

    assert rendered =~ "1 opaque reference"
    refute rendered =~ secret_ref
    assert File.read!(ctx.config_path) =~ secret_ref

    rendered =
      render_submit(view, "preview-credential", %{
        "credential" => %{
          "pool" => "primary",
          "provider" => "openai",
          "operation" => "remove",
          "credential_ref" => secret_ref
        }
      })

    assert rendered =~ "<code>primary</code>"
    refute rendered =~ secret_ref

    rendered =
      render_submit(view, "apply-preview", %{
        "apply" => %{"confirmation" => "primary", "credential_ref" => secret_ref}
      })

    refute rendered =~ secret_ref
    refute File.read!(ctx.config_path) =~ secret_ref
  end

  test "stale apply fails closed while preserving the non-secret draft", ctx do
    {:ok, view, _html} = live(authenticated_conn(ctx.token), "/manage/providers")

    render_submit(view, "preview-fallback-add", %{
      "fallback" => %{"provider" => "anthropic"}
    })

    File.write!(ctx.config_path, File.read!(ctx.config_path) <> "\n# external edit\n")

    rendered = render_submit(view, "apply-preview", %{"apply" => %{}})
    assert rendered =~ "changed after preview"
    assert rendered =~ "drafts were kept"
    assert rendered =~ ~s(value="anthropic")
    refute rendered =~ ~s(id="provider-change-preview")
    refute File.read!(ctx.config_path) =~ ~s("anthropic")
  end

  test "runtime failures are bounded and redact callback details", ctx do
    secret = "sk-runtime-secret"

    Application.put_env(:lemon_web, :provider_snapshot_fun, fn ->
      {:error, {:failed, secret, ctx.root}}
    end)

    Application.put_env(:lemon_web, :provider_configuration_fun, fn _params ->
      {:error, :configuration_failed,
       "#{secret} https://private.example #{ctx.root} OPENAI_API_KEY"}
    end)

    {:ok, view, html} = live(authenticated_conn(ctx.token), "/manage/providers")
    assert html =~ "Provider routing status is temporarily unavailable"
    refute html =~ secret
    refute html =~ ctx.root
    refute html =~ "OPENAI_API_KEY"
    refute html =~ "private.example"

    rendered =
      render_submit(view, "preview-fallback-add", %{
        "fallback" => %{"provider" => "anthropic"}
      })

    assert rendered =~ "Provider configuration is temporarily unavailable"
    refute rendered =~ secret
    refute rendered =~ ctx.root
    refute rendered =~ "OPENAI_API_KEY"
    refute rendered =~ "private.example"
  end

  defp authenticated_conn(token) do
    conn = get(build_conn(), "/manage/providers?token=#{token}")
    assert redirected_to(conn, 302) == "/manage/providers"
    conn |> recycle() |> get("/manage/providers")
  end

  defp initial_config do
    """
    # retained operator note
    [defaults]
    provider = "openai"
    model = "gpt-5-mini"

    [runtime.provider_routing]
    fallback_providers = ["zai"]
    default_pool = "primary"

    [runtime.provider_routing.credential_pools.primary]
    providers = ["openai"]
    strategy = "priority"
    """
  end
end
