# Lemon browser node and Chrome relay

This client provides two execution paths behind Lemon's shared browser tools:

- `local-driver` launches or attaches to Chrome through Playwright/CDP.
- `lemon-browser-relay` exposes existing signed-in Chrome tabs through the
  bundled Manifest V3 extension, without relaunching the user's profile.

Both paths support explicit stable tab target IDs. Attached browser processes
are never closed when Lemon disconnects.

## Build and test

```bash
npm install
npm run build
npm test
npm run typecheck
```

## Existing-Chrome extension relay

Generate a secret and start the loopback-only relay:

```bash
export LEMON_BROWSER_RELAY_TOKEN="$(openssl rand -hex 32)"
./bin/lemon-browser-relay start
```

Run `./bin/lemon-browser-relay install` to copy the extension into a stable,
versioned user-data path, or `./bin/lemon-browser-relay path` to use the source
directory. In `chrome://extensions`, enable Developer mode, choose **Load
unpacked**, and select that directory. Open the extension settings and enter
the same token and port. On every existing tab Lemon may control, click the
extension toolbar icon once; the visible `L` badge means that tab is opted in.
Click it again to detach immediately. Tabs opened by Lemon through an already
opted-in relay session are scoped automatically.

Select the relay through Lemon's [unified browser provider](../../docs/tools/browser.md#choosing-a-browser-provider):

```bash
export LEMON_BROWSER_PROVIDER=relay
```

The default `auto` provider can also choose a configured, connected relay, after
checking LCU. When running the Node driver directly rather than through Lemon,
attach with `LEMON_BROWSER_CDP_ENDPOINT="ws://127.0.0.1:9224/cdp?token=$LEMON_BROWSER_RELAY_TOKEN"`;
endpoint attachment is always attach-only.

The relay rejects non-loopback binding, rejects browser-originated CDP
connections, requires constant-time token authentication on discovery and both
WebSocket paths, hides Chrome-internal pages, multiplexes tab debugger sessions,
and acknowledges rather than forwards `Browser.close`.

