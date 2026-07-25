// Perch — jump to terminal.
//
// Perch can bring VS Code forward on its own; what it cannot do from outside is pick one
// of a dozen terminal tabs. This extension answers a URI with the tty of the session you
// clicked and focuses the terminal running on it.
//
// Plain JavaScript on purpose: no TypeScript build, no `node_modules`, nothing to keep in
// step with a toolchain. The whole extension is this file and a manifest, so installing it
// is a copy — which matters for something a native app asks you to install.

const vscode = require("vscode");
const { execFile } = require("child_process");

/** `ps` is the only way to get from a shell's pid to the tty it is attached to. */
function ttyOf(pid) {
  return new Promise((resolve) => {
    execFile("/bin/ps", ["-o", "tty=", "-p", String(pid)], (error, stdout) => {
      if (error) return resolve(null);
      const tty = stdout.trim();
      // `ps` prints `ttys004`; the hook captured `/dev/ttys004`.
      resolve(tty && tty !== "??" ? tty : null);
    });
  });
}

function normalise(tty) {
  if (!tty) return null;
  return tty.replace(/^\/dev\//, "");
}

async function focusByTty(target) {
  const wanted = normalise(target);
  if (!wanted) return false;

  for (const terminal of vscode.window.terminals) {
    let pid;
    try {
      pid = await terminal.processId;
    } catch {
      continue;
    }
    if (!pid) continue;

    if (normalise(await ttyOf(pid)) === wanted) {
      // `preserveFocus: false` — the point of the jump is to land in it.
      terminal.show(false);
      return true;
    }
  }
  return false;
}

function activate(context) {
  context.subscriptions.push(
    vscode.window.registerUriHandler({
      async handleUri(uri) {
        // vscode://kweli.perch-jump/focus?tty=/dev/ttys004
        const params = new URLSearchParams(uri.query);
        const tty = params.get("tty");
        if (!tty) return;

        const found = await focusByTty(tty);
        if (!found) {
          // Silence here would look like the extension is not installed. One line, once,
          // is better than a jump that quietly does nothing.
          vscode.window.setStatusBarMessage(
            `Perch: no terminal on ${tty} in this window`,
            4000
          );
        }
      },
    })
  );

  context.subscriptions.push(
    vscode.commands.registerCommand("perch.focusTerminalByTty", async () => {
      const tty = await vscode.window.showInputBox({
        prompt: "tty to focus, e.g. /dev/ttys004",
      });
      if (tty) await focusByTty(tty);
    })
  );
}

function deactivate() {}

module.exports = { activate, deactivate };
