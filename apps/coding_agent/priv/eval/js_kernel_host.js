"use strict";
// Keep the JavaScript kernel in its own OS process group. This host never
// executes cells, so EOF remains observable even during a synchronous loop.
const { spawn, spawnSync } = require("node:child_process");
const path = require("node:path");

const kernel = spawn(process.execPath, [path.join(__dirname, "js_kernel.js")], {
  detached: true,
  stdio: ["pipe", "inherit", "inherit"],
});

let stopping = false;
function stop(status) {
  if (stopping) return;
  stopping = true;
  if (kernel.pid) {
    try {
      if (process.platform === "win32") {
        spawnSync("taskkill", ["/F", "/T", "/PID", String(kernel.pid)], { stdio: "ignore" });
      } else {
        process.kill(-kernel.pid, "SIGKILL");
      }
    } catch (_) {
      // The group may already have exited.
    }
  }
  process.exit(status);
}

kernel.on("error", (error) => {
  process.stderr.write("Could not start JavaScript kernel: " + error.message + "\n");
  stop(70);
});
kernel.on("exit", (status) => stop(status === null ? 1 : status));
kernel.stdin.on("error", () => stop(1));
process.stdin.on("end", () => stop(0));
process.stdin.on("error", () => stop(1));
process.on("SIGINT", () => { if (kernel.pid) process.kill(-kernel.pid, "SIGINT"); });
process.on("SIGTERM", () => stop(1));
process.stdin.pipe(kernel.stdin);
