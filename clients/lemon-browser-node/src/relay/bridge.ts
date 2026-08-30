/**
 * Minimal CDP browser facade over the Chrome MV3 `chrome.debugger` API.
 *
 * The target/session synthesis follows the same Chrome-extension transport
 * mechanics used by OMP's MIT-licensed browser relay, adapted for Playwright
 * and Lemon's explicit multi-tab protocol. See THIRD_PARTY_NOTICES.md.
 */
import type {
  ExtensionToRelay,
  RelayRpcRequest,
  RelayToExtension,
  TabSnapshot,
} from './protocol.js';

export interface RelaySocket {
  send(text: string): void;
  close(): void;
}

type SessionRef =
  | { tabId: number; kind: 'page' | 'child' }
  | { kind: 'browser' };
type PendingRpc = {
  resolve(value: unknown): void;
  reject(error: Error): void;
  timer: NodeJS.Timeout;
};

type TargetInfo = {
  targetId: string;
  type: 'page' | 'browser';
  title: string;
  url: string;
  attached: boolean;
  canAccessOpener: boolean;
  browserContextId?: string;
};

type CdpCommand = {
  id: number;
  method: string;
  params?: Record<string, unknown>;
  sessionId?: string;
};

class DownstreamConnection {
  readonly sessions = new Map<string, SessionRef>();
  discover = false;
  autoAttach = false;

  constructor(
    readonly id: number,
    readonly socket: RelaySocket,
  ) {}
}

class TabState {
  attached = false;
  banned = false;
  attaching: Promise<boolean> | null = null;

  constructor(readonly tabId: number, snapshot: TabSnapshot) {
    this.update(snapshot);
  }

  url = '';
  targetId = '';
  title = '';
  active = false;
  windowId = -1;
  pinned = false;

  update(snapshot: TabSnapshot): void {
    this.targetId = snapshot.targetId;
    if (this.url !== snapshot.url) this.banned = false;
    this.url = snapshot.url;
    this.title = snapshot.title;
    this.active = snapshot.active;
    this.windowId = snapshot.windowId;
    this.pinned = snapshot.pinned;
  }
}

// `about:blank` is Chrome's normal target bootstrap URL and must remain
// eligible so Playwright can create a page before navigating it. Other browser
// internals stay outside the relay.
const INELIGIBLE_URL = /^(chrome|chrome-extension|devtools|edge|brave):|^about:(?!blank$)/i;
const RPC_TIMEOUT_MS = 30_000;
const CDP_METHOD_NOT_FOUND = -32601;
const DEFAULT_BROWSER_CONTEXT_ID = 'LEMON_DEFAULT';

export class RelayBridge {
  private tabs = new Map<number, TabState>();
  private connections = new Map<number, DownstreamConnection>();
  private extension: RelaySocket | null = null;
  private extensionInfo: { userAgent: string; browserVersion: string } | null = null;
  private pendingRpc = new Map<number, PendingRpc>();
  private realSessionTabs = new Map<string, number>();
  private connectionSeq = 0;
  private sessionSeq = 0;
  private rpcSeq = 0;

  constructor(private readonly log: (message: string, data?: Record<string, unknown>) => void = () => {}) {}

  get ready(): boolean {
    return this.extension !== null && this.extensionInfo !== null;
  }

  versionInfo(webSocketDebuggerUrl: string): Record<string, string> {
    return {
      Browser: this.extensionInfo?.browserVersion ?? 'Chrome/unknown',
      'Protocol-Version': '1.3',
      'User-Agent': this.extensionInfo?.userAgent ?? '',
      'V8-Version': '',
      'WebKit-Version': '',
      webSocketDebuggerUrl,
    };
  }

  listTargets(): Array<Record<string, string>> {
    return [...this.tabs.values()]
      .filter((tab) => this.eligible(tab))
      .map((tab) => ({
        id: tab.targetId,
        type: 'page',
        title: tab.title,
        url: tab.url,
      }));
  }

  extensionConnected(socket: RelaySocket): void {
    if (this.extension && this.extension !== socket) this.extension.close();
    this.extension = socket;
  }

  extensionClosed(socket: RelaySocket): void {
    if (this.extension !== socket) return;
    this.extension = null;
    this.extensionInfo = null;
    for (const pending of this.pendingRpc.values()) {
      clearTimeout(pending.timer);
      pending.reject(new Error('relay extension disconnected'));
    }
    this.pendingRpc.clear();
    for (const tab of this.tabs.values()) {
      tab.attached = false;
      tab.attaching = null;
    }
  }

  extensionMessage(socket: RelaySocket, raw: string): void {
    if (socket !== this.extension) return;
    let message: ExtensionToRelay;
    try {
      message = JSON.parse(raw) as ExtensionToRelay;
    } catch {
      return;
    }

    switch (message.t) {
      case 'hello':
        this.onHello(message);
        return;
      case 'rpcResult': {
        const pending = this.pendingRpc.get(message.id);
        if (!pending) return;
        this.pendingRpc.delete(message.id);
        clearTimeout(pending.timer);
        if (message.ok) pending.resolve(message.result);
        else pending.reject(new Error(message.error || 'extension RPC failed'));
        return;
      }
      case 'cdpEvent':
        this.onCdpEvent(message.tabId, message.sessionId, message.method, message.params);
        return;
      case 'detached':
        this.onDetached(message.tabId, message.reason);
        return;
      case 'tabCreated':
      case 'tabUpdated':
        this.upsertTab(message.tab);
        return;
      case 'tabRemoved':
        this.removeTab(message.tabId);
        return;
      case 'ping':
        this.extension?.send(JSON.stringify({ t: 'pong' } satisfies RelayToExtension));
        return;
    }
  }

  cdpConnected(socket: RelaySocket): number {
    const connection = new DownstreamConnection(++this.connectionSeq, socket);
    this.connections.set(connection.id, connection);
    return connection.id;
  }

  cdpClosed(connectionId: number): void {
    const connection = this.connections.get(connectionId);
    if (!connection) return;
    this.connections.delete(connectionId);

    const touchedTabs = new Set(
      [...connection.sessions.values()]
        .filter((session): session is Extract<SessionRef, { tabId: number }> => 'tabId' in session)
        .map((session) => session.tabId),
    );
    connection.sessions.clear();
    for (const tabId of touchedTabs) {
      if (this.sessionHolders(tabId) !== 0) continue;
      const tab = this.tabs.get(tabId);
      if (!tab?.attached) continue;
      tab.attached = false;
      void this.rpc({ op: 'detach', tabId }).catch(() => undefined);
    }
  }

  cdpMessage(connectionId: number, raw: string): void {
    const connection = this.connections.get(connectionId);
    if (!connection) return;

    let message: CdpCommand;
    try {
      message = JSON.parse(raw) as CdpCommand;
    } catch {
      return;
    }
    if (!Number.isInteger(message.id) || typeof message.method !== 'string') return;

    void this.handleCommand(connection, message).catch((error) => {
      this.replyError(connection, message, error instanceof Error ? error.message : String(error));
    });
  }

  private onHello(message: Extract<ExtensionToRelay, { t: 'hello' }>): void {
    this.extensionInfo = {
      userAgent: message.userAgent,
      browserVersion: message.browserVersion,
    };
    const attached = new Set(message.attachedTabIds);
    const seen = new Set<number>();
    for (const snapshot of message.tabs) {
      seen.add(snapshot.tabId);
      const tab = this.upsertTab(snapshot, true);
      tab.attached = attached.has(snapshot.tabId);
    }
    for (const tabId of this.tabs.keys()) {
      if (!seen.has(tabId)) this.removeTab(tabId);
    }
    this.log('extension ready', { tabs: this.tabs.size });
  }

  private async handleCommand(connection: DownstreamConnection, message: CdpCommand): Promise<void> {
    this.log('cdp command', {
      connectionId: connection.id,
      method: message.method,
      session: message.sessionId ? 'child' : 'root',
    });
    if (message.sessionId) {
      const session = connection.sessions.get(message.sessionId);
      const realTabId = this.realSessionTabs.get(message.sessionId);
      if (!session && realTabId === undefined) {
        this.replyError(connection, message, `Unknown session id ${message.sessionId}`);
        return;
      }
      if (session?.kind === 'browser') {
        await this.handleBrowserCommand(connection, message);
        return;
      }
      await this.forwardToTab(connection, message, session?.tabId ?? realTabId!, realTabId === undefined ? undefined : message.sessionId);
      return;
    }
    await this.handleBrowserCommand(connection, message);
  }

  private async handleBrowserCommand(connection: DownstreamConnection, message: CdpCommand): Promise<void> {
    switch (message.method) {
      case 'Browser.getVersion':
        this.reply(connection, message, {
          protocolVersion: '1.3',
          product: this.extensionInfo?.browserVersion ?? 'Chrome/unknown',
          revision: '',
          userAgent: this.extensionInfo?.userAgent ?? '',
          jsVersion: '',
        });
        return;
      case 'Target.getBrowserContexts':
        this.reply(connection, message, { browserContextIds: [] });
        return;
      case 'Target.attachToBrowserTarget': {
        const sessionId = `LEMON.BROWSER.${connection.id}.${++this.sessionSeq}`;
        connection.sessions.set(sessionId, { kind: 'browser' });
        this.reply(connection, message, { sessionId });
        return;
      }
      case 'Target.setDiscoverTargets':
        connection.discover = true;
        for (const tab of this.tabs.values()) {
          if (this.eligible(tab)) this.emit(connection, 'Target.targetCreated', { targetInfo: this.targetInfo(tab) });
        }
        this.reply(connection, message, {});
        return;
      case 'Target.setAutoAttach': {
        connection.autoAttach = true;
        for (const tab of this.tabs.values()) {
          if (!this.eligible(tab) || !(await this.ensureAttached(tab))) continue;
          this.attachConnection(connection, tab);
        }
        this.reply(connection, message, {});
        return;
      }
      case 'Target.attachToTarget': {
        const tab = this.tabFromTarget(message.params?.targetId);
        if (!tab || !(await this.ensureAttached(tab))) {
          this.replyError(connection, message, 'Target is unavailable');
          return;
        }
        const sessionId = this.mintSession(connection, tab.tabId);
        if (!message.sessionId) {
          this.emit(connection, 'Target.attachedToTarget', {
            sessionId,
            targetInfo: this.targetInfo(tab, true),
            waitingForDebugger: false,
          });
        }
        this.reply(connection, message, { sessionId });
        return;
      }
      case 'Target.detachFromTarget': {
        const sessionId = stringValue(message.params?.sessionId);
        if (sessionId) connection.sessions.delete(sessionId);
        this.reply(connection, message, {});
        return;
      }
      case 'Target.createTarget': {
        const url = stringValue(message.params?.url) ?? 'about:blank';
        const result = (await this.rpc({ op: 'createTab', url })) as { tab: TabSnapshot };
        const tab = this.upsertTab(result.tab);
        // Playwright expects an auto-attached target to exist in its internal
        // page map by the time the createTarget response resolves. Chrome emits
        // this ordering naturally; our synthesized target must preserve it.
        if (connection.autoAttach && (await this.ensureAttached(tab))) {
          this.attachConnection(connection, tab);
        }
        this.reply(connection, message, { targetId: tab.targetId });
        return;
      }
      case 'Target.closeTarget': {
        const tab = this.tabFromTarget(message.params?.targetId);
        if (!tab) {
          this.reply(connection, message, { success: false });
          return;
        }
        await this.rpc({ op: 'removeTab', tabId: tab.tabId });
        this.reply(connection, message, { success: true });
        return;
      }
      case 'Target.activateTarget': {
        const tab = this.tabFromTarget(message.params?.targetId);
        if (tab) await this.rpc({ op: 'activateTab', tabId: tab.tabId });
        this.reply(connection, message, {});
        return;
      }
      case 'Target.getTargetInfo': {
        const tab = this.tabFromTarget(message.params?.targetId);
        this.reply(connection, message, {
          targetInfo: tab ? this.targetInfo(tab, tab.attached) : browserTargetInfo(),
        });
        return;
      }
      case 'Browser.close':
        // An attached controller must never close the user's browser.
        this.log('ignored Browser.close', { connectionId: connection.id });
        this.reply(connection, message, {});
        return;
      case 'Browser.setDownloadBehavior':
        this.reply(connection, message, {});
        return;
      default:
        this.replyError(connection, message, `'${message.method}' wasn't found`, CDP_METHOD_NOT_FOUND);
    }
  }

  private async forwardToTab(
    connection: DownstreamConnection,
    message: CdpCommand,
    tabId: number,
    realSessionId?: string,
  ): Promise<void> {
    if (message.method === 'Browser.close') {
      this.reply(connection, message, {});
      return;
    }
    if (message.method === 'Target.getTargetInfo' && !realSessionId) {
      const tab = this.tabs.get(tabId);
      if (!tab) {
        this.replyError(connection, message, 'Target is unavailable');
        return;
      }
      this.reply(connection, message, { targetInfo: this.targetInfo(tab, true) });
      return;
    }
    const result = await this.rpc({
      op: 'send',
      tabId,
      sessionId: realSessionId,
      method: message.method,
      params: message.params,
    });
    this.reply(connection, message, (result as Record<string, unknown> | undefined) ?? {});
  }

  private onCdpEvent(tabId: number, realSessionId: string | undefined, method: string, params?: Record<string, unknown>): void {
    this.log('cdp event', { tabId, method, realSession: Boolean(realSessionId) });
    if (method === 'Target.attachedToTarget') {
      const child = stringValue(params?.sessionId);
      if (child) this.realSessionTabs.set(child, tabId);
    } else if (method === 'Target.detachedFromTarget') {
      const child = stringValue(params?.sessionId);
      if (child) this.realSessionTabs.delete(child);
    }

    for (const connection of this.connections.values()) {
      const sessions = [...connection.sessions.entries()].filter(
        ([, ref]) => 'tabId' in ref && ref.tabId === tabId,
      );
      if (sessions.length === 0) continue;
      if (realSessionId) {
        connection.socket.send(JSON.stringify({ sessionId: realSessionId, method, params }));
      } else {
        for (const [sessionId] of sessions) {
          connection.socket.send(JSON.stringify({ sessionId, method, params }));
        }
      }
    }
  }

  private onDetached(tabId: number, reason: string): void {
    const tab = this.tabs.get(tabId);
    if (!tab) return;
    tab.attached = false;
    tab.attaching = null;
    tab.banned = true;
    this.log('tab detached', { tabId, reason });
    this.removeSessionsForTab(tabId);
  }

  private upsertTab(snapshot: TabSnapshot, silent = false): TabState {
    let tab = this.tabs.get(snapshot.tabId);
    const created = !tab;
    if (!tab) {
      tab = new TabState(snapshot.tabId, snapshot);
      this.tabs.set(snapshot.tabId, tab);
    } else {
      tab.update(snapshot);
    }
    if (silent || !this.eligible(tab)) return tab;

    for (const connection of this.connections.values()) {
      if (connection.discover) {
        this.emit(connection, created ? 'Target.targetCreated' : 'Target.targetInfoChanged', {
          targetInfo: this.targetInfo(tab, tab.attached),
        });
      }
      if (created && connection.autoAttach) {
        void this.ensureAttached(tab).then((ok) => {
          if (ok) this.attachConnection(connection, tab!);
        });
      }
    }
    return tab;
  }

  private removeTab(tabId: number): void {
    const tab = this.tabs.get(tabId);
    if (!tab || !this.tabs.delete(tabId)) return;
    this.removeSessionsForTab(tabId, tab.targetId);
    for (const connection of this.connections.values()) {
      if (connection.discover) this.emit(connection, 'Target.targetDestroyed', { targetId: tab.targetId });
    }
  }

  private removeSessionsForTab(
    tabId: number,
    targetId = this.tabs.get(tabId)?.targetId ?? '',
  ): void {
    for (const connection of this.connections.values()) {
      for (const [sessionId, ref] of connection.sessions) {
        if (!('tabId' in ref) || ref.tabId !== tabId) continue;
        connection.sessions.delete(sessionId);
        this.emit(connection, 'Target.detachedFromTarget', { sessionId, targetId });
      }
    }
  }

  private attachConnection(connection: DownstreamConnection, tab: TabState): void {
    if (
      [...connection.sessions.values()].some(
        (session) => 'tabId' in session && session.tabId === tab.tabId,
      )
    ) return;
    const sessionId = this.mintSession(connection, tab.tabId);
    this.emit(connection, 'Target.attachedToTarget', {
      sessionId,
      targetInfo: this.targetInfo(tab, true),
      waitingForDebugger: false,
    });
  }

  private mintSession(connection: DownstreamConnection, tabId: number): string {
    const sessionId = `LEMON.${tabId}.${connection.id}.${++this.sessionSeq}`;
    connection.sessions.set(sessionId, { tabId, kind: 'page' });
    return sessionId;
  }

  private async ensureAttached(tab: TabState): Promise<boolean> {
    if (tab.attached) return true;
    if (tab.banned || !this.extension) return false;
    if (tab.attaching) return tab.attaching;
    tab.attaching = this.rpc({ op: 'attach', tabId: tab.tabId })
      .then(() => {
        tab.attached = true;
        return true;
      })
      .catch((error) => {
        tab.banned = true;
        this.log('tab attach failed', { tabId: tab.tabId, error: String(error) });
        return false;
      })
      .finally(() => {
        tab.attaching = null;
      });
    return tab.attaching;
  }

  private rpc(request: RelayRpcRequest): Promise<unknown> {
    if (!this.extension) return Promise.reject(new Error('relay extension is not connected'));
    this.log('extension rpc', { op: request.op });
    const id = ++this.rpcSeq;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pendingRpc.delete(id);
        reject(new Error(`extension RPC timed out (${request.op})`));
      }, RPC_TIMEOUT_MS);
      this.pendingRpc.set(id, { resolve, reject, timer });
      this.extension!.send(JSON.stringify({ t: 'rpc', id, ...request } satisfies RelayToExtension));
    });
  }

  private eligible(tab: TabState): boolean {
    return !tab.banned && !INELIGIBLE_URL.test(tab.url);
  }

  private targetInfo(tab: TabState, attached = tab.attached): TargetInfo {
    return {
      targetId: tab.targetId,
      type: 'page',
      title: tab.title,
      url: tab.url,
      attached,
      canAccessOpener: false,
      browserContextId: DEFAULT_BROWSER_CONTEXT_ID,
    };
  }

  private tabFromTarget(raw: unknown): TabState | undefined {
    const id = stringValue(raw);
    return id ? [...this.tabs.values()].find((tab) => tab.targetId === id) : undefined;
  }

  private sessionHolders(tabId: number): number {
    let count = 0;
    for (const connection of this.connections.values()) {
      if (
        [...connection.sessions.values()].some(
          (session) => 'tabId' in session && session.tabId === tabId,
        )
      ) count += 1;
    }
    return count;
  }

  private reply(connection: DownstreamConnection, message: CdpCommand, result: Record<string, unknown>): void {
    connection.socket.send(JSON.stringify({ id: message.id, result, sessionId: message.sessionId }));
  }

  private replyError(connection: DownstreamConnection, message: CdpCommand, text: string, code = -32000): void {
    connection.socket.send(JSON.stringify({ id: message.id, error: { code, message: text }, sessionId: message.sessionId }));
  }

  private emit(connection: DownstreamConnection, method: string, params: Record<string, unknown>): void {
    connection.socket.send(JSON.stringify({ method, params }));
  }
}

function browserTargetInfo(): TargetInfo {
  return {
    targetId: 'LEMON_BROWSER',
    type: 'browser',
    title: '',
    url: '',
    attached: true,
    canAccessOpener: false,
    browserContextId: DEFAULT_BROWSER_CONTEXT_ID,
  };
}

function stringValue(value: unknown): string | null {
  return typeof value === 'string' && value !== '' ? value : null;
}
