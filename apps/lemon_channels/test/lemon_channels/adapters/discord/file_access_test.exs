defmodule LemonChannels.Adapters.Discord.FileAccessTest do
  @moduledoc """
  Discord `/file` and `/cwd` share the Telegram containment rules, driven
  through `Transport.process_event/2` with a stand-in transport for the
  guarded Discord CDN fetch.
  """
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Discord.Transport
  alias LemonChannels.BindingResolver
  alias LemonCore.{ChatScope, ProjectBindingStore, Store}

  @gateway_config_key :"Elixir.LemonGateway.Config"
  @guild_id 1_475_727_417_372_049_000
  @user_id 1_476_753_643_834_183_691

  defmodule FakeApi do
    def create(channel_id, %{files: [path]} = params) do
      send(:persistent_term.get({__MODULE__, :pid}), {
        :discord_file,
        channel_id,
        Path.basename(path),
        File.read!(path),
        params
      })

      {:ok, %{id: 1}}
    end

    def create(_channel_id, _params), do: {:ok, %{id: 1}}
  end

  setup do
    start_supervised!({Task.Supervisor, name: LemonChannels.Adapters.Discord.AsyncSupervisor})
    parent = self()
    :persistent_term.put({FakeApi, :pid}, parent)

    Application.put_env(:lemon_channels, :discord_interaction_responder, fn interaction,
                                                                            payload ->
      send(parent, {:interaction_response, interaction, payload})
      :ok
    end)

    previous = Application.get_env(:lemon_gateway, @gateway_config_key)
    root = fresh_dir!("lemon-discord-file-root")
    outside = fresh_dir!("lemon-discord-file-outside")
    File.write!(Path.join(outside, "secret.txt"), "OUTSIDE_SECRET")
    channel_id = 1_475_727_417_372_049_419 + System.unique_integer([:positive])

    Application.put_env(:lemon_gateway, @gateway_config_key, %{
      projects: %{"fileproj" => %{root: root}},
      bindings: [],
      discord: %{api_mod: FakeApi}
    })

    scope = %ChatScope{transport: :discord, chat_id: channel_id, topic_id: nil}
    :ok = ProjectBindingStore.put_override(scope, "fileproj")

    on_exit(fn ->
      Application.delete_env(:lemon_channels, :discord_interaction_responder)
      :persistent_term.erase({FakeApi, :pid})
      ProjectBindingStore.delete_override(scope)

      if previous,
        do: Application.put_env(:lemon_gateway, @gateway_config_key, previous),
        else: Application.delete_env(:lemon_gateway, @gateway_config_key)

      File.rm_rf!(root)
      File.rm_rf!(outside)
    end)

    %{
      root: root,
      outside: outside,
      channel_id: channel_id,
      url: "https://cdn.discordapp.com/attachments/1/2/attachment"
    }
  end

  test "a symlinked file is refused for get and put", ctx do
    File.ln_s!(Path.join(ctx.outside, "secret.txt"), Path.join(ctx.root, "link.txt"))

    get = file_get(ctx.channel_id, "link.txt")
    process(get, %{})
    assert_receive {:interaction_response, ^get, %{data: %{content: text}}}
    assert text =~ "Symlinks are not allowed"

    put = file_put(ctx.channel_id, ctx.url, "doc.txt", "link.txt", true)
    process(put, %{})
    assert_receive {:interaction_response, ^put, %{data: %{content: text}}}
    assert text =~ "Symlinks are not allowed"

    assert File.read!(Path.join(ctx.outside, "secret.txt")) == "OUTSIDE_SECRET"
    refute_receive {:discord_file, _, _, _, _}, 100
  end

  test "a directory archive excludes .env and .git", ctx do
    File.write!(Path.join(ctx.root, "readme.md"), "hello")
    File.write!(Path.join(ctx.root, ".env"), "API_KEY=1")
    File.mkdir_p!(Path.join(ctx.root, ".git"))
    File.write!(Path.join(ctx.root, ".git/config"), "[core]")
    File.ln_s!(ctx.outside, Path.join(ctx.root, "linkdir"))
    File.ln_s!(Path.join(ctx.outside, "secret.txt"), Path.join(ctx.root, "leak.txt"))

    get = file_get(ctx.channel_id, ".")
    process(get, %{})

    assert_receive {:discord_file, _, _name, zip, _}, 2_000
    {:ok, entries} = :zip.unzip(zip, [:memory])
    assert Enum.map(entries, fn {name, _} -> to_string(name) end) == ["readme.md"]
    refute Enum.any?(entries, fn {_, bytes} -> bytes == "OUTSIDE_SECRET" end)
  end

  test "an attachment name is reduced to its basename", ctx do
    put = file_put(ctx.channel_id, ctx.url, "../.git/hooks/pre-commit", nil, false)
    process(put, %{})

    assert_receive {:interaction_response, ^put,
                    %{data: %{content: "Saved: incoming/pre-commit"}}},
                   2_000

    assert File.read!(Path.join(ctx.root, "incoming/pre-commit")) == "ATTACHMENT_BYTES"
    refute File.exists?(Path.join(ctx.root, ".git"))
  end

  test "a DM from a user outside allowed_user_ids is refused", ctx do
    File.write!(Path.join(ctx.root, "out.txt"), "hello")

    get =
      ctx.channel_id
      |> file_get("out.txt")
      |> Map.delete(:guild_id)

    process(get, %{allowed_user_ids: [@user_id + 1]})
    assert_receive {:interaction_response, ^get, %{data: %{content: text}}}
    assert text =~ "restricted"
    refute_receive {:discord_file, _, _, _, _}, 100
  end

  test "/cwd refuses host paths and never writes a global project", ctx do
    before = Store.list(:projects_dynamic)
    scope = %ChatScope{transport: :discord, chat_id: ctx.channel_id, topic_id: nil}
    :ok = ProjectBindingStore.delete_override(scope)

    for selector <- ["/", "../../", ctx.outside] do
      cwd = slash("cwd", [%{name: "path", value: selector}], ctx.channel_id)
      process(cwd, %{})
      assert_receive {:interaction_response, ^cwd, %{data: %{content: text}}}
      assert text =~ "configured project"
      refute text =~ ctx.outside
    end

    assert Store.list(:projects_dynamic) == before
    assert BindingResolver.get_project_override(scope) == nil
  end

  defp process(interaction, files) do
    state = %{
      account_id: "default",
      bot_user_id: 1,
      allowed_guild_ids: nil,
      allowed_channel_ids: nil,
      deny_unbound_channels: false,
      model_pickers: %{},
      buffers: %{},
      reaction_runs: %{},
      pending_new: %{},
      debounce_ms: 10_000,
      dedupe_ttl_ms: 600_000,
      attachment_net_opts: [
        resolver: fn "cdn.discordapp.com" -> {:ok, [{162, 159, 128, 233}]} end,
        send: fn _request -> {:ok, %{status: 200, headers: [], body: "ATTACHMENT_BYTES"}} end
      ],
      files:
        Map.merge(%{enabled: true, uploads_dir: "incoming", allowed_user_ids: [@user_id]}, files)
    }

    assert {:noreply, _} =
             Transport.process_event(
               {:discord_event, {:INTERACTION_CREATE, interaction, nil}},
               state
             )
  end

  defp file_get(channel_id, path) do
    slash(
      "file",
      [%{type: 1, name: "get", options: [%{name: "path", value: path}]}],
      channel_id
    )
  end

  defp file_put(channel_id, url, filename, path, force) do
    options =
      [%{name: "attachment", value: "900"}] ++
        if(path, do: [%{name: "path", value: path}], else: []) ++
        if(force, do: [%{name: "force", value: true}], else: [])

    "file"
    |> slash([%{type: 1, name: "put", options: options}], channel_id)
    |> put_in([:data, :resolved], %{attachments: %{"900" => %{url: url, filename: filename}}})
  end

  defp slash(name, options, channel_id) when is_binary(name) and is_integer(channel_id) do
    %{
      type: 2,
      id: Integer.to_string(1_503_803_470_493_257_999 + System.unique_integer([:positive])),
      channel_id: Integer.to_string(channel_id),
      guild_id: Integer.to_string(@guild_id),
      data: %{name: name, options: options},
      member: %{user: %{id: Integer.to_string(@user_id)}, permissions: "2048"}
    }
  end

  defp fresh_dir!(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end
end
