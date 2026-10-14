"use strict";
// Lemon `eval` tool kernel: one persistent JavaScript realm driven over stdio.
// Runs under Bun or Node (CommonJS, no dependencies).
//
// Protocol (owned by CodingAgent.Eval.Kernel):
// * Commands arrive on stdin, one JSON object per line:
//   {"op": "execute", "id": <int>, "code": <string>}. A worker thread owns
//   stdin so that EOF (the host went away) kills the kernel even while a cell
//   is stuck in a synchronous loop.
// * User output goes to the real stdout/stderr (merged by the host). Console
//   and process.stdout/stderr writes are synchronous so they stay ordered with
//   protocol frames.
// * Protocol frames are single stdout lines prefixed with
//   "\x1eLEMONEVAL:<token>:"; the token comes from LEMON_EVAL_TOKEN and is
//   removed from the environment before user code runs. Unframed bytes are
//   user output, so user code cannot corrupt the protocol.
//
// Cells run through indirect eval inside an async wrapper so top-level
// `await` works. Top-level `const`/`let`/`var`/`class`/`function` and static
// `import` declarations are rewritten to global bindings so they persist
// across cells (and may be re-declared), and the trailing expression's value
// is returned and displayed with util.inspect.

const fs = require("node:fs");
const path = require("node:path");
const util = require("node:util");
const { Console } = require("node:console");
const { Writable } = require("node:stream");
const { Worker } = require("node:worker_threads");
const { createRequire } = require("node:module");
const { pathToFileURL } = require("node:url");

const TOKEN = process.env.LEMON_EVAL_TOKEN || "";
delete process.env.LEMON_EVAL_TOKEN;
const MARKER = "\x1eLEMONEVAL:" + TOKEN + ":";
const MAX_DISPLAY_CHARS = 1000000;
const SLEEP_CELL = new Int32Array(new SharedArrayBuffer(4));
const AsyncFunction = (async function () {}).constructor;

// ---------------------------------------------------------------------------
// Output plumbing
// ---------------------------------------------------------------------------

function writeAll(fd, data) {
  const buffer = typeof data === "string" ? Buffer.from(data, "utf8") : Buffer.from(data);
  let offset = 0;
  while (offset < buffer.length) {
    try {
      offset += fs.writeSync(fd, buffer, offset, buffer.length - offset);
    } catch (error) {
      if (error && error.code === "EAGAIN") {
        Atomics.wait(SLEEP_CELL, 0, 0, 2);
        continue;
      }
      throw error;
    }
  }
}

function patchStreamWrite(stream, fd) {
  stream.write = function (chunk, encoding, callback) {
    if (typeof encoding === "function") callback = encoding;
    if (typeof chunk === "string" || chunk instanceof Uint8Array) {
      writeAll(fd, typeof chunk === "string" ? chunk : Buffer.from(chunk));
    } else if (chunk !== undefined && chunk !== null) {
      writeAll(fd, String(chunk));
    }
    if (typeof callback === "function") callback();
    return true;
  };
}

patchStreamWrite(process.stdout, 1);
patchStreamWrite(process.stderr, 2);

function fdWritable(fd) {
  return new Writable({
    decodeStrings: false,
    write(chunk, _encoding, callback) {
      writeAll(fd, chunk);
      callback();
    },
  });
}

globalThis.console = new Console({ stdout: fdWritable(1), stderr: fdWritable(2) });

function send(message) {
  writeAll(1, MARKER + JSON.stringify(message) + "\n");
}

process.on("uncaughtException", (error) => {
  writeAll(2, "Uncaught " + formatError(error) + "\n");
});
process.on("unhandledRejection", (reason) => {
  writeAll(2, "Unhandled rejection: " + formatError(reason) + "\n");
});

// ---------------------------------------------------------------------------
// Module loading relative to the kernel cwd (the session cwd)
// ---------------------------------------------------------------------------

const cwdRequire = createRequire(path.join(process.cwd(), "[lemon-eval].js"));

function lemonImport(specifier, options) {
  let target = specifier;
  if (typeof specifier === "string" && !specifier.startsWith("node:") && !/^[a-z]+:/i.test(specifier)) {
    try {
      const resolved = cwdRequire.resolve(specifier);
      target = path.isAbsolute(resolved) ? pathToFileURL(resolved).href : resolved;
    } catch (_error) {
      target = specifier;
    }
  }
  return options === undefined ? import(target) : import(target, options);
}

Object.defineProperty(globalThis, "__lemon_import__", { value: lemonImport, writable: false });
globalThis.require = cwdRequire;

// ---------------------------------------------------------------------------
// Tokenizer (enough JavaScript to find top-level statements)
// ---------------------------------------------------------------------------

const PUNCTUATORS = [
  ">>>=", "...", "===", "!==", "**=", "<<=", ">>=", ">>>", "&&=", "||=", "??=",
  "=>", "==", "!=", "<=", ">=", "&&", "||", "??", "?.", "++", "--", "+=", "-=",
  "*=", "/=", "%=", "&=", "|=", "^=", "**", "<<", ">>",
];
const REGEX_AFTER_KEYWORDS = new Set([
  "return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw",
  "case", "do", "else", "yield", "await",
]);
const OPERAND_KEYWORDS = new Set([
  "return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw",
  "case", "yield", "await", "extends", "export", "default", "async",
]);
const UNARY_ONLY = new Set(["!", "~", "++", "--"]);
const IDENT_START = /[A-Za-z_$\u0080-\uffff\\]/;
const IDENT_PART = /[\w$\u0080-\uffff\\]/;

function tokenize(code) {
  const tokens = [];
  const stack = [];
  const n = code.length;
  let i = 0;
  let nl = false;

  const push = (type, start, end) => {
    tokens.push({ type, value: code.slice(start, end), start, end, depth: stack.length, nl });
    nl = false;
  };

  const scanTemplate = (from, start) => {
    let j = from;
    while (j < n) {
      const c = code[j];
      if (c === "\\") {
        j += 2;
      } else if (c === "`") {
        push("template", start, j + 1);
        return j + 1;
      } else if (c === "$" && code[j + 1] === "{") {
        push("template", start, j + 2);
        stack.push("${");
        return j + 2;
      } else {
        j++;
      }
    }
    push("template", start, n);
    return n;
  };

  const regexAllowed = () => {
    const prev = tokens[tokens.length - 1];
    if (!prev) return true;
    if (prev.type === "name") return REGEX_AFTER_KEYWORDS.has(prev.value);
    if (prev.type === "punct") return !(prev.value === ")" || prev.value === "]" || prev.value === "++" || prev.value === "--");
    return false;
  };

  if (code.startsWith("#!")) {
    const end = code.indexOf("\n");
    i = end < 0 ? n : end;
  }

  while (i < n) {
    const c = code[i];

    if (c === "\n" || c === "\u2028" || c === "\u2029") {
      nl = true;
      i++;
      continue;
    }
    if (c === " " || c === "\t" || c === "\r" || c === "\v" || c === "\f" || c === "\ufeff" || c === "\u00a0") {
      i++;
      continue;
    }
    if (c === "/" && code[i + 1] === "/") {
      const end = code.indexOf("\n", i);
      i = end < 0 ? n : end;
      continue;
    }
    if (c === "/" && code[i + 1] === "*") {
      const end = code.indexOf("*/", i + 2);
      const stop = end < 0 ? n : end + 2;
      if (code.slice(i, stop).includes("\n")) nl = true;
      i = stop;
      continue;
    }
    if (c === "'" || c === '"') {
      let j = i + 1;
      while (j < n && code[j] !== c && code[j] !== "\n") j += code[j] === "\\" ? 2 : 1;
      push("string", i, Math.min(j + 1, n));
      i = j + 1;
      continue;
    }
    if (c === "`") {
      i = scanTemplate(i + 1, i);
      continue;
    }
    if (IDENT_START.test(c) || (c === "#" && i + 1 < n && IDENT_START.test(code[i + 1]))) {
      let j = i + 1;
      while (j < n && IDENT_PART.test(code[j])) j += code[j] === "\\" ? 2 : 1;
      push("name", i, j);
      i = j;
      continue;
    }
    if (/[0-9]/.test(c) || (c === "." && /[0-9]/.test(code[i + 1] || ""))) {
      let j = i + 1;
      while (j < n && /[\w.]/.test(code[j])) {
        if ((code[j] === "e" || code[j] === "E") && (code[j + 1] === "+" || code[j + 1] === "-")) j++;
        j++;
      }
      push("number", i, j);
      i = j;
      continue;
    }
    if (c === "/" && regexAllowed()) {
      let j = i + 1;
      let inClass = false;
      while (j < n && code[j] !== "\n") {
        const d = code[j];
        if (d === "\\") {
          j += 2;
          continue;
        }
        if (d === "[") inClass = true;
        else if (d === "]") inClass = false;
        else if (d === "/" && !inClass) break;
        j++;
      }
      j++;
      while (j < n && IDENT_PART.test(code[j])) j++;
      push("regex", i, Math.min(j, n));
      i = j;
      continue;
    }

    if (c === "(" || c === "[" || c === "{") {
      push("punct", i, i + 1);
      stack.push(c);
      i++;
      continue;
    }
    if (c === ")" || c === "]" || c === "}") {
      if (c === "}" && stack[stack.length - 1] === "${") {
        stack.pop();
        i = scanTemplate(i + 1, i);
        continue;
      }
      stack.pop();
      push("punct", i, i + 1);
      i++;
      continue;
    }

    const punct = PUNCTUATORS.find((p) => code.startsWith(p, i)) || c;
    push("punct", i, i + punct.length);
    i += punct.length;
  }

  return tokens;
}

function isPunct(token, value) {
  return Boolean(token) && token.type === "punct" && token.value === value;
}

function isName(token, value) {
  return Boolean(token) && token.type === "name" && (value === undefined || token.value === value);
}

// Whether `prev` leaves an expression unfinished, so a following newline
// cannot end the statement.
function expectsOperand(prev) {
  if (!prev) return false;
  if (prev.type === "punct") return !(prev.value === ")" || prev.value === "]" || prev.value === "}" || prev.value === "++" || prev.value === "--");
  if (prev.type === "name") return OPERAND_KEYWORDS.has(prev.value);
  return false;
}

// Whether `token` can only continue the previous expression.
function continuesExpression(token) {
  if (token.type === "template") return true;
  if (token.type === "punct") return !UNARY_ONLY.has(token.value) && token.value !== "{";
  return token.type === "name" && (token.value === "in" || token.value === "instanceof" || token.value === "of");
}

function startsStatement(tokens, index) {
  const token = tokens[index];
  if (token.depth !== 0) return false;
  if (index === 0) return true;
  const prev = tokens[index - 1];
  if (isPunct(prev, ";") || isPunct(prev, "}")) return true;
  return token.nl && !expectsOperand(prev) && !continuesExpression(token);
}

function matchingClose(tokens, index) {
  const open = tokens[index];
  const close = open.value === "{" ? "}" : open.value === "[" ? "]" : ")";
  for (let j = index + 1; j < tokens.length; j++) {
    if (tokens[j].depth === open.depth && isPunct(tokens[j], close)) return j;
  }
  return -1;
}

// ---------------------------------------------------------------------------
// Cell rewriting
// ---------------------------------------------------------------------------

function rewriteImport(tokens, index) {
  let j = index + 1;
  let defaultName = null;
  let namespaceName = null;
  const named = [];

  if (tokens[j] && tokens[j].type !== "string") {
    if (isName(tokens[j]) && tokens[j].value !== "from") {
      if (tokens[j].value === "type") return null;
      defaultName = tokens[j].value;
      j++;
      if (isPunct(tokens[j], ",")) j++;
    }
    if (isPunct(tokens[j], "*") && isName(tokens[j + 1], "as") && isName(tokens[j + 2])) {
      namespaceName = tokens[j + 2].value;
      j += 3;
    } else if (isPunct(tokens[j], "{")) {
      const close = matchingClose(tokens, j);
      if (close < 0) return null;
      let k = j + 1;
      while (k < close) {
        if (isName(tokens[k], "type") && isName(tokens[k + 1]) && !isPunct(tokens[k + 1], ",")) return null;
        const imported = tokens[k];
        if (!imported || (imported.type !== "name" && imported.type !== "string")) return null;
        const importedName = imported.value;
        let local = imported.value;
        k++;
        if (isName(tokens[k], "as") && isName(tokens[k + 1])) {
          local = tokens[k + 1].value;
          k += 2;
        }
        named.push([importedName, local]);
        if (isPunct(tokens[k], ",")) k++;
      }
      j = close + 1;
    }
    if (!isName(tokens[j], "from")) return null;
    j++;
  }

  const source = tokens[j];
  if (!source || source.type !== "string") return null;
  let end = source.end;
  let options = "";
  if ((isName(tokens[j + 1], "with") || isName(tokens[j + 1], "assert")) && isPunct(tokens[j + 2], "{")) {
    const close = matchingClose(tokens, j + 2);
    if (close < 0) return null;
    options = ", { with: " + tokensText(tokens, j + 2, close) + " }";
    end = tokens[close].end;
  }

  const call = "await __lemon_import__(" + source.value + options + ")";
  let text;
  if (named.length > 0) {
    const parts = named.map(([imported, local]) => (imported === local ? local : imported + ": " + local));
    if (defaultName) parts.unshift("default: " + defaultName);
    text = "0, { " + parts.join(", ") + " } = " + call;
  } else if (namespaceName) {
    text = namespaceName + " = " + call + (defaultName ? ", " + defaultName + " = " + namespaceName + ".default" : "");
  } else if (defaultName) {
    text = defaultName + " = (" + call + ").default";
  } else {
    text = call;
  }
  return { start: tokens[index].start, end, text };
}

let currentSource = "";

function tokensText(tokens, from, to) {
  return currentSource.slice(tokens[from].start, tokens[to].end);
}

// `const a = 1, {b} = c; let d;` -> `      a = 1, {b} = c;     d = undefined;`
function rewriteVariableDeclaration(tokens, index, edits) {
  const keyword = tokens[index];
  const first = tokens[index + 1];
  if (!first || !(isName(first) || isPunct(first, "{") || isPunct(first, "["))) return;

  const pending = [];
  let j = index + 1;
  while (j < tokens.length) {
    const binding = tokens[j];
    let bindingIsName = false;
    if (isName(binding)) {
      bindingIsName = true;
      j++;
    } else if (isPunct(binding, "{") || isPunct(binding, "[")) {
      const close = matchingClose(tokens, j);
      if (close < 0) return;
      j = close + 1;
    } else {
      return;
    }

    if (isPunct(tokens[j], "=") && tokens[j].depth === 0) {
      j++;
      while (j < tokens.length) {
        const token = tokens[j];
        if (token.depth === 0 && (isPunct(token, ",") || isPunct(token, ";"))) break;
        if (token.depth === 0 && token.nl && !expectsOperand(tokens[j - 1]) && !continuesExpression(token) && token.type !== "punct") break;
        j++;
      }
    } else if (bindingIsName) {
      pending.push({ start: binding.end, end: binding.end, text: " = undefined" });
    } else {
      return;
    }

    if (isPunct(tokens[j], ",") && tokens[j].depth === 0) {
      j++;
      continue;
    }
    break;
  }

  const replacement = isName(first) ? "" : "0,";
  edits.push({ start: keyword.start, end: keyword.end, text: replacement.padEnd(keyword.value.length, " ") });
  edits.push(...pending);
}

function rewriteClassDeclaration(tokens, index, edits) {
  const name = tokens[index + 1];
  if (!isName(name) || name.value === "extends") return;
  for (let j = index + 2; j < tokens.length; j++) {
    if (tokens[j].depth === 0 && isPunct(tokens[j], "{")) {
      const close = matchingClose(tokens, j);
      if (close < 0) return;
      edits.push({ start: tokens[index].start, end: tokens[index].start, text: name.value + " = " });
      edits.push({ start: tokens[close].end, end: tokens[close].end, text: ";" });
      return;
    }
  }
}

function functionDeclarationName(tokens, index) {
  let j = index;
  if (isName(tokens[j], "async")) {
    if (!isName(tokens[j + 1], "function") || tokens[j + 1].nl) return null;
    j++;
  }
  if (!isName(tokens[j], "function")) return null;
  j++;
  if (isPunct(tokens[j], "*")) j++;
  return isName(tokens[j]) ? tokens[j].value : null;
}

const EXPRESSION_STATEMENT_FORBIDDEN = new Set(["function", "class"]);

function compiles(source) {
  try {
    new AsyncFunction(source);
    return true;
  } catch (_error) {
    return false;
  }
}

// Find the trailing expression statement. The engine is the parser: a split is
// accepted only when the prefix compiles as statements and the tail compiles as
// a single expression. Candidates are scanned from the start so that
// newline-joined expressions (`a\n(b)`) keep JavaScript's own interpretation.
function findTrailingExpression(tokens, checkSource) {
  let last = tokens.length - 1;
  if (last < 0) return null;
  let end = tokens[last].end;
  if (isPunct(tokens[last], ";") && tokens[last].depth === 0) {
    last--;
    if (last < 0) return null;
    end = tokens[last].end;
  }

  for (let k = 0; k <= last; k++) {
    const token = tokens[k];
    if (token.depth !== 0) continue;
    const prev = tokens[k - 1];
    const boundary = k === 0 || isPunct(prev, ";") || isPunct(prev, "}") || token.nl;
    if (!boundary) continue;
    if (k > 0 && !isPunct(prev, ";") && continuesExpression(token)) continue;
    if (isPunct(token, "{") || (token.type === "name" && EXPRESSION_STATEMENT_FORBIDDEN.has(token.value))) continue;
    if (isName(token, "let") && isPunct(tokens[k + 1], "[")) continue;
    if (isName(token, "async") && isName(tokens[k + 1], "function")) continue;

    // Tokens of blanked statements (static imports) are not candidates.
    if (checkSource[token.start] !== currentSource[token.start]) continue;
    const tail = checkSource.slice(token.start, end);
    if (!compiles("return (" + tail + "\n)")) continue;
    if (!compiles(checkSource.slice(0, token.start))) continue;
    return { start: token.start, end };
  }
  return null;
}

function applyEdits(source, edits) {
  const sorted = edits.slice().sort((a, b) => b.start - a.start || b.end - a.end);
  let result = source;
  for (const edit of sorted) {
    result = result.slice(0, edit.start) + edit.text + result.slice(edit.end);
  }
  return result;
}

function transformCell(code) {
  currentSource = code;
  const tokens = tokenize(code);
  const importEdits = [];
  const exportEdits = [];
  const declarationEdits = [];
  const published = [];

  const rewriteDeclaration = (k) => {
    const token = tokens[k];
    if (token.value === "const" || token.value === "let" || token.value === "var") {
      rewriteVariableDeclaration(tokens, k, declarationEdits);
    } else if (token.value === "class") {
      rewriteClassDeclaration(tokens, k, declarationEdits);
    } else if (token.value === "function" || token.value === "async") {
      const name = functionDeclarationName(tokens, k);
      if (name) published.push(name);
    }
  };

  for (let k = 0; k < tokens.length; k++) {
    const token = tokens[k];
    if (isName(token, "import") && isPunct(tokens[k + 1], "(")) {
      importEdits.push({ start: token.start, end: token.end, text: "__lemon_import__" });
      continue;
    }
    if (token.type !== "name" || !startsStatement(tokens, k)) continue;

    if (token.value === "import" && !isPunct(tokens[k + 1], ".")) {
      const edit = rewriteImport(tokens, k);
      if (edit) importEdits.push(edit);
    } else if (token.value === "export" && isName(tokens[k + 1]) && !isName(tokens[k + 1], "default")) {
      // `export` means nothing in a cell; keep the declaration it introduces.
      exportEdits.push({ start: token.start, end: token.end, text: " ".repeat(token.value.length) });
      rewriteDeclaration(k + 1);
      k++;
    } else {
      rewriteDeclaration(k);
    }
  }

  // Compile checks see static imports and `export` keywords as same-length whitespace.
  const blanked = applyEdits(code, blankEdits(code, importEdits).concat(exportEdits));
  const trailing = findTrailingExpression(tokens, blanked);
  const returnEdits = trailing
    ? [
        { start: trailing.start, end: trailing.start, text: "return (" },
        { start: trailing.end, end: trailing.end, text: ")" },
      ]
    : [];

  const publish = published.map((name) => "globalThis[" + JSON.stringify(name) + "] = " + name + ";").join(" ");
  const baseEdits = importEdits.concat(exportEdits, returnEdits);
  let body = applyEdits(code, baseEdits.concat(declarationEdits));
  if (!compiles(publish + body)) {
    // Never let the persistence rewrite turn valid code into a syntax error.
    body = applyEdits(code, baseEdits);
  }
  return { publish, body };
}

function blankEdits(code, importEdits) {
  return importEdits
    .filter((edit) => edit.text !== "__lemon_import__")
    .map((edit) => ({ start: edit.start, end: edit.end, text: code.slice(edit.start, edit.end).replace(/[^\n]/g, " ") }));
}

// ---------------------------------------------------------------------------
// Execution
// ---------------------------------------------------------------------------

const indirectEval = globalThis.eval;

// Frames of the kernel itself: indirect eval, worker message dispatch, runtime internals.
const HOST_FRAME = /\(node:|\bat node:|eval \((<anonymous>|unknown)\)|<parse>/;

function formatError(error) {
  if (error instanceof Error && typeof error.stack === "string") {
    const lines = error.stack.split("\n");
    const kept = lines.filter((line) => !/^\s+at /.test(line) || !HOST_FRAME.test(line) && !line.includes(__filename));
    return kept.join("\n");
  }
  return util.inspect(error, { depth: 4, colors: false });
}

async function runCell(code, cell) {
  let source;
  try {
    const { publish, body } = transformCell(code);
    source = "(async () => {" + publish + body + "\n})()\n//# sourceURL=cell-" + cell + ".js";
  } catch (error) {
    return { status: "error", error: "Internal eval rewrite failure: " + formatError(error) };
  }

  try {
    const value = await indirectEval(source);
    if (value === undefined) return { status: "ok", display: null };
    let display = util.inspect(value, { depth: 4, colors: false, maxArrayLength: 200, breakLength: 100 });
    if (display.length > MAX_DISPLAY_CHARS) {
      display = display.slice(0, MAX_DISPLAY_CHARS) + "\n[display truncated at " + MAX_DISPLAY_CHARS + " characters]";
    }
    return { status: "ok", display };
  } catch (error) {
    return { status: "error", error: formatError(error) };
  }
}

// ---------------------------------------------------------------------------
// Command loop
// ---------------------------------------------------------------------------

const READER_SOURCE = `
const fs = require("node:fs");
const { parentPort } = require("node:worker_threads");
const { spawnSync } = require("node:child_process");
const { StringDecoder } = require("node:string_decoder");
const decoder = new StringDecoder("utf8");
const sleepCell = new Int32Array(new SharedArrayBuffer(4));
const buffer = Buffer.alloc(65536);
let pending = "";
for (;;) {
  let count;
  try {
    count = fs.readSync(0, buffer, 0, buffer.length, null);
  } catch (error) {
    if (error && error.code === "EAGAIN") { Atomics.wait(sleepCell, 0, 0, 5); continue; }
    count = 0;
  }
  if (count === 0) {
    if (process.platform === "win32") {
      spawnSync("taskkill", ["/F", "/T", "/PID", String(process.pid)], { stdio: "ignore" });
      process.kill(process.pid, "SIGKILL");
    } else {
      // js_kernel_host.js launched this process as the detached group leader.
      process.kill(-process.pid, "SIGKILL");
    }
  }
  pending += decoder.write(buffer.subarray(0, count));
  let newline;
  while ((newline = pending.indexOf("\\n")) >= 0) {
    const line = pending.slice(0, newline);
    pending = pending.slice(newline + 1);
    if (line.trim() !== "") parentPort.postMessage(line);
  }
}
`;

const queue = [];
let running = false;
let cellCounter = 0;

async function drain() {
  if (running) return;
  running = true;
  while (queue.length > 0) {
    const line = queue.shift();
    let message;
    try {
      message = JSON.parse(line);
    } catch (_error) {
      continue;
    }
    if (!message || message.op !== "execute") continue;
    cellCounter++;
    const result = await runCell(String(message.code || ""), cellCounter);
    send(Object.assign({ type: "result", id: message.id }, result));
  }
  running = false;
}

const reader = new Worker(READER_SOURCE, { eval: true });
reader.on("message", (line) => {
  queue.push(line);
  drain();
});
reader.on("error", (error) => {
  writeAll(2, "eval kernel command reader failed: " + formatError(error) + "\n");
  process.exit(70);
});

send({
  type: "ready",
  runtime: typeof Bun !== "undefined" ? "bun" : "node",
  version: typeof Bun !== "undefined" ? Bun.version : process.versions.node,
});
