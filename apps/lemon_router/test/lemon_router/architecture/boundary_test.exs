defmodule LemonRouter.Architecture.BoundaryTest do
  @moduledoc """
  Tripwire tests that detect forbidden LemonChannels module references and
  Telegram-specific state keys leaked into lemon_router source files.

  These violations currently exist and are tracked as a known baseline count.
  The test fails only if NEW violations are introduced, preventing further drift.

  Once ARCH-011, ARCH-012, and ARCH-013 are completed (moving these references
  behind proper abstractions), the known counts should be reduced to zero and
  the @moduletag removed so the test enforces a clean boundary.
  """

  use ExUnit.Case, async: true

  @moduletag :skip_until_arch_cleanup

  @router_lib_root Path.expand("../../../lib", __DIR__)

  # ── Forbidden module-reference patterns ────────────────────────────────
  #
  # These LemonChannels modules should NOT be referenced directly from
  # lemon_router. They represent implementation details that belong behind
  # a channel-adapter abstraction.

  @forbidden_module_patterns [
    {~r/LemonChannels\.OutboundPayload/, "LemonChannels.OutboundPayload"},
    {~r/LemonChannels\.Telegram(?:\.\w+)*/, "LemonChannels.Telegram.*"},
    {~r/LemonChannels\.EngineRegistry/, "LemonChannels.EngineRegistry"},
    {~r/LemonChannels\.GatewayConfig/, "LemonChannels.GatewayConfig"}
  ]

  # ── Forbidden state-key patterns ───────────────────────────────────────
  #
  # Telegram-specific Store keys that leak channel-specific state into the
  # router layer.

  @forbidden_state_key_patterns [
    {~r/:telegram_pending_compaction\b/, ":telegram_pending_compaction"},
    {~r/:telegram_msg_resume\b/, ":telegram_msg_resume"},
    {~r/:telegram_selected_resume\b/, ":telegram_selected_resume"},
    {~r/:telegram_msg_session\b/, ":telegram_msg_session"}
  ]

  # ── Known violation baseline ───────────────────────────────────────────
  #
  # This is the count of currently-known violations as of the time this
  # tripwire was added. If cleanup reduces violations, lower this number.
  # If new code adds violations, the test will fail — that is the point.

  @known_module_violation_count 19
  @known_state_key_violation_count 0

  describe "forbidden LemonChannels module references" do
    test "no new violations beyond the known baseline" do
      violations = scan_for_violations(@forbidden_module_patterns)
      count = length(violations)

      if count > @known_module_violation_count do
        violation_report =
          violations
          |> Enum.map(fn {file, line_no, line, label} ->
            "  #{Path.relative_to(file, @router_lib_root)}:#{line_no} [#{label}] #{String.trim(line)}"
          end)
          |> Enum.join("\n")

        flunk("""
        Found #{count} forbidden module references (known baseline: #{@known_module_violation_count}).
        New violations have been introduced — do not add more LemonChannels coupling to lemon_router.

        All violations:
        #{violation_report}
        """)
      end

      # If cleanup reduced violations, prompt the developer to lower the baseline.
      if count < @known_module_violation_count do
        IO.puts("""

        [ARCH-003 tripwire] Forbidden module reference count dropped from \
        #{@known_module_violation_count} to #{count}. \
        Update @known_module_violation_count in #{__ENV__.file} to lock in the improvement.
        """)
      end
    end
  end

  describe "forbidden Telegram state keys" do
    test "no new violations beyond the known baseline" do
      violations = scan_for_violations(@forbidden_state_key_patterns)
      count = length(violations)

      if count > @known_state_key_violation_count do
        violation_report =
          violations
          |> Enum.map(fn {file, line_no, line, label} ->
            "  #{Path.relative_to(file, @router_lib_root)}:#{line_no} [#{label}] #{String.trim(line)}"
          end)
          |> Enum.join("\n")

        flunk("""
        Found #{count} forbidden state-key references (known baseline: #{@known_state_key_violation_count}).
        New violations have been introduced — do not leak more Telegram state keys into lemon_router.

        All violations:
        #{violation_report}
        """)
      end

      if count < @known_state_key_violation_count do
        IO.puts("""

        [ARCH-003 tripwire] Forbidden state-key count dropped from \
        #{@known_state_key_violation_count} to #{count}. \
        Update @known_state_key_violation_count in #{__ENV__.file} to lock in the improvement.
        """)
      end
    end
  end

  describe "violation details" do
    test "all violations are accounted for with file and line info" do
      all_patterns = @forbidden_module_patterns ++ @forbidden_state_key_patterns
      violations = scan_for_violations(all_patterns)

      # Every violation must have a non-nil file path and a positive line number
      for {file, line_no, _line, _label} <- violations do
        assert is_binary(file) and file != "", "violation missing file path"
        assert is_integer(line_no) and line_no > 0, "violation missing line number in #{file}"
      end
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp scan_for_violations(patterns) do
    @router_lib_root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.flat_map(fn file ->
      file
      |> File.read!()
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, line_no} ->
        Enum.flat_map(patterns, fn {regex, label} ->
          if Regex.match?(regex, line) do
            [{file, line_no, line, label}]
          else
            []
          end
        end)
      end)
    end)
  end
end
