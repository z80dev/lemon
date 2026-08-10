defmodule LemonChannels.Adapters.Email.Outbound do
  @moduledoc """
  Sends mail for the email channel adapter over an SMTP relay.

  Ported from `LemonGateway.Transports.Email.Outbound`. `smtp_options/1` is the
  same function it always was — its configuration semantics are pinned by
  characterization tests that were written before the move and carried over
  unchanged, so a difference there is a regression rather than a design choice.

  ## What the port had to change

  The gateway version was handed a finished run (`deliver(job, completed)`) and
  read its reply headers out of `job.meta.email_reply`, which the inbound half
  had put there. A `LemonChannels.Plugin` adapter is handed a
  `LemonChannels.OutboundPayload` instead, which carries the recipient, the
  thread and the id being replied to — but deliberately not a `Subject` or a
  `References` chain, since neither means anything to a channel that is not
  email. Those come from `LemonChannels.Adapters.Email.ThreadStore`, which the
  inbound half populates; see its moduledoc for why that state is worth
  keeping.

  Two behaviours did not survive, both because they described the old
  entrypoint rather than email:

    * The `job.meta` guard that made `deliver/2` a silent no-op for non-email
      runs. `deliver/1` is only ever called for payloads addressed to this
      channel, so a payload it cannot send is now an `{:error, reason}` — an
      unsendable message should be reported, not swallowed.
    * The "Attachment references" list appended to the body from the run's
      output files. In this pipeline a file is its own `:file` payload and is
      attached to its own message, so there is nothing to reference.
  """

  require Logger

  alias LemonChannels.Adapters.Email.{Config, MessageId, ThreadStore}
  alias LemonChannels.OutboundPayload

  @max_attachments 8
  @safe_html_tags ~w(
    p br pre code em strong b i a ul ol li blockquote h1 h2 h3 h4 h5 h6 hr
  )

  @doc """
  Sends `payload` as a reply on its thread.

  Returns `{:ok, message_id}` with the `Message-ID` of the sent mail, which is
  also recorded against the thread so the recipient's reply threads back.
  """
  @spec deliver(OutboundPayload.t() | term()) :: {:ok, binary()} | {:error, term()}
  def deliver(%OutboundPayload{kind: kind} = payload) when kind in [:text, :file] do
    cfg = Config.get()

    with {:ok, envelope} <- build_envelope(payload, cfg),
         {:ok, body} <- build_body(payload),
         {:ok, rendered, message_id} <- build_message(envelope, body),
         :ok <- send_message(envelope, rendered) do
      _ = ThreadStore.record_outbound(envelope.thread_id, message_id, envelope.references)
      {:ok, message_id}
    else
      {:error, reason} ->
        Logger.warning("email outbound failed: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    error ->
      reason = {:exception, Exception.message(error)}
      Logger.warning("email outbound crashed: #{inspect(reason)}")
      {:error, reason}
  end

  def deliver(%OutboundPayload{kind: kind}), do: {:error, {:unsupported_kind, kind}}
  def deliver(_payload), do: {:error, :invalid_payload}

  @doc """
  Builds `:gen_smtp_client` options from an email config map.

  `{:error, :missing_smtp_relay}` when no relay is configured, which is the
  common case: this adapter is inert until someone points it at a relay.
  """
  @spec smtp_options(map() | term()) :: {:ok, keyword()} | {:error, term()}
  def smtp_options(cfg) when is_map(cfg) do
    relay =
      cfg
      |> Config.first_defined([[:outbound, :relay], :smtp_relay, :relay])
      |> Config.blank_to_nil()

    if is_nil(relay) do
      {:error, :missing_smtp_relay}
    else
      ssl =
        cfg
        |> Config.first_defined([[:outbound, :ssl], :smtp_ssl])
        |> truthy?()

      port =
        cfg
        |> Config.first_defined([[:outbound, :port], :smtp_port])
        |> int_value(default_port_for_ssl(ssl))

      tls =
        cfg
        |> Config.first_defined([[:outbound, :tls], :smtp_tls])
        |> parse_mode(:if_available, [:always, :never, :if_available])

      username =
        cfg
        |> Config.first_defined([[:outbound, :username], :smtp_username])
        |> Config.blank_to_nil()

      password =
        cfg
        |> Config.first_defined([[:outbound, :password], :smtp_password])
        |> Config.blank_to_nil()

      auth =
        cfg
        |> Config.first_defined([[:outbound, :auth], :smtp_auth])
        |> parse_mode(default_auth_mode(username, password), [:always, :never, :if_available])

      hostname =
        cfg
        |> Config.first_defined([[:outbound, :hostname], :smtp_hostname])
        |> Config.blank_to_nil()

      tls_versions =
        case Config.first_defined(cfg, [[:outbound, :tls_versions], :smtp_tls_versions]) do
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

  def smtp_options(_cfg), do: {:error, :invalid_smtp_config}

  # ---------------------------------------------------------------------------
  # Envelope
  # ---------------------------------------------------------------------------

  @doc """
  The reply headers `payload` would be sent with.

  Public so the threading decisions — which subject a reply carries, which
  ancestors end up in `References` — are assertable without an SMTP server
  standing by. Not part of the adapter's contract with the platform.
  """
  @doc since: "phase 2.4"
  @spec build_envelope(OutboundPayload.t(), map()) :: {:ok, map()} | {:error, term()}
  def build_envelope(payload, cfg \\ nil)

  def build_envelope(%OutboundPayload{} = payload, nil),
    do: build_envelope(payload, Config.get())

  def build_envelope(%OutboundPayload{} = payload, cfg) when is_map(cfg) do
    thread_id = thread_id(payload)
    thread = ThreadStore.state(thread_id)

    to = address(peer_id(payload))

    from =
      address(
        Config.first_defined(cfg, [[:outbound, :from], :from]) ||
          thread["recipient"] ||
          payload.account_id
      )

    cond do
      is_nil(to) -> {:error, :missing_recipient}
      is_nil(from) -> {:error, :missing_sender}
      true -> {:ok, compose_envelope(payload, cfg, thread, thread_id, to, from)}
    end
  end

  defp compose_envelope(payload, cfg, thread, thread_id, to, from) do
    in_reply_to =
      MessageId.normalize(payload.reply_to) || MessageId.normalize(thread["last_message_id"])

    %{
      to: to,
      from: from,
      subject: reply_subject(subject_for(payload, thread)),
      in_reply_to: in_reply_to,
      references: MessageId.merge([thread["references"], [in_reply_to]]),
      thread_id: thread_id,
      reply_to: address(Config.first_defined(cfg, [[:outbound, :reply_to], :reply_to])),
      cfg: cfg
    }
  end

  defp thread_id(%OutboundPayload{peer: %{thread_id: thread_id}}) when is_binary(thread_id),
    do: thread_id

  defp thread_id(_payload), do: nil

  defp peer_id(%OutboundPayload{peer: %{id: id}}), do: id
  defp peer_id(_payload), do: nil

  # The thread's subject is the one the human wrote. Only when the thread is
  # unknown — a send that did not originate from an inbound message — does the
  # payload get to name it.
  defp subject_for(%OutboundPayload{meta: meta}, thread) do
    Config.blank_to_nil(thread["subject"]) || meta_subject(meta) || "(no subject)"
  end

  defp meta_subject(meta) when is_map(meta) do
    Config.blank_to_nil(meta[:subject] || meta["subject"])
  end

  defp meta_subject(_meta), do: nil

  defp reply_subject(subject) do
    if String.match?(subject, ~r/^\s*re\s*:/i) do
      subject
    else
      "Re: " <> subject
    end
  end

  # ---------------------------------------------------------------------------
  # Body
  # ---------------------------------------------------------------------------

  defp build_body(%OutboundPayload{kind: :text, content: content}) do
    case text_content(content) do
      nil -> {:error, :empty_body}
      text -> {:ok, %{text: text, attachments: []}}
    end
  end

  defp build_body(%OutboundPayload{kind: :file, content: content}) do
    files = content |> List.wrap() |> Enum.map(&file_path/1) |> Enum.reject(&is_nil/1)

    case Enum.filter(files, &File.exists?/1) do
      [] ->
        {:error, :no_readable_attachment}

      paths ->
        {:ok, %{text: caption(content) || "", attachments: Enum.take(paths, @max_attachments)}}
    end
  end

  defp text_content(content) when is_binary(content), do: Config.blank_to_nil(content)

  defp text_content(content) when is_map(content),
    do: Config.blank_to_nil(content[:text] || content["text"])

  defp text_content(_content), do: nil

  defp file_path(%{path: path}) when is_binary(path), do: path
  defp file_path(%{"path" => path}) when is_binary(path), do: path
  defp file_path(path) when is_binary(path), do: path
  defp file_path(_file), do: nil

  defp caption(content) when is_map(content),
    do: Config.blank_to_nil(content[:caption] || content["caption"])

  defp caption([first | _rest]), do: caption(first)
  defp caption(_content), do: nil

  # ---------------------------------------------------------------------------
  # Message
  # ---------------------------------------------------------------------------

  defp build_message(envelope, body) do
    message_id = MessageId.generate(envelope.from)

    mail =
      Mail.build_multipart()
      |> Mail.put_from(envelope.from)
      |> Mail.put_to(envelope.to)
      |> Mail.put_subject(envelope.subject)
      |> Mail.put_text(body.text)
      |> Mail.put_html(html_body(body.text))
      |> maybe_put_header("reply-to", envelope.reply_to)
      |> maybe_put_header("in-reply-to", MessageId.format(envelope.in_reply_to))
      |> maybe_put_header("references", references_header(envelope.references))
      |> Mail.Message.put_header("message-id", MessageId.format(message_id))
      |> put_attachments(body.attachments)

    {:ok, Mail.render(mail), message_id}
  rescue
    error -> {:error, {:build_message_failed, Exception.message(error)}}
  end

  defp references_header([]), do: nil
  defp references_header(references), do: MessageId.format_list(references)

  defp put_attachments(mail, []), do: mail

  defp put_attachments(mail, paths) do
    Enum.reduce(paths, mail, fn path, acc ->
      try do
        Mail.put_attachment(acc, path)
      rescue
        _ -> acc
      end
    end)
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

  # ---------------------------------------------------------------------------
  # HTML rendering
  # ---------------------------------------------------------------------------

  defp html_body(text), do: "<div>" <> markdown_to_html(text) <> "</div>"

  defp markdown_to_html(markdown) when is_binary(markdown) do
    if Code.ensure_loaded?(EarmarkParser) and function_exported?(EarmarkParser, :as_ast, 1) do
      case EarmarkParser.as_ast(markdown) do
        {:ok, ast, _messages} when is_list(ast) -> render_ast(ast)
        {:error, ast, _messages} when is_list(ast) -> render_ast(ast)
        _ -> fallback_markdown(markdown)
      end
    else
      fallback_markdown(markdown)
    end
  rescue
    _ -> fallback_markdown(markdown)
  end

  defp markdown_to_html(_markdown), do: fallback_markdown("")

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

  defp render_ast_node({tag, attrs, children}), do: render_ast_node({tag, attrs, children, %{}})
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

  # Anything outside the allow-list becomes a span: this HTML is assembled from
  # model output and rendered in someone's mail client.
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

  # ---------------------------------------------------------------------------
  # Config value coercion
  # ---------------------------------------------------------------------------

  defp address(nil), do: nil
  defp address({_name, email}) when is_binary(email), do: address(email)

  defp address(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        nil

      String.contains?(value, "<") and String.contains?(value, ">") ->
        case Regex.run(~r/<\s*([^>]+)\s*>/, value) do
          [_, email] -> address(email)
          _ -> nil
        end

      true ->
        case Regex.run(~r/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,63}/i, value) do
          [email] -> String.downcase(email)
          _ -> nil
        end
    end
  end

  defp address(_value), do: nil

  defp maybe_put_header(mail, _header, nil), do: mail

  defp maybe_put_header(mail, header, value) when is_binary(header),
    do: Mail.Message.put_header(mail, header, value)

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, _key, ""), do: opts
  defp maybe_put_opt(opts, key, value), do: opts ++ [{key, value}]

  defp maybe_put_tuple(opts, nil), do: opts
  defp maybe_put_tuple(opts, tuple), do: opts ++ [tuple]

  defp parse_mode(nil, default, _allowed), do: default
  defp parse_mode(value, _default, _allowed) when is_atom(value), do: value

  defp parse_mode(value, default, allowed) when is_binary(value) do
    normalized = value |> String.trim() |> String.downcase()

    cond do
      normalized == "always" and Enum.member?(allowed, :always) -> :always
      normalized == "never" and Enum.member?(allowed, :never) -> :never
      normalized == "if_available" and Enum.member?(allowed, :if_available) -> :if_available
      true -> default
    end
  end

  defp parse_mode(_value, default, _allowed), do: default

  defp default_auth_mode(username, password) when is_binary(username) and is_binary(password),
    do: :if_available

  defp default_auth_mode(_username, _password), do: :never

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

  defp parse_tls_version(_version), do: :"tlsv1.2"

  defp default_port_for_ssl(true), do: 465
  defp default_port_for_ssl(false), do: 587

  defp int_value(value, _default) when is_integer(value) and value > 0, do: value

  defp int_value(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, _rest} when n > 0 -> n
      _ -> default
    end
  end

  defp int_value(_value, default), do: default

  defp truthy?(value) when is_boolean(value), do: value
  defp truthy?(value) when is_integer(value), do: value != 0

  defp truthy?(value) when is_binary(value),
    do: String.downcase(String.trim(value)) in ["1", "true", "yes", "on"]

  defp truthy?(_value), do: false
end
