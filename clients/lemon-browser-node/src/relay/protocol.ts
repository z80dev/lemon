export interface TabSnapshot {
  tabId: number;
  targetId: string;
  url: string;
  title: string;
  active: boolean;
  windowId: number;
  pinned: boolean;
}

export type RelayRpcRequest =
  | { op: 'attach'; tabId: number }
  | { op: 'detach'; tabId: number }
  | {
      op: 'send';
      tabId: number;
      sessionId?: string;
      method: string;
      params?: Record<string, unknown>;
    }
  | { op: 'createTab'; url: string }
  | { op: 'removeTab'; tabId: number }
  | { op: 'activateTab'; tabId: number };

export type RelayToExtension =
  | ({ t: 'rpc'; id: number } & RelayRpcRequest)
  | { t: 'pong' };

export type ExtensionToRelay =
  | {
      t: 'hello';
      userAgent: string;
      browserVersion: string;
      tabs: TabSnapshot[];
      attachedTabIds: number[];
    }
  | {
      t: 'cdpEvent';
      tabId: number;
      sessionId?: string;
      method: string;
      params?: Record<string, unknown>;
    }
  | { t: 'detached'; tabId: number; reason: string }
  | { t: 'tabCreated'; tab: TabSnapshot }
  | { t: 'tabUpdated'; tab: TabSnapshot }
  | { t: 'tabRemoved'; tabId: number }
  | { t: 'rpcResult'; id: number; ok: boolean; result?: unknown; error?: string }
  | { t: 'ping' };
