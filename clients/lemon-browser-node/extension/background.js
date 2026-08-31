// Lemon Browser Relay MV3 service worker. Mechanics adapted from OMP's
// MIT-licensed browser relay; see ../THIRD_PARTY_NOTICES.md.
const DEFAULT_PORT = 9224;
const PING_INTERVAL_MS = 20_000;
const RECONNECT_MIN_MS = 1_000;
const RECONNECT_MAX_MS = 10_000;

let socket = null;
let reconnectDelay = RECONNECT_MIN_MS;
let pingTimer = null;
let allowedTabs = new Set();

async function settings() {
  const stored = await chrome.storage.local.get({ port: DEFAULT_PORT, token: '', allowedTabIds: [] });
  const port = Number(stored.port);
  allowedTabs = new Set(
    Array.isArray(stored.allowedTabIds)
      ? stored.allowedTabIds.filter((value) => Number.isInteger(value))
      : [],
  );
  return {
    port: Number.isInteger(port) && port > 0 && port <= 65535 ? port : DEFAULT_PORT,
    token: typeof stored.token === 'string' ? stored.token : '',
  };
}

function snapshot(tab, targetId) {
  if (tab.id === undefined) return null;
  return {
    tabId: tab.id,
    targetId,
    url: tab.url ?? tab.pendingUrl ?? '',
    title: tab.title ?? '',
    active: tab.active,
    windowId: tab.windowId,
    pinned: tab.pinned,
  };
}

function post(message) {
  if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
}

async function badge(state) {
  const text = state === 'connected' ? 'on' : state === 'auth' ? '!' : 'off';
  const color = state === 'connected' ? '#1a7f37' : state === 'auth' ? '#cf222e' : '#6e7781';
  await chrome.action.setBadgeText({ text }).catch(() => undefined);
  await chrome.action.setBadgeBackgroundColor({ color }).catch(() => undefined);
}

async function hello() {
  const [tabs, targets] = await Promise.all([chrome.tabs.query({}), chrome.debugger.getTargets()]);
  const targetByTab = new Map(
    targets
      .filter((target) => target.tabId !== undefined)
      .map((target) => [target.tabId, target.id]),
  );
  const browserVersion = /Chrome\/[\d.]+/.exec(navigator.userAgent)?.[0] ?? 'Chrome/unknown';
  return {
    t: 'hello',
    userAgent: navigator.userAgent,
    browserVersion,
    tabs: tabs
      .filter((tab) => allowedTabs.has(tab.id))
      .map((tab) => snapshot(tab, targetByTab.get(tab.id)))
      .filter((tab) => tab?.targetId),
    attachedTabIds: targets
      .filter((target) => target.attached && allowedTabs.has(target.tabId))
      .map((target) => target.tabId),
  };
}

async function runRpc(message) {
  if (message.op !== 'createTab' && !allowedTabs.has(message.tabId)) {
    throw new Error('tab is not opted in to Lemon Browser Relay');
  }
  switch (message.op) {
    case 'attach':
      await chrome.debugger.attach({ tabId: message.tabId }, '1.3');
      return {};
    case 'detach':
      await chrome.debugger.detach({ tabId: message.tabId });
      return {};
    case 'send':
      return chrome.debugger.sendCommand(
        message.sessionId
          ? { tabId: message.tabId, sessionId: message.sessionId }
          : { tabId: message.tabId },
        message.method,
        message.params,
      );
    case 'createTab': {
      const tab = await chrome.tabs.create({ url: message.url });
      await allowTab(tab.id);
      const tabSnapshot = await snapshotForTab(tab);
      if (!tabSnapshot) throw new Error('created tab has no ID');
      return { tab: tabSnapshot };
    }
    case 'removeTab':
      await chrome.tabs.remove(message.tabId);
      return {};
    case 'activateTab': {
      const tab = await chrome.tabs.get(message.tabId);
      await chrome.windows.update(tab.windowId, { focused: true });
      await chrome.tabs.update(message.tabId, { active: true });
      return {};
    }
    default:
      throw new Error(`unsupported relay operation: ${message.op}`);
  }
}

async function snapshotForTab(tab) {
  if (tab.id === undefined) return null;
  const targets = await chrome.debugger.getTargets();
  const target = targets.find((candidate) => candidate.tabId === tab.id);
  return target ? snapshot(tab, target.id) : null;
}

async function postTab(type, tab) {
  if (!allowedTabs.has(tab.id)) return;
  const value = await snapshotForTab(tab);
  if (value) post({ t: type, tab: value });
}

async function allowTab(tabId) {
  if (!Number.isInteger(tabId)) throw new Error('tab has no ID');
  allowedTabs.add(tabId);
  await chrome.storage.local.set({ allowedTabIds: [...allowedTabs] });
  await setTabBadge(tabId, true);
}

async function disallowTab(tabId) {
  allowedTabs.delete(tabId);
  await chrome.storage.local.set({ allowedTabIds: [...allowedTabs] });
  await chrome.debugger.detach({ tabId }).catch(() => undefined);
  await setTabBadge(tabId, false);
  post({ t: 'tabRemoved', tabId });
}

async function setTabBadge(tabId, enabled) {
  await chrome.action.setBadgeText({ tabId, text: enabled ? 'L' : '' }).catch(() => undefined);
  if (enabled) {
    await chrome.action.setBadgeBackgroundColor({ tabId, color: '#1a7f37' }).catch(() => undefined);
  }
}

function handleMessage(raw) {
  let message;
  try {
    message = JSON.parse(raw);
  } catch {
    return;
  }
  if (message.t === 'pong') return;
  if (message.t !== 'rpc') return;
  void runRpc(message)
    .then((result) => post({ t: 'rpcResult', id: message.id, ok: true, result }))
    .catch((error) =>
      post({
        t: 'rpcResult',
        id: message.id,
        ok: false,
        error: error instanceof Error ? error.message : String(error),
      }),
    );
}

function reconnect() {
  const delay = reconnectDelay;
  reconnectDelay = Math.min(reconnectDelay * 2, RECONNECT_MAX_MS);
  setTimeout(() => void connect(), delay);
}

async function connect() {
  if (socket && [WebSocket.OPEN, WebSocket.CONNECTING].includes(socket.readyState)) return;
  const config = await settings();
  if (!config.token) {
    await badge('auth');
    reconnect();
    return;
  }
  const next = new WebSocket(
    `ws://127.0.0.1:${config.port}/ext?token=${encodeURIComponent(config.token)}`,
  );
  socket = next;
  next.onopen = () => {
    reconnectDelay = RECONNECT_MIN_MS;
    void badge('connected');
    void hello().then(post);
    clearInterval(pingTimer);
    pingTimer = setInterval(() => post({ t: 'ping' }), PING_INTERVAL_MS);
  };
  next.onmessage = (event) => {
    if (typeof event.data === 'string') handleMessage(event.data);
  };
  next.onclose = () => {
    if (socket !== next) return;
    socket = null;
    clearInterval(pingTimer);
    pingTimer = null;
    void badge('disconnected');
    reconnect();
  };
  next.onerror = () => next.close();
}

chrome.debugger.onEvent.addListener((source, method, params) => {
  if (source.tabId !== undefined && allowedTabs.has(source.tabId)) {
    post({ t: 'cdpEvent', tabId: source.tabId, sessionId: source.sessionId, method, params });
  }
});
chrome.debugger.onDetach.addListener((source, reason) => {
  if (source.tabId !== undefined && allowedTabs.has(source.tabId)) {
    post({ t: 'detached', tabId: source.tabId, reason });
  }
});
chrome.tabs.onCreated.addListener((tab) => {
  void postTab('tabCreated', tab);
});
chrome.tabs.onUpdated.addListener((_tabId, _changeInfo, tab) => {
  void postTab('tabUpdated', tab);
});
chrome.tabs.onRemoved.addListener((tabId) => {
  if (allowedTabs.has(tabId)) void disallowTab(tabId);
});
chrome.alarms.create('lemon-relay-keepalive', { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === 'lemon-relay-keepalive') void connect();
});
chrome.storage.onChanged.addListener((changes, area) => {
  if (area === 'local') {
    if (changes.allowedTabIds) {
      const next = changes.allowedTabIds.newValue;
      allowedTabs = new Set(Array.isArray(next) ? next.filter(Number.isInteger) : []);
    }
    if (changes.port || changes.token) {
      socket?.close();
      void connect();
    }
  }
});
chrome.action.onClicked.addListener((tab) => {
  if (!Number.isInteger(tab.id) || /^(chrome|chrome-extension|devtools|edge|brave):/i.test(tab.url ?? '')) {
    void chrome.runtime.openOptionsPage();
    return;
  }
  if (allowedTabs.has(tab.id)) void disallowTab(tab.id);
  else void allowTab(tab.id).then(() => postTab('tabCreated', tab));
});
chrome.runtime.onInstalled.addListener(() => void chrome.runtime.openOptionsPage());
chrome.runtime.onStartup.addListener(() => void connect());
void connect();
