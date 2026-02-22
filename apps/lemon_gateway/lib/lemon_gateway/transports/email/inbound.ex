defmodule LemonGateway.Transports.Email.Inbound do
  @moduledoc """
  HTTP webhook server that receives inbound emails, parses both raw RFC 2822
  and structured JSON payloads, persists attachments, resolves email threads,
  and submits prompts to the LemonGateway runtime.
  """

  use Plug.Router

  require Logger

  alias LemonGateway.{BindingResolver, Runtime, Store}
  alias LemonGateway.Transports.Email
  alias LemonGateway.Types.{ChatScope, Job}

  @default_port 4045
  @default_path "/webhooks/email/inbound"
  @attachments_dir "lemon_gateway_email_attachments"
  @default_max_attachment_bytes 10 * 1024 * 1024
  @message_thread_table :email_message_threads
  @thread_state_table :email_thread_state
  @max_references 25

  plug(Plug.Logger, log: :debug)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(:match)
  plug(:dispatch)

  def start_link(opts \\ []) do
    cfg = normalize_config(Keyword.get(opts, :config))

    if webhook_enabled?(cfg) do
      if public_bind_without_token?(cfg) do
        Logger.warning(
          "email inbound webhook disabled: missing token for non-loopback bind #{inspect(bind_ip(cfg))}"
        )

        :ignore
      else
        ip = bind_ip(cfg)
        port = port(cfg)
        path = webhook_path(cfg)

        Logger.info("Starting email inbound webhook server on #{inspect(ip)}:#{port}#{path}")

        Bandit.start_link(
          plug: __MODULE__,
          ip: ip,
          port: port,
          scheme: :http
        )
      end
    else
      Logger.info("email inbound webhook server disabled")
      :ignore
    end
  end

  post _ do
    cfg = config()

    cond do
      conn.request_path != webhook_path(cfg) ->
        send_resp(conn, 404, "not found")

      not authorized?(conn, conn.params || %{}, cfg) ->
        send_resp(conn, 401, "unauthorized")

      true ->
        case ingest(conn.params || %{}, cfg) do
          {:ok, _meta} ->
            send_resp(conn, 202, "accepted")

          {:error, reason} ->
            Logger.warning("email inbound payload rejected: #{inspect(reason)}")
            send_resp(conn, 400, "invalid payload")
        end
    end
  end

  get _ do
    cfg = config()

    if conn.request_path == webhook_path(cfg) do
      send_resp(conn, 200, "ok")
    else
      send_resp(conn, 404, "not found")
    end
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  @spec ingest(map(), map()) :: {:ok, map()} | {:error, term()}
  def ingest(params, cfg) when is_map(params) and is_map(cfg) do
    parsed = parse_email_payload(params)
    from = normalize_address(parsed.from)

    if is_nil(from) do
      {:error, :missing_from}
    else
      to = normalize_address_list(parsed.to)
      subject = normalize_blank(parsed.subject) || "(no subject)"
      text = normalize_blank(parsed.text)
      html = normalize_blank(parsed.html)
      message_id = normalize_message_id(parsed.message_id)
      in_reply_to = normalize_message_id(parsed.in_reply_to)
      references = normalize_reference_ids(parsed.references)
      persisted_attachments = persist_attachments(parsed.attachments || [])

      email = %{
        from: from,
        to: to,
        subject: subject,
        text: text,
        html: html,
        message_id: message_id,
        in_reply_to: in_reply_to,
        references: references,
        attachments: persisted_attachments
      }

      thread_id = resolve_thread_id(email)
      sender_hash = stable_hash(from, 24)
      session_key = "email:#{sender_hash}:#{thread_id}"
      thread_state = persist_thread_state(thread_id, message_id, references)
      combined_refs = merge_reference_ids([thread_state["references"], references, [message_id]])

      if is_binary(message_id) do
        persist_message_thread(message_id, thread_id)
      end

      scope = %ChatScope{transport: :email, chat_id: sender_hash, topic_id: nil}

      base_body =
        case primary_body(email) do
          nil -> subject
          value -> value
        end

      {engine_hint, stripped_body} = LemonGateway.EngineDirective.strip(base_body)

      prompt = build_prompt(email, stripped_body)

      reply_meta = %{
        to: from,
        from_hint: List.first(to),
        subject: reply_subject(subject),
        in_reply_to: message_id || in_reply_to,
        references: combined_refs,
        thread_id: thread_id,
        sender_hash: sender_hash,
        reply_to: normalize_blank(email_cfg(cfg, :reply_to))
      }

      meta = %{
        notify_pid: Process.whereis(LemonGateway.Transports.Email),
        origin: :email,
        email: %{
          from: from,
          to: to,
          subject: subject,
          message_id: message_id,
          in_reply_to: in_reply_to,
          references: references,
          attachments: persisted_attachments,
          thread_id: thread_id,
          session_key: session_key
        },
        email_reply: reply_meta
      }

      job = %Job{
        session_key: session_key,
        prompt: prompt,
        engine_id: BindingResolver.resolve_engine(scope, engine_hint, nil),
        cwd: BindingResolver.resolve_cwd(scope),
        queue_mode: BindingResolver.resolve_queue_mode(scope) || :collect,
        meta: meta
      }

      Runtime.submit(job)

      {:ok,
       %{
         session_key: session_key,
         thread_id: thread_id,
         message_id: message_id
       }}
    end
  rescue
    error ->
      {:error, {:exception, Exception.message(error)}}
  end

  def ingest(_params, _cfg), do: {:error, :invalid_payload}

  defp parse_email_payload(params) when is_map(params) do
    raw =
      params
      |> fetch_any([["raw"], ["mime"], ["rfc822"], ["message"]])
      |> normalize_blank()

    if is_binary(raw) do
      parse_raw_email(raw, params)
    else
      parse_structured_email(params)
    end
  end

  defp parse_raw_email(raw, params) when is_binary(raw) do
    parsed = Mail.parse(normalize_rfc2822(raw))

    %{
      from: Mail.get_from(parsed),
      to: Mail.get_to(parsed),
      subject: Mail.get_subject(parsed) || fetch_any(params, [["subject"]]),
      text: parsed |> Mail.get_text() |> part_body(),
      html: parsed |> Mail.get_html() |> part_body(),
      message_id:
        Mail.Message.get_header(parsed, "message-id") || fetch_any(params, [["message-id"]]),
      in_reply_to:
        Mail.Message.get_header(parsed, "in-reply-to") || fetch_any(params, [["in-reply-to"]]),
      references:
        Mail.Message.get_header(parsed, "references") || fetch_any(params, [["references"]]),
      attachments: parse_mail_attachments(parsed)
    }
  rescue
    _ ->
      parse_structured_email(params)
  end

  defp parse_structured_email(params) when is_map(params) do
    %{
      from: fetch_any(params, [["from"], ["sender"], ["mail_from"]]),
      to: fetch_any(params, [["to"], ["recipient"], ["mail_to"]]),
      subject: fetch_any(params, [["subject"]]),
      text:
        first_non_blank([
          fetch_any(params, [["text"], ["plain"], ["text/plain"], ["text_body"], ["body", "text"]]),
          fetch_any(params, [["body", "plain"], ["content", "text"]])
        ]),
      html:
        first_non_blank([
          fetch_any(params, [["html"], ["text/html"], ["html_body"], ["body", "html"]]),
          fetch_any(params, [["content", "html"]])
        ]),
      message_id:
        fetch_any(params, [
          ["message-id"],
          ["message_id"],
          ["Message-Id"],
          ["headers", "message-id"]
        ]),
      in_reply_to:
        fetch_any(params, [
          ["in-reply-to"],
          ["in_reply_to"],
          ["headers", "in-reply-to"]
        ]),
      references: fetch_any(params, [["references"], ["headers", "references"]]),
      attachments: parse_structured_attachments(params)
    }
  end

  defp parse_mail_attachments(%Mail.Message{} = message) do
    Mail.get_attachments(message, :all)
    |> Enum.map(fn {filename, data} ->
      %{
        filename: sanitize_filename(filename),
        content_type: nil,
        data: to_binary(data),
        source: :raw
      }
    end)
  end

  defp parse_structured_attachments(params) when is_map(params) do
    value = fetch_any(params, [["attachments"], ["files"], ["attachment"]])

    cond do
      is_list(value) ->
        Enum.map(value, &normalize_structured_attachment/1)

      is_map(value) ->
        value
        |> Map.values()
        |> Enum.map(&normalize_structured_attachment/1)

      true ->
        []
    end
  end

  defp normalize_structured_attachment(%Plug.Upload{} = upload) do
    %{
      filename: sanitize_filename(upload.filename),
      content_type: normalize_blank(upload.content_type),
      data: nil,
      upload: upload,
      url: nil,
      source: :upload
    }
  end

  defp normalize_structured_attachment(%{} = attachment) do
    upload =
      fetch_any(attachment, [["upload"], ["file"], ["attachment"]])
      |> case do
        %Plug.Upload{} = value -> value
        _ -> nil
      end

    raw_data =
      fetch_any(attachment, [
        ["content"],
        ["data"],
        ["content_base64"],
        ["base64"],
        ["body"]
      ])

    url = fetch_any(attachment, [["url"], ["href"]]) |> normalize_blank()
    encoding = fetch_any(attachment, [["encoding"], ["content_transfer_encoding"]])

    %{
      filename:
        attachment
        |> fetch_any([["filename"], ["name"], ["file_name"]])
        |> normalize_blank()
        |> case do
          nil when is_struct(upload, Plug.Upload) -> sanitize_filename(upload.filename)
          value -> filename_or_default(value, url)
        end,
      content_type: fetch_any(attachment, [["content_type"], ["mime_type"], ["type"]]),
      data: decode_attachment_data(raw_data, encoding),
      upload: upload,
      url: url,
      source: :structured
    }
  end

  defp normalize_structured_attachment(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        %{}

      String.starts_with?(value, "http://") or String.starts_with?(value, "https://") ->
        %{
          filename: "attachment",
          content_type: nil,
          data: nil,
          upload: nil,
          url: value,
          source: :structured
        }

      true ->
        %{}
    end
  end

  defp normalize_structured_attachment(_), do: %{}

  defp persist_attachments(attachments) when is_list(attachments) do
    attachments
    |> Enum.map(&persist_attachment/1)
    |> Enum.reject(&is_nil/1)
  end

  defp persist_attachments(_), do: []

  defp persist_attachment(%{} = attachment) do
    filename = sanitize_filename(attachment[:filename] || "attachment.bin")
    content_type = normalize_blank(attachment[:content_type])
    source = attachment[:source] || :structured

    cond do
      match?(%Plug.Upload{}, attachment[:upload]) ->
        with {:ok, dir} <- ensure_attachment_dir(),
             {:ok, path, bytes} <- copy_upload_file(dir, filename, attachment[:upload]) do
          %{
            filename: filename,
            content_type: content_type,
            path: path,
            url: normalize_blank(attachment[:url]),
            bytes: bytes,
            source: source
          }
        else
          {:error, :attachment_too_large} ->
            Logger.warning("email inbound attachment dropped: upload exceeds size cap")
            nil

          _ ->
            nil
        end

      is_binary(attachment[:data]) and attachment[:data] != "" ->
        with {:ok, dir} <- ensure_attachment_dir(),
             {:ok, path} <- write_attachment_file(dir, filename, attachment[:data]) do
          %{
            filename: filename,
            content_type: content_type,
            path: path,
            url: normalize_blank(attachment[:url]),
            bytes: byte_size(attachment[:data]),
            source: source
          }
        else
          {:error, :attachment_too_large} ->
            Logger.warning("email inbound attachment dropped: decoded data exceeds size cap")
            nil

          _ ->
            nil
        end

      is_binary(attachment[:url]) and attachment[:url] != "" ->
        %{
          filename: filename,
          content_type: content_type,
          path: nil,
          url: attachment[:url],
          bytes: nil,
          source: source
        }

      true ->
        nil
    end
  end

  defp persist_attachment(_), do: nil

  defp write_attachment_file(dir, filename, data) when is_binary(data) do
    if byte_size(data) > max_attachment_bytes() do
      {:error, :attachment_too_large}
    else
      unique = "#{System.system_time(:millisecond)}_#{System.unique_integer([:positive])}"
      target = Path.join(dir, "#{unique}_#{filename}")

      case File.write(target, data) do
        :ok ->
          maybe_restrict_file_permissions(target)
          {:ok, target}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp copy_upload_file(dir, filename, %Plug.Upload{} = upload) do
    source = normalize_blank(upload.path)

    with true <- is_binary(source),
         {:ok, stat} <- File.stat(source),
         true <- stat.size <= max_attachment_bytes() || {:error, :attachment_too_large} do
      unique = "#{System.system_time(:millisecond)}_#{System.unique_integer([:positive])}"
      target = Path.join(dir, "#{unique}_#{filename}")

      case File.cp(source, target) do
        :ok ->
          maybe_restrict_file_permissions(target)
          {:ok, target, stat.size}

        {:error, reason} ->
          {:error, reason}
      end
    else
      false -> {:error, :invalid_upload_path}
      {:error, _} = error -> error
    end
  end

  defp ensure_attachment_dir do
    dir = Path.join(System.tmp_dir!(), @attachments_dir)

    case File.mkdir_p(dir) do
      :ok -> {:ok, dir}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_prompt(email, body_text) do
    header_lines = [
      "Inbound email:",
      "From: #{email.from}",
      "To: #{Enum.join(email.to || [], ", ")}",
      "Subject: #{email.subject}"
    ]

    header_lines =
      maybe_append(header_lines, "Message-ID: #{email.message_id}", is_binary(email.message_id))
      |> maybe_append("In-Reply-To: #{email.in_reply_to}", is_binary(email.in_reply_to))

    references_line =
      case email.references do
        refs when is_list(refs) and refs != [] ->
          "References: " <> Enum.map_join(refs, " ", &format_message_id/1)

        _ ->
          nil
      end

    header_lines =
      if is_binary(references_line) do
        header_lines ++ [references_line]
      else
        header_lines
      end

    attachment_lines =
      case email.attachments do
        [] ->
          ["Attachments: none"]

        list ->
          ["Attachments:" | Enum.map(list, &attachment_context_line/1)]
      end

    body =
      body_text
      |> normalize_blank()
      |> case do
        nil ->
          email.html
          |> html_to_text()
          |> normalize_blank()
          |> Kernel.||("(no body)")

        value ->
          value
      end

    (header_lines ++ [""] ++ attachment_lines ++ ["", "Body:", body])
    |> Enum.join("\n")
    |> String.trim()
  end

  defp attachment_context_line(%{} = attachment) do
    name = attachment[:filename] || "attachment"
    type = attachment[:content_type] || "application/octet-stream"
    bytes = attachment[:bytes]
    location = attachment[:path] || attachment[:url] || "(unavailable)"

    size_text =
      if is_integer(bytes) do
        "#{bytes} bytes"
      else
        "size unknown"
      end

    "- #{name} (#{type}, #{size_text}) at #{location}"
  end

  defp primary_body(email) do
    first_non_blank([email.text, html_to_text(email.html), email.subject])
  end

  defp resolve_thread_id(email) do
    references = merge_reference_ids([[email.in_reply_to], email.references])

    resolved =
      references
      |> Enum.find_value(&lookup_thread_id/1)
      |> case do
        nil -> lookup_thread_id(email.message_id)
        thread_id -> thread_id
      end

    cond do
      is_binary(resolved) ->
        resolved

      is_binary(email.in_reply_to) ->
        "thr_" <> stable_hash(email.in_reply_to, 24)

      references != [] ->
        "thr_" <> stable_hash(List.last(references), 24)

      is_binary(email.message_id) ->
        "thr_" <> stable_hash(email.message_id, 24)

      true ->
        subject_seed = canonical_subject(email.subject)
        sender_seed = normalize_blank(email.from) || "(unknown-sender)"
        "thr_" <> stable_hash("#{subject_seed}|#{sender_seed}", 24)
    end
  end

  defp lookup_thread_id(message_id) when is_binary(message_id) do
    case Store.get(@message_thread_table, message_id) do
      %{"thread_id" => thread_id} when is_binary(thread_id) and thread_id != "" -> thread_id
      %{thread_id: thread_id} when is_binary(thread_id) and thread_id != "" -> thread_id
      thread_id when is_binary(thread_id) and thread_id != "" -> thread_id
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp lookup_thread_id(_), do: nil

  defp persist_message_thread(message_id, thread_id)
       when is_binary(message_id) and is_binary(thread_id) do
    Store.put(@message_thread_table, message_id, %{
      "thread_id" => thread_id,
      "updated_at_ms" => System.system_time(:millisecond)
    })
  rescue
    _ -> :ok
  end

  defp persist_message_thread(_, _), do: :ok

  defp persist_thread_state(thread_id, message_id, references) when is_binary(thread_id) do
    existing =
      case Store.get(@thread_state_table, thread_id) do
        %{} = map -> map
        _ -> %{}
      end

    merged_refs =
      merge_reference_ids([
        existing[:references] || existing["references"],
        references,
        [message_id]
      ])

    state = %{
      "thread_id" => thread_id,
      "references" => merged_refs,
      "last_message_id" => message_id,
      "updated_at_ms" => System.system_time(:millisecond)
    }

    _ = Store.put(@thread_state_table, thread_id, state)
    state
  rescue
    _ ->
      %{
        "thread_id" => thread_id,
        "references" => merge_reference_ids([references, [message_id]])
      }
  end

  defp merge_reference_ids(reference_sets) when is_list(reference_sets) do
    reference_sets
    |> Enum.flat_map(&normalize_reference_ids/1)
    |> Enum.uniq()
    |> Enum.take(-@max_references)
  end

  defp normalize_reference_ids(value) when is_list(value) do
    value
    |> Enum.flat_map(&normalize_reference_ids/1)
    |> Enum.reject(&is_nil/1)
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

      _ ->
        refs
    end
  end

  defp normalize_reference_ids(value) do
    case normalize_message_id(value) do
      nil -> []
      id -> [id]
    end
  end

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

  defp normalize_address_list(nil), do: []

  defp normalize_address_list(value) when is_list(value) do
    value
    |> Enum.flat_map(&normalize_address_list/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_address_list(value) when is_binary(value) do
    parsed =
      try do
        Mail.Parsers.RFC2822.parse_recipient_value(value)
      rescue
        _ -> []
      end

    list =
      case parsed do
        [] -> [value]
        _ -> parsed
      end

    list
    |> Enum.map(&normalize_address/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_address_list(value), do: normalize_address_list([value])

  defp normalize_address(nil), do: nil

  defp normalize_address({_, email}) when is_binary(email), do: normalize_address(email)

  defp normalize_address(%{} = map) do
    map
    |> fetch_any([["email"], ["address"], ["value"]])
    |> normalize_address()
  end

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

  defp decode_attachment_data(nil, _encoding), do: nil

  defp decode_attachment_data(data, encoding) when is_binary(data) do
    data = String.trim(data)

    cond do
      data == "" ->
        nil

      base64_encoding?(encoding) ->
        decode_base64(data)

      likely_base64?(data) ->
        decode_base64(data) || size_cap_binary(data)

      true ->
        size_cap_binary(data)
    end
  end

  defp decode_attachment_data(data, _encoding), do: data |> to_binary() |> size_cap_binary()

  defp decode_base64(data) when is_binary(data) do
    if byte_size(data) <= max_base64_input_bytes() do
      case Base.decode64(data) do
        {:ok, decoded} -> size_cap_binary(decoded)
        :error -> nil
      end
    else
      nil
    end
  end

  defp likely_base64?(value) when is_binary(value) do
    byte_size(value) > 20 and Regex.match?(~r/\A[A-Za-z0-9+\/=\r\n]+\z/, value)
  end

  defp base64_encoding?(encoding) when is_binary(encoding) do
    String.downcase(String.trim(encoding)) in ["base64", "b64", "mime/base64"]
  end

  defp base64_encoding?(_), do: false

  defp filename_or_default(value, url) do
    value = normalize_blank(value)

    cond do
      is_binary(value) ->
        sanitize_filename(value)

      is_binary(url) ->
        sanitize_filename(Path.basename(URI.parse(url).path || "attachment.bin"))

      true ->
        "attachment.bin"
    end
  end

  defp sanitize_filename(nil), do: "attachment.bin"

  defp sanitize_filename(name) when is_binary(name) do
    name
    |> Path.basename()
    |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
    |> case do
      "" -> "attachment.bin"
      value -> value
    end
  end

  defp stable_hash(value, length) when is_binary(value) and is_integer(length) and length > 0 do
    value
    |> String.downcase()
    |> :erlang.iolist_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, min(length, 64))
  end

  defp stable_hash(_value, _length), do: stable_hash("unknown", 16)

  defp canonical_subject(subject) do
    (normalize_blank(subject) || "(no-subject)")
    |> String.downcase()
    |> String.replace(~r/^\s*(re|fwd|fw)\s*:\s*/i, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> case do
      "" -> "(no-subject)"
      value -> value
    end
  end

  defp reply_subject(subject) when is_binary(subject) do
    if String.match?(subject, ~r/^\s*re\s*:/i) do
      subject
    else
      "Re: " <> subject
    end
  end

  defp reply_subject(_), do: "Re: (no subject)"

  defp part_body(nil), do: nil
  defp part_body(%Mail.Message{body: body}) when is_binary(body), do: body
  defp part_body(%Mail.Message{body: body}), do: to_binary(body)
  defp part_body(_), do: nil

  defp format_message_id(message_id) when is_binary(message_id), do: "<#{message_id}>"
  defp format_message_id(_), do: nil

  defp html_to_text(nil), do: nil

  defp html_to_text(value) when is_binary(value) do
    value
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(~r/<\/p>/i, "\n")
    |> String.replace(~r/<[^>]*>/, "")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
  end

  defp html_to_text(_), do: nil

  defp first_non_blank(values) when is_list(values) do
    Enum.find_value(values, fn value ->
      case normalize_blank(value) do
        nil -> nil
        non_blank -> non_blank
      end
    end)
  end

  defp first_non_nil(values) when is_list(values) do
    Enum.find(values, &(not is_nil(&1)))
  end

  defp maybe_append(list, value, true), do: list ++ [value]
  defp maybe_append(list, _value, _), do: list

  defp to_binary(value) when is_binary(value), do: value
  defp to_binary(value) when is_list(value), do: IO.iodata_to_binary(value)
  defp to_binary(value), do: to_string(value)

  defp size_cap_binary(nil), do: nil

  defp size_cap_binary(value) when is_binary(value) do
    if byte_size(value) <= max_attachment_bytes(), do: value, else: nil
  end

  defp normalize_rfc2822(raw) when is_binary(raw) do
    raw
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
    |> String.split("\n")
    |> Enum.join("\r\n")
  end

  defp webhook_enabled?(cfg) do
    value =
      first_non_nil([
        email_cfg(cfg, :inbound_enabled),
        email_cfg(cfg, :webhook_enabled),
        email_cfg(cfg, [:inbound, :enabled])
      ])

    case value do
      nil -> true
      v -> truthy?(v)
    end
  end

  defp authorized?(conn, params, cfg) do
    expected = webhook_token(cfg)

    if is_nil(expected) do
      true
    else
      provided =
        first_non_blank([
          authorization_token(conn),
          List.first(Plug.Conn.get_req_header(conn, "x-webhook-token")),
          fetch_any(params, [["token"], ["webhook_token"]])
        ])

      secure_compare(expected, provided)
    end
  end

  defp authorization_token(conn) do
    conn
    |> Plug.Conn.get_req_header("authorization")
    |> List.first()
    |> normalize_blank()
    |> case do
      nil ->
        nil

      "Bearer " <> token ->
        normalize_blank(token)

      "bearer " <> token ->
        normalize_blank(token)

      token ->
        normalize_blank(token)
    end
  end

  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    Plug.Crypto.secure_compare(a, b)
  rescue
    _ -> false
  end

  defp secure_compare(_, _), do: false

  defp port(cfg) do
    cfg
    |> email_cfg([:inbound, :port])
    |> case do
      nil -> email_cfg(cfg, :webhook_port)
      value -> value
    end
    |> int_value(@default_port)
  end

  defp webhook_path(cfg) do
    path =
      email_cfg(cfg, [:inbound, :path]) ||
        email_cfg(cfg, :webhook_path) ||
        @default_path

    normalize_path(path)
  end

  defp bind_ip(cfg) do
    bind =
      email_cfg(cfg, [:inbound, :bind]) ||
        email_cfg(cfg, :webhook_bind)

    case normalize_blank(bind) do
      nil -> :loopback
      "127.0.0.1" -> :loopback
      "localhost" -> :loopback
      "0.0.0.0" -> :any
      "any" -> :any
      other -> parse_ip(other) || :loopback
    end
  end

  defp webhook_token(cfg) when is_map(cfg) do
    cfg
    |> email_cfg([:inbound, :token])
    |> normalize_blank()
    |> case do
      nil ->
        cfg
        |> email_cfg(:webhook_token)
        |> normalize_blank()

      value ->
        value
    end
  end

  defp webhook_token(_), do: nil

  defp public_bind_without_token?(cfg) when is_map(cfg) do
    is_nil(webhook_token(cfg)) and not loopback_bind?(bind_ip(cfg))
  end

  defp public_bind_without_token?(_), do: false

  defp loopback_bind?(:loopback), do: true
  defp loopback_bind?({127, _b, _c, _d}), do: true
  defp loopback_bind?(_), do: false

  defp config do
    Email.config()
  rescue
    _ -> %{}
  end

  defp normalize_config(nil), do: config()

  defp normalize_config(cfg) when is_list(cfg) do
    cfg
    |> Enum.into(%{})
    |> normalize_config()
  end

  defp normalize_config(cfg) when is_map(cfg), do: cfg
  defp normalize_config(_), do: %{}

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

  defp fetch_any(map, paths) when is_map(map) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      case path do
        [single] ->
          fetch_any(map, single)

        list when is_list(list) ->
          fetch_path(map, list)

        key ->
          fetch_key(map, key)
      end
    end)
  end

  defp fetch_any(map, key) when is_map(map) do
    fetch_key(map, key)
  end

  defp fetch_any(_, _), do: nil

  defp fetch_path(value, []), do: value

  defp fetch_path(map, [head | tail]) when is_map(map) do
    next = fetch_key(map, head)

    case tail do
      [] -> next
      _ when is_map(next) -> fetch_path(next, tail)
      _ -> nil
    end
  end

  defp fetch_path(_, _), do: nil

  defp fetch_key(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Map.get(map, to_string(key))
    end
  end

  defp truthy?(value) when is_boolean(value), do: value
  defp truthy?(value) when is_integer(value), do: value != 0

  defp truthy?(value) when is_binary(value) do
    String.downcase(String.trim(value)) in ["1", "true", "yes", "on"]
  end

  defp truthy?(_), do: false

  defp int_value(value, _default) when is_integer(value) and value >= 0, do: value

  defp int_value(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, _} when n >= 0 -> n
      _ -> default
    end
  end

  defp int_value(_, default), do: default

  defp max_attachment_bytes do
    case Application.get_env(:lemon_gateway, :email_attachment_max_bytes) do
      value when is_integer(value) and value > 0 ->
        value

      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {n, _} when n > 0 -> n
          _ -> @default_max_attachment_bytes
        end

      _ ->
        @default_max_attachment_bytes
    end
  end

  defp max_base64_input_bytes do
    max_attachment_bytes()
    |> Kernel.*(4)
    |> div(3)
    |> Kernel.+(8)
  end

  defp normalize_blank(nil), do: nil

  defp normalize_blank(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp normalize_blank(_), do: nil

  defp normalize_path(path) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      trimmed == "" -> @default_path
      String.starts_with?(trimmed, "/") -> trimmed
      true -> "/" <> trimmed
    end
  end

  defp normalize_path(_), do: @default_path

  defp maybe_restrict_file_permissions(path) when is_binary(path) do
    # Best-effort hardening for persisted attachment copies on Unix systems.
    if match?({:unix, _}, :os.type()) do
      _ = File.chmod(path, 0o600)
    end

    :ok
  end

  defp parse_ip(str) when is_binary(str) do
    case String.split(str, ".", parts: 8) do
      [a, b, c, d] ->
        with {a, ""} <- Integer.parse(a),
             {b, ""} <- Integer.parse(b),
             {c, ""} <- Integer.parse(c),
             {d, ""} <- Integer.parse(d),
             true <- Enum.all?([a, b, c, d], &(&1 >= 0 and &1 <= 255)) do
          {a, b, c, d}
        else
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_ip(_), do: nil
end
