defmodule LemonGateway.Transports.Email.Outbound do
  @moduledoc false

  require Logger

  alias LemonGateway.Store
  alias LemonGateway.Transports.Email
  alias LemonGateway.Types.Job

  @message_thread_table :email_message_threads
  @thread_state_table :email_thread_state
  @max_references 25
  @max_outbound_attachments 8
  @safe_html_tags ~w(
    p br pre code em strong b i a ul ol li blockquote h1 h2 h3 h4 h5 h6 hr
  )

  @spec deliver(Job.t(), map() | struct()) :: :ok | {:error, term()}
  def deliver(%Job{} = job, completed) do
    case job_reply_meta(job) do
      nil ->
        :ok

      reply when is_map(reply) ->
        with {:ok, envelope} <- build_envelope(reply),
             {:ok, message, message_id} <- build_message(envelope, completed),
             :ok <- send_message(envelope, message),
             :ok <- persist_thread_state(reply, message_id) do
          :ok
        else
          {:error, reason} ->
            Logger.warning("email outbound failed: #{inspect(reason)}")
            {:error, reason}
        end
    end
  rescue
    error ->
      reason = {:exception, Exception.message(error)}
      Logger.warning("email outbound crashed: #{inspect(reason)}")
      {:error, reason}
  end

  defp job_reply_meta(%Job{meta: meta}) when is_map(meta) do
    reply = Map.get(meta, :email_reply) || Map.get(meta, "email_reply")
    if is_map(reply), do: reply, else: nil
  end

  defp job_reply_meta(_), do: nil

  defp build_envelope(reply) do
    cfg = Email.config()
    to = normalize_address(reply_value(reply, :to))

    from =
      normalize_address(
        email_cfg(cfg, [:outbound, :from]) ||
          email_cfg(cfg, :from) ||
          reply_value(reply, :from) ||
          reply_value(reply, :from_hint)
      )

    cond do
      is_nil(to) ->
        {:error, :missing_recipient}

      is_nil(from) ->
        {:error, :missing_sender}

      true ->
        {:ok,
         %{
           to: to,
           from: from,
           subject: reply_subject(reply),
           in_reply_to: normalize_message_id(reply_value(reply, :in_reply_to)),
           references: normalize_reference_ids(reply_value(reply, :references)),
           thread_id: normalize_blank(reply_value(reply, :thread_id)),
           reply_to:
             normalize_address(
               reply_value(reply, :reply_to) ||
                 email_cfg(cfg, [:outbound, :reply_to]) ||
                 email_cfg(cfg, :reply_to)
             ),
           cfg: cfg
         }}
    end
  end

  defp build_message(envelope, completed) do
    summary = render_summary(completed)
    references = gather_attachment_references(completed)
    plain_body = build_plain_body(summary, references)
    html_body = build_html_body(summary, references)
    message_id = generate_message_id(envelope.from)

    mail =
      Mail.build_multipart()
      |> Mail.put_from(envelope.from)
      |> Mail.put_to(envelope.to)
      |> Mail.put_subject(envelope.subject)
      |> Mail.put_text(plain_body)
      |> Mail.put_html(html_body)
      |> maybe_put_header("reply-to", envelope.reply_to)
      |> maybe_put_header("in-reply-to", format_message_id(envelope.in_reply_to))
      |> maybe_put_header("references", format_references(envelope.references))
      |> Mail.Message.put_header("message-id", format_message_id(message_id))
      |> maybe_put_attachments(references.attach_paths)

    {:ok, Mail.render(mail), message_id}
  rescue
    error ->
      {:error, {:build_message_failed, Exception.message(error)}}
  end

  defp send_message(envelope, message) when is_binary(message) do
    with {:ok, smtp_opts} <- smtp_options(envelope.cfg) do
      case :gen_smtp_client.send_blocking({envelope.from, [envelope.to], message}, smtp_opts) do
        receipt when is_binary(receipt) ->
          :ok

        receipt when is_list(receipt) ->
          # LMTP can return a list of per-recipient statuses.
          if Enum.all?(receipt, &match?({_, _}, &1)), do: :ok, else: {:error, {:smtp, receipt}}

        {:error, _} = error ->
          {:error, {:smtp, error}}

        other when is_tuple(other) ->
          {:error, {:smtp, other}}

        _ ->
          :ok
      end
    end
  end

  defp send_message(_envelope, _message), do: {:error, :invalid_message}

  @doc false
  @spec smtp_options(map()) :: {:ok, keyword()} | {:error, term()}
  def smtp_options(cfg) when is_map(cfg) do
    relay =
      cfg
      |> first_defined([[:outbound, :relay], :smtp_relay, :relay])
      |> normalize_blank()

    if is_nil(relay) do
      {:error, :missing_smtp_relay}
    else
      ssl =
        cfg
        |> first_defined([[:outbound, :ssl], :smtp_ssl])
        |> truthy?()

      default_port = default_port_for_ssl(ssl)

      port =
        cfg
        |> first_defined([[:outbound, :port], :smtp_port])
        |> int_value(default_port)

      tls =
        cfg
        |> first_defined([[:outbound, :tls], :smtp_tls])
        |> parse_mode(:if_available, [:always, :never, :if_available])

      username =
        cfg
        |> first_defined([[:outbound, :username], :smtp_username])
        |> normalize_blank()

      password =
        cfg
        |> first_defined([[:outbound, :password], :smtp_password])
        |> normalize_blank()

      auth =
        cfg
        |> first_defined([[:outbound, :auth], :smtp_auth])
        |> parse_mode(default_auth_mode(username, password), [:always, :never, :if_available])

      hostname =
        cfg
        |> first_defined([[:outbound, :hostname], :smtp_hostname])
        |> normalize_blank()

      tls_versions =
        case first_defined(cfg, [[:outbound, :tls_versions], :smtp_tls_versions]) do
          values when is_list(values) and values != [] ->
            {:tls_options, [versions: Enum.map(values, &parse_tls_version/1)]}

          _ ->
            nil
        end

      opts =
        [
          {:relay, relay},
          {:port, port},
          {:ssl, ssl},
          {:tls, tls},
          {:auth, auth},
          {:no_mx_lookups, true}
        ]
        |> maybe_put_opt(:hostname, hostname)
        |> maybe_put_opt(:username, username)
        |> maybe_put_opt(:password, password)
        |> maybe_put_tuple(tls_versions)

      {:ok, opts}
    end
  end

  def smtp_options(_), do: {:error, :invalid_smtp_config}

  defp persist_thread_state(reply, message_id) when is_binary(message_id) do
    thread_id = normalize_blank(reply_value(reply, :thread_id))
    refs = normalize_reference_ids(reply_value(reply, :references))

    if is_binary(thread_id) do
      _ =
        Store.put(@message_thread_table, message_id, %{
          "thread_id" => thread_id,
          "updated_at_ms" => System.system_time(:millisecond)
        })

      existing =
        case Store.get(@thread_state_table, thread_id) do
          %{} = map -> map
          _ -> %{}
        end

      merged_refs =
        merge_reference_ids([
          existing[:references] || existing["references"],
          refs,
          [message_id]
        ])

      _ =
        Store.put(@thread_state_table, thread_id, %{
          "thread_id" => thread_id,
          "references" => merged_refs,
          "last_message_id" => message_id,
          "updated_at_ms" => System.system_time(:millisecond)
        })
    end

    :ok
  rescue
    _ -> :ok
  end

  defp persist_thread_state(_reply, _message_id), do: :ok

  defp render_summary(completed) do
    ok? = completed_value(completed, :ok) == true
    answer = completed_value(completed, :answer)
    error = completed_value(completed, :error)

    cond do
      ok? and is_binary(answer) and String.trim(answer) != "" ->
        answer

      ok? ->
        "Done."

      true ->
        "Request failed: " <> format_error(error)
    end
  end

  defp build_plain_body(summary, references) do
    refs =
      case references.refs do
        [] ->
          []

        list ->
          ["", "Attachment references:" | Enum.map(list, &"- #{&1}")]
      end

    ([summary] ++ refs)
    |> Enum.join("\n")
    |> String.trim()
  end

  defp build_html_body(summary, references) do
    refs =
      case references.refs do
        [] ->
          ""

        list ->
          items =
            list
            |> Enum.map(fn ref -> "<li><code>#{html_escape(ref)}</code></li>" end)
            |> Enum.join()

          "<h3>Attachment references</h3><ul>#{items}</ul>"
      end

    "<div>" <> markdown_to_html(summary) <> refs <> "</div>"
  end

  defp gather_attachment_references(completed) do
    files =
      completed
      |> completed_value(:meta)
      |> extract_files()

    refs = Enum.uniq(files.refs)

    attach_paths =
      files.paths
      |> Enum.filter(&File.exists?/1)
      |> Enum.take(@max_outbound_attachments)

    %{
      refs: refs,
      attach_paths: attach_paths
    }
  end

  defp extract_files(nil), do: %{refs: [], paths: []}

  defp extract_files(meta) when is_map(meta) do
    files = Map.get(meta, :files) || Map.get(meta, "files") || []

    refs =
      files
      |> List.wrap()
      |> Enum.flat_map(&file_refs/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    paths =
      refs
      |> Enum.filter(fn ref ->
        not String.starts_with?(ref, "http://") and not String.starts_with?(ref, "https://")
      end)
      |> Enum.uniq()

    %{refs: refs, paths: paths}
  end

  defp extract_files(_), do: %{refs: [], paths: []}

  defp file_refs(%{} = file) do
    [
      Map.get(file, :path) || Map.get(file, "path"),
      Map.get(file, :url) || Map.get(file, "url")
    ]
    |> Enum.map(&normalize_blank/1)
    |> Enum.reject(&is_nil/1)
  end

  defp file_refs(value) when is_binary(value), do: [value]
  defp file_refs(_), do: []

  defp maybe_put_attachments(mail, []), do: mail

  defp maybe_put_attachments(mail, paths) when is_list(paths) do
    Enum.reduce(paths, mail, fn path, acc ->
      try do
        Mail.put_attachment(acc, path)
      rescue
        _ -> acc
      end
    end)
  end

  defp markdown_to_html(markdown) when is_binary(markdown) do
    if Code.ensure_loaded?(EarmarkParser) and function_exported?(EarmarkParser, :as_ast, 1) do
      case EarmarkParser.as_ast(markdown) do
        {:ok, ast, _messages} when is_list(ast) ->
          render_ast(ast)

        {:error, ast, _messages} when is_list(ast) ->
          render_ast(ast)

        _ ->
          fallback_markdown(markdown)
      end
    else
      fallback_markdown(markdown)
    end
  rescue
    _ -> fallback_markdown(markdown)
  end

  defp markdown_to_html(_), do: fallback_markdown("")

  defp render_ast(ast) when is_list(ast), do: Enum.map_join(ast, &render_ast_node/1)

  defp render_ast_node(text) when is_binary(text), do: html_escape(text)

  defp render_ast_node({tag, attrs, children, _meta}) do
    tag_name = safe_tag(tag)
    attrs_html = render_attrs(attrs || [])
    inner = render_ast(children || [])

    if tag_name in ~w(br hr) do
      "<#{tag_name}#{attrs_html}/>"
    else
      "<#{tag_name}#{attrs_html}>#{inner}</#{tag_name}>"
    end
  end

  defp render_ast_node({tag, attrs, children}) do
    render_ast_node({tag, attrs, children, %{}})
  end

  defp render_ast_node(other), do: html_escape(to_string(other))

  defp render_attrs(attrs) when is_list(attrs) do
    attrs
    |> Enum.map(fn
      {k, v} -> {to_string(k), to_string(v)}
      other -> {to_string(other), ""}
    end)
    |> Enum.reject(fn {_k, v} -> v == "" end)
    |> Enum.map_join("", fn {k, v} ->
      " " <> html_escape(k) <> "=\"" <> html_escape(v) <> "\""
    end)
  end

  defp safe_tag(tag) do
    tag = tag |> to_string() |> String.downcase()
    if tag in @safe_html_tags, do: tag, else: "span"
  end

  defp fallback_markdown(markdown) do
    escaped = markdown |> html_escape() |> String.replace("\n", "<br/>\n")
    "<p>#{escaped}</p>"
  end

  defp html_escape(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end

  defp html_escape(value), do: value |> to_string() |> html_escape()

  defp format_error(error) when is_binary(error), do: error
  defp format_error(error), do: inspect(error)

  defp reply_subject(reply) do
    subject = normalize_blank(reply_value(reply, :subject)) || "(no subject)"

    if String.match?(subject, ~r/^\s*re\s*:/i) do
      subject
    else
      "Re: " <> subject
    end
  end

  defp reply_value(reply, key) when is_map(reply) do
    Map.get(reply, key) || Map.get(reply, to_string(key))
  end

  defp reply_value(_, _), do: nil

  defp completed_value(completed, key) when is_map(completed) do
    Map.get(completed, key) || Map.get(completed, to_string(key))
  end

  defp completed_value(_, _), do: nil

  defp normalize_address(nil), do: nil
  defp normalize_address({_, email}) when is_binary(email), do: normalize_address(email)

  defp normalize_address(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        nil

      String.contains?(value, "<") and String.contains?(value, ">") ->
        case Regex.run(~r/<\s*([^>]+)\s*>/, value) do
          [_, email] -> normalize_address(email)
          _ -> nil
        end

      true ->
        case Regex.run(~r/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,63}/i, value) do
          [email] -> String.downcase(email)
          _ -> nil
        end
    end
  end

  defp normalize_address(_), do: nil

  defp generate_message_id(from) when is_binary(from) do
    domain =
      from
      |> String.split("@")
      |> List.last()
      |> normalize_blank()
      |> Kernel.||("localhost")

    "lemon-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}@#{domain}"
  end

  defp format_message_id(nil), do: nil
  defp format_message_id(value) when is_binary(value), do: "<#{value}>"

  defp format_references(references) when is_list(references) do
    references
    |> Enum.map(&format_message_id/1)
    |> Enum.reject(&is_nil/1)
  end

  defp format_references(_), do: nil

  defp normalize_message_id(nil), do: nil

  defp normalize_message_id(value) when is_list(value) do
    value
    |> Enum.find_value(&normalize_message_id/1)
  end

  defp normalize_message_id({_, value}), do: normalize_message_id(value)

  defp normalize_message_id(value) when is_binary(value) do
    value =
      value
      |> String.trim()
      |> String.trim_leading("<")
      |> String.trim_trailing(">")

    if value == "", do: nil, else: value
  end

  defp normalize_message_id(_), do: nil

  defp normalize_reference_ids(value) when is_list(value) do
    value
    |> Enum.flat_map(&normalize_reference_ids/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(-@max_references)
  end

  defp normalize_reference_ids(value) when is_binary(value) do
    refs =
      Regex.scan(~r/<([^>]+)>/, value, capture: :all_but_first)
      |> List.flatten()
      |> Enum.map(&normalize_message_id/1)
      |> Enum.reject(&is_nil/1)

    case refs do
      [] ->
        value
        |> String.split(~r/[\s,]+/, trim: true)
        |> Enum.map(&normalize_message_id/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.take(-@max_references)

      _ ->
        refs |> Enum.uniq() |> Enum.take(-@max_references)
    end
  end

  defp normalize_reference_ids(other) do
    case normalize_message_id(other) do
      nil -> []
      id -> [id]
    end
  end

  defp merge_reference_ids(reference_sets) when is_list(reference_sets) do
    reference_sets
    |> Enum.flat_map(&normalize_reference_ids/1)
    |> Enum.reduce([], fn ref, acc ->
      if ref in acc do
        acc
      else
        acc ++ [ref]
      end
    end)
    |> Enum.take(-@max_references)
  end

  defp maybe_put_header(mail, _header, nil), do: mail

  defp maybe_put_header(mail, header, value) when is_binary(header) do
    Mail.Message.put_header(mail, header, value)
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, _key, ""), do: opts
  defp maybe_put_opt(opts, key, value), do: opts ++ [{key, value}]

  defp maybe_put_tuple(opts, nil), do: opts
  defp maybe_put_tuple(opts, tuple), do: opts ++ [tuple]

  defp first_defined(cfg, keys) when is_map(cfg) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      case email_cfg(cfg, key) do
        nil -> nil
        value -> {:value, value}
      end
    end)
    |> case do
      {:value, value} -> value
      _ -> nil
    end
  end

  defp email_cfg(cfg, [head | tail]) when is_map(cfg) do
    value = fetch_key(cfg, head)

    case tail do
      [] -> value
      _ when is_map(value) -> email_cfg(value, tail)
      _ -> nil
    end
  end

  defp email_cfg(cfg, key) when is_map(cfg) do
    fetch_key(cfg, key)
  end

  defp email_cfg(_, _), do: nil

  defp fetch_key(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Map.get(map, to_string(key))
    end
  end

  defp parse_mode(nil, default, _allowed), do: default
  defp parse_mode(value, _default, _allowed) when is_atom(value), do: value

  defp parse_mode(value, default, allowed) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    cond do
      normalized == "always" and Enum.member?(allowed, :always) ->
        :always

      normalized == "never" and Enum.member?(allowed, :never) ->
        :never

      normalized == "if_available" and Enum.member?(allowed, :if_available) ->
        :if_available

      true ->
        default
    end
  end

  defp parse_mode(_, default, _allowed), do: default

  defp default_auth_mode(username, password) when is_binary(username) and is_binary(password) do
    :if_available
  end

  defp default_auth_mode(_, _), do: :never

  defp parse_tls_version(version) when is_atom(version), do: version

  defp parse_tls_version(version) when is_binary(version) do
    case String.downcase(String.trim(version)) do
      "tlsv1" -> :tlsv1
      "tlsv1.1" -> :"tlsv1.1"
      "tlsv1.2" -> :"tlsv1.2"
      "tlsv1.3" -> :"tlsv1.3"
      _ -> :"tlsv1.2"
    end
  end

  defp parse_tls_version(_), do: :"tlsv1.2"

  defp default_port_for_ssl(true), do: 465
  defp default_port_for_ssl(false), do: 587

  defp int_value(value, _default) when is_integer(value) and value > 0, do: value

  defp int_value(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, _} when n > 0 -> n
      _ -> default
    end
  end

  defp int_value(_, default), do: default

  defp truthy?(value) when is_boolean(value), do: value
  defp truthy?(value) when is_integer(value), do: value != 0

  defp truthy?(value) when is_binary(value) do
    String.downcase(String.trim(value)) in ["1", "true", "yes", "on"]
  end

  defp truthy?(_), do: false

  defp normalize_blank(nil), do: nil

  defp normalize_blank(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_blank(_), do: nil
end
