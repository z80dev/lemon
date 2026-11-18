defmodule LemonBrowser.TernEvaluateGuardTest do
  # Executes the real Tern evaluate function (`TernSession.evaluate_script/0`)
  # in a JavaScript engine: its source compiled on its own in the document's
  # global scope and called with the model's expression as its argument. The
  # document that runs it is not http(s)/about, as after a navigation between
  # the caller's probe and execution. This harness compiles the guard directly,
  # so it covers the guard body; a page that runs its own script and replaces
  # `eval` before Tern compiles the guard is out of scope (credential files
  # run no script).
  use ExUnit.Case, async: true

  alias LemonBrowser.TernSession

  @runner ~S"""
  const vm = require('node:vm');
  const script = process.argv[1];
  const cases = JSON.parse(process.argv[2]);
  const results = cases.map((c) => {
    const leaked = [];
    const ctx = {
      location: { protocol: c.protocol },
      document: { body: { innerText: 'credential bytes' } },
      leak: (value) => leaked.push(String(value)),
      lemonArgument: c.src,
    };
    if (c.replaceEval) ctx.eval = () => leaked.push('replaced eval');
    if (c.replaceError) ctx.Error = function () { leaked.push('replaced Error'); };
    let value = null;
    let error = null;
    try {
      value = vm.runInNewContext('(' + script + ')(lemonArgument)', ctx);
    } catch (e) {
      error = String(e && e.message ? e.message : e);
    }
    return { value, error, leaked };
  });
  process.stdout.write(JSON.stringify(results));
  """

  # Node.js is a documented development requirement (browser client, docs).
  test "hoisted declarations in the expression cannot reach the guard" do
    node = System.find_executable("node") || flunk("node is required to execute the guard")

    hostile = [
      "leak(document.body.innerText); function location() {}",
      "function Error() { leak('error constructor'); } leak(document.body.innerText)",
      "leak(document.body.innerText); var location = { protocol: 'https:' }",
      # The old concatenation escape is now just a syntax error inside eval,
      # which the guard never reaches on a refused document.
      "document.body.innerText); function location() {} return (0"
    ]

    cases =
      for(
        protocol <- ["file:", "data:", "blob:", "chrome-extension:", "view-source:"],
        src <- hostile,
        do: %{protocol: protocol, src: src}
      ) ++
        [
          # Guard body only: the body never calls a page-replaced eval or Error.
          %{protocol: "file:", src: "1", replaceEval: true, replaceError: true},
          %{protocol: "https:", src: "const x = 2; x * 3"},
          %{protocol: "http:", src: "document.body.innerText"},
          %{protocol: "about:", src: "1 + 1"}
        ]

    {output, 0} =
      System.cmd(node, ["-e", @runner, TernSession.evaluate_script(), Jason.encode!(cases)])

    results = Jason.decode!(output)
    {refused, allowed} = Enum.split(results, length(cases) - 3)

    for {result, input} <- Enum.zip(refused, cases) do
      assert result["value"] == %{"__lemon_refused" => true},
             "#{inspect(input)}: #{inspect(result)}"

      assert result["leaked"] == [], "#{inspect(input)} ran page code: #{inspect(result)}"
      assert result["error"] == nil
    end

    assert [%{"value" => 6}, %{"value" => "credential bytes"}, %{"value" => 2}] = allowed
    refute TernSession.evaluate_script() =~ ~r/\bnew\b|Error|globalThis/
  end
end
