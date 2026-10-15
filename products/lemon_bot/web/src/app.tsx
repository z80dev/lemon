import { createContext, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import { LemonBotClient, nonce, type Bot, type Conversation, type Device, type InstanceStatus, type RealtimeConnection, type RealtimeEvent, type RealtimeState, type Resource, type Snapshot } from '@lemon-bot/sdk';
import { AuthScreen, savedAccounts, type WebSession } from './auth';
import { ArrowDown, ChevronRight, GitBranch, History, Inbox, LayoutGrid, ListFilter, Menu, MoreHorizontal, Plus, Search, SquarePen } from 'lucide-react';
import { AccountAvatar, BotAvatar, EmptyState, ErrorNotice, LemonFace, LemonMark, Loading, useAction } from './ui';
import { currentStep, previewText } from './live';
import { SettingsRoute, isSettingsScreen } from './settings-shell';
import { BotsScreen } from './features/bots';
import { ConversationScreen, FileViewer, VoiceOverlay } from './features/chat';
import { MachinesScreen } from './features/machines';
import { WorkScreen } from './features/work';
import { SettingsScreen } from './features/settings';
import { OwnerControlsScreen } from './features/enterprise';
import { PairingScreen } from './features/pairing';
import { ActivityScreen, Palette, SearchScreen } from './navigation';
import { ConnectionPanel } from './connection';
import { connectionLabel, sessionEnded } from './connection-state';

export interface Route { screen: string; id?: string; botId?: string; tab?: string; entryId?: string; conversationId?: string; taskConversationId?: string }
export interface AppContextValue { client: LemonBotClient; realtime: RealtimeConnection | null; snapshot: Snapshot; device: Device | null; online: boolean; navigate: (route: Route) => void; refresh: () => Promise<void>; reportError: (error: unknown) => void; draftPrompt: (conversationId: string, text: string) => void; logout: () => Promise<void>; forgetConversation: (conversationId: string) => void }
const AppContext = createContext<AppContextValue | null>(null);
export function useApp() { const value = useContext(AppContext); if (!value) throw new Error('Lemon Bot workspace context is not mounted.'); return value; }

export function decodeDeepLink(value: string, workspaceId: string): Route {
  const url = new URL(value, location.origin);
  const native = url.protocol === 'lemonbot:' && url.hostname === 'workspace';
  const web = url.origin === location.origin && url.pathname.startsWith('/app/workspace/');
  if ((!native && !web) || url.username || url.password || url.hash) throw new Error('Unsupported workspace link.');
  const raw = url.pathname.split('/').filter(Boolean);
  const parts = (web ? raw.slice(2) : raw).map(part => { const decoded = decodeURIComponent(part); if (!decoded || /[\/\\\u0000-\u001f]/.test(decoded)) throw new Error('Invalid link identifier.'); return decoded; });
  if (parts[0] !== workspaceId) throw new Error('This link belongs to a different workspace. Sign in to its saved backend account before opening it.');
  const allowed: Record<string, true> = { conversationId: true, taskConversationId: true, entryId: true, approvalId: true, routineRunId: true, botId: true };
  for (const [key, id] of url.searchParams) { if (!Object.hasOwn(allowed, key) || !id || /[\/\\\u0000-\u001f]/.test(id) || url.searchParams.getAll(key).length !== 1) throw new Error('Unsupported or invalid workspace link query.'); }
  if (parts[1] === 'machine' && parts.length === 3) { if ([...url.searchParams.keys()].some(key => key !== 'botId')) throw new Error('Invalid machine link.'); return { screen: 'machine.detail', id: parts[2], botId: url.searchParams.get('botId') || undefined }; }
  if (parts[1] !== 'bot' || !parts[2]) throw new Error('Invalid Bot link.');
  if (parts[3] === 'routine' && parts.length === 5) { if ([...url.searchParams.keys()].some(key => key !== 'routineRunId')) throw new Error('Invalid routine link.'); return { screen: 'routines', id: parts[4], botId: parts[2], entryId: url.searchParams.get('routineRunId') || undefined }; }
  if (parts.length !== 3 || url.searchParams.has('routineRunId') || url.searchParams.has('botId')) throw new Error('Invalid Bot link query.');
  const conversationId = url.searchParams.get('taskConversationId') || url.searchParams.get('conversationId');
  if (url.searchParams.has('approvalId')) {
    if (!url.searchParams.get('conversationId') || !url.searchParams.get('entryId') || url.searchParams.has('taskConversationId')) throw new Error('Approval links require their exact conversation and entry.');
    return { screen: 'decision', id: url.searchParams.get('approvalId')!, botId: parts[2], tab: conversationId || undefined, entryId: url.searchParams.get('entryId') || undefined };
  }
  if (url.searchParams.has('entryId') && !conversationId) throw new Error('An entry link requires its conversation.');
  return conversationId ? { screen: 'conversation', id: conversationId, botId: parts[2], entryId: url.searchParams.get('entryId') || undefined, conversationId: url.searchParams.get('conversationId') || undefined, taskConversationId: url.searchParams.get('taskConversationId') || undefined } : { screen: 'bot.overview', id: parts[2], botId: parts[2] };
}
export function openWorkspaceLink(value: string, workspaceId: string, navigate: (route: Route) => void) {
  const url = new URL(value, location.origin);
  const raw = url.pathname.split('/').filter(Boolean);
  const targetWorkspace = decodeURIComponent(url.protocol === 'lemonbot:' ? raw[0] || '' : raw[2] || '');
  const route = decodeDeepLink(value, targetWorkspace);
  if (targetWorkspace === workspaceId) { navigate(route); return; }
  const account = savedAccounts().find(item => item.workspaceId === targetWorkspace);
  if (!account) throw new Error('No saved backend account matches this workspace. Sign in to its known product backend before opening the link; links cannot choose an arbitrary server.');
  window.dispatchEvent(new CustomEvent('lemonbot:account-target', { detail: { baseUrl: account.baseUrl, link: value } }));
}
function initialRoute(): Route {
  const query = new URLSearchParams(location.hash.replace(/^#/, '') || location.search);
  return { screen: query.get('screen') || 'home', id: query.get('id') || undefined, botId: query.get('botId') || undefined, tab: query.get('tab') || undefined, entryId: query.get('entryId') || undefined, conversationId: query.get('conversationId') || undefined, taskConversationId: query.get('taskConversationId') || undefined };
}
function upsert<T extends Resource>(items: T[], resource: T) { const previous = items.find(item => item.id === resource.id); if (previous && previous.revision >= resource.revision) return items; return previous ? items.map(item => item.id === resource.id ? resource : item) : [...items, resource]; }
function applySnapshotEvent(snapshot: Snapshot, event: RealtimeEvent): Snapshot {
  switch (event.event) {
    case 'user.updated': return event.payload.revision > snapshot.user.revision ? { ...snapshot, user: event.payload } : snapshot;
    case 'workspace.updated': return event.payload.revision > snapshot.workspace.revision ? { ...snapshot, workspace: event.payload } : snapshot;
    case 'member.upserted': return event.payload.userId === snapshot.user.id ? { ...snapshot, member: event.payload } : snapshot;
    case 'bot.upserted': return { ...snapshot, bots: upsert(snapshot.bots, event.payload) };
    case 'bot.deleted': return { ...snapshot, bots: snapshot.bots.filter(bot => bot.id !== event.payload.id) };
    case 'bot.presence': return { ...snapshot, bots: snapshot.bots.map(bot => bot.id === event.payload.botId ? { ...bot, activity: event.payload.status } : bot) };
    case 'machine.upserted': return { ...snapshot, machines: upsert(snapshot.machines, event.payload) };
    case 'machine.deleted': return { ...snapshot, machines: snapshot.machines.filter(machine => machine.id !== event.payload.id) };
    case 'conversation.upserted': return { ...snapshot, conversations: upsert(snapshot.conversations, event.payload) };
    case 'conversation.deleted': return { ...snapshot, conversations: snapshot.conversations.filter(room => room.id !== event.payload.id) };
    case 'section.upserted': return { ...snapshot, sections: upsert(snapshot.sections, event.payload) };
    case 'section.deleted': return { ...snapshot, sections: snapshot.sections.filter(section => section.id !== event.payload.id) };
    case 'notification.upserted': return { ...snapshot, notifications: upsert(snapshot.notifications, event.payload) };
    case 'notification.deleted': return { ...snapshot, notifications: snapshot.notifications.filter(item => item.id !== event.payload.id) };
    case 'run.upserted': return { ...snapshot, activeRuns: ['reserved', 'queued', 'running', 'awaiting_input', 'outcome_unknown'].includes(event.payload.status) ? upsert(snapshot.activeRuns, event.payload) : snapshot.activeRuns.filter(run => run.id !== event.payload.id) };
    default: return snapshot;
  }
}
export function App() {
  const [session, setSession] = useState<WebSession | null>(() => { try { const stored = JSON.parse(sessionStorage.getItem('lemonbot.session') || 'null'); return stored && typeof stored.baseUrl === 'string' && typeof stored.token === 'string' && typeof stored.workspaceId === 'string' ? stored : null; } catch { return null; } });
  const [initialBackend, setInitialBackend] = useState<string>();
  const [signInNotice, setSignInNotice] = useState<string>();
  const forget = () => { const keys = Object.keys(sessionStorage); for (const key of keys) if (key.startsWith('lemonbot.')) sessionStorage.removeItem(key); setSession(null); };
  useEffect(() => {
    const change = (event: Event) => {
      const detail: unknown = (event as CustomEvent<unknown>).detail;
      if (!detail || typeof detail !== 'object' || !('baseUrl' in detail) || !('link' in detail) || typeof detail.baseUrl !== 'string' || typeof detail.link !== 'string') return;
      const target = savedAccounts().find(account => account.baseUrl === detail.baseUrl);
      if (!target) return;
      const finish = () => { forget(); sessionStorage.setItem('lemonbot.pending-link', detail.link as string); setInitialBackend(target.baseUrl); };
      if (session) void new LemonBotClient({ baseUrl: session.baseUrl, token: session.token }).call('POST /auth/logout', { body: { clientNonce: nonce() } }).finally(finish).catch(() => undefined);
      else finish();
    };
    window.addEventListener('lemonbot:account-target', change); return () => window.removeEventListener('lemonbot:account-target', change);
  }, [session]);
  return session ? <Workspace key={`${session.baseUrl}:${session.token}`} session={session} onLogout={reason => { setInitialBackend(session.baseUrl); setSignInNotice(reason); forget(); }} /> : <AuthScreen onAuth={value => { setSignInNotice(undefined); setSession(value); }} initialBackend={initialBackend} notice={signInNotice}/>;
}
function Workspace({ session, onLogout }: { session: WebSession; onLogout: (reason?: string) => void }) {
  const client = useMemo(() => new LemonBotClient({ baseUrl: session.baseUrl, token: session.token }), [session]);
  const [snapshot, setSnapshot] = useState<Snapshot>(); const snapshotRef = useRef<Snapshot | undefined>(undefined);
  const [device, setDevice] = useState<Device | null>(null); const [realtime, setRealtime] = useState<RealtimeConnection | null>(null);
  const [error, setError] = useState<unknown>(); const [connectionError, setConnectionError] = useState<unknown>();
  const [connection, setConnection] = useState<RealtimeState>('connecting'); const [browserOnline, setBrowserOnline] = useState(navigator.onLine);
  const [attempt, setAttempt] = useState(0), [bootRetryAt, setBootRetryAt] = useState<number | null>(null);
  const [lastAttemptAt, setLastAttemptAt] = useState(Date.now());
  const bootFailures = useRef(0);
  const [runtimeRunning, setRuntimeRunning] = useState(false);
  const [phone, setPhone] = useState(() => matchMedia('(max-width: 760px)').matches);
  useEffect(() => { const media = matchMedia('(max-width: 760px)'); const change = () => setPhone(media.matches); media.addEventListener('change', change); return () => media.removeEventListener('change', change); }, []);
  const [route, setRoute] = useState<Route>(initialRoute); const [palette, setPalette] = useState(false); const [sidebar, setSidebar] = useState(false);
  const routeRef = useRef(route); routeRef.current = route;
  const reportError = (failure: unknown) => setError(failure);
  const navigate = (next: Route) => { const query = new URLSearchParams(); for (const [key, value] of Object.entries(next)) if (value) query.set(key, value); location.hash = query.toString(); setRoute(next); setSidebar(false); };
  const update = (value: Snapshot) => { snapshotRef.current = value; setSnapshot(value); };
  const forgetConversation = (conversationId: string) => {
    const current = snapshotRef.current;
    if (current) {
      if (current.conversations.some(room => room.id === conversationId)) update({ ...current, conversations: current.conversations.filter(room => room.id !== conversationId) });
      sessionStorage.removeItem(`lemonbot.composer:${current.workspace.id}:${current.user.id}:${conversationId}`);
      sessionStorage.removeItem(`lemonbot.prompt:${current.workspace.id}:${current.user.id}:${conversationId}`);
    }
    if (routeRef.current.screen === 'conversation' && routeRef.current.id === conversationId) navigate({ screen: 'home' });
  };
  const sync = async (isCurrent: () => boolean = () => true) => {
    const value = await client.call('GET /sync');
    // Snapshot bounds are explicit. Page each flagged collection, keeping newer revisions.
    if (value.hasMore.bots) { let cursor: string | undefined; do { const page = await client.call('GET /bots', { query: { limit: 200, cursor } }); for (const item of page.items) value.bots = upsert(value.bots, item); cursor = page.nextCursor || undefined; } while (cursor); }
    if (value.hasMore.machines) { let cursor: string | undefined; do { const page = await client.call('GET /machines', { query: { limit: 200, cursor } }); for (const item of page.items) value.machines = upsert(value.machines, item); cursor = page.nextCursor || undefined; } while (cursor); }
    if (value.hasMore.conversations) { let cursor: string | undefined; do { const page = await client.call('GET /conversations', { query: { limit: 200, cursor } }); for (const item of page.items) value.conversations = upsert(value.conversations, item); cursor = page.nextCursor || undefined; } while (cursor); }
    if (value.hasMore.notifications) { let cursor: string | undefined; do { const page = await client.call('GET /notifications', { query: { limit: 200, cursor } }); for (const item of page.items) value.notifications = upsert(value.notifications, item); cursor = page.nextCursor || undefined; } while (cursor); }
    if (value.sections.length >= 200) { let cursor: string | undefined; do { const page = await client.call('GET /sections', { query: { limit: 200, cursor } }); for (const item of page.items) value.sections = upsert(value.sections, item); cursor = page.nextCursor || undefined; } while (cursor); }
    if (isCurrent()) update(value); return value;
  };
  const refresh = async () => { try { await sync(); window.dispatchEvent(new Event('lemon:refresh')); } catch (failure) { if (sessionEnded(failure)) onLogout('Your session ended. Sign in again.'); throw failure; } };
  const retry = () => { realtime?.close(); setRealtime(null); setBootRetryAt(null); setConnection('connecting'); setAttempt(value => value + 1); };
  const applyInstance = (status: InstanceStatus) => { const current = snapshotRef.current; if (current) update({ ...current, capabilities: { ...current.capabilities, controlConnected: status.controller.state === 'connected' } }); };
  useEffect(() => { if (bootRetryAt === null) return; const timer = setTimeout(() => setAttempt(value => value + 1), Math.max(0, bootRetryAt - Date.now())); return () => clearTimeout(timer); }, [bootRetryAt]);
  const logout = async () => { try { await client.call('POST /auth/logout', { body: { clientNonce: nonce() } }); } catch (failure) { setError(failure); } finally { realtime?.close(); sessionStorage.removeItem(`lemonbot.cursor:${session.baseUrl}:${session.workspaceId}`); onLogout(); } };
  useEffect(() => {
    let disposed = false; let socket: RealtimeConnection | undefined;
    setConnection('connecting'); setBootRetryAt(null); setLastAttemptAt(Date.now());
    void (async () => {
      try {
        const value = await sync(() => !disposed); if (disposed) return;
        bootFailures.current = 0;
        let registration: Device | undefined;
        try { let installationId = localStorage.getItem('lemonbot.installation'); if (!installationId) { installationId = nonce(); localStorage.setItem('lemonbot.installation', installationId); }
          registration = await client.call('POST /devices', { body: { clientNonce: nonce(), installationId, platform: 'web', name: 'Web browser', appVersion: '1.0.0' } }); if (disposed) return; setDevice(registration);
        } catch (failure) { if (!disposed) reportError(failure); }
        socket = client.realtime({ deviceId: registration?.id, cursor: value.cursor, onEvent: async event => {
          if (disposed) return; if (snapshotRef.current) update(applySnapshotEvent(snapshotRef.current, event));
          if (event.event === 'conversation.deleted') forgetConversation(event.payload.id);
          window.dispatchEvent(new CustomEvent('lemon:event', { detail: event }));
        }, onState: (state, failure) => {
          if (disposed) return;
          setConnection(state);
          if (failure) setConnectionError(failure);
          if (state === 'connecting' || state === 'authenticating') setLastAttemptAt(Date.now());
          if (state === 'live') setConnectionError(undefined);
          if (state === 'unauthenticated' || state === 'forbidden' || sessionEnded(failure)) onLogout('Your session ended. Sign in again.');
        }, onReset: async () => { const fresh = await sync(() => !disposed); if (!disposed) window.dispatchEvent(new Event('lemon:refresh')); return fresh; }, saveCursor: cursor => sessionStorage.setItem(`lemonbot.cursor:${session.baseUrl}:${session.workspaceId}`, cursor) });
        setRealtime(socket); socket.start();
      } catch (failure) { if (!disposed) {
        if (sessionEnded(failure)) { onLogout('Your session ended. Sign in again.'); return; }
        setConnectionError(failure); setConnection('error');
        const delay = Math.min(30000, 500 * 2 ** Math.min(bootFailures.current++, 6));
        setBootRetryAt(Date.now() + delay);
      } }
    })();
    return () => { disposed = true; socket?.close(); };
  }, [client, attempt]);
  useEffect(() => { const change = () => setRoute(initialRoute()); const online = () => setBrowserOnline(navigator.onLine); window.addEventListener('hashchange', change); window.addEventListener('online', online); window.addEventListener('offline', online); return () => { window.removeEventListener('hashchange', change); window.removeEventListener('online', online); window.removeEventListener('offline', online); }; }, []);
  useEffect(() => {
    if (!snapshot || snapshot.capabilities.controlConnected !== false) return;
    let disposed = false;
    const timer = setInterval(() => { if (document.visibilityState === 'visible') void client.call('GET /capabilities').then(capabilities => { const current = snapshotRef.current; if (!disposed && current) update({ ...current, capabilities }); }).catch(failure => { if (!disposed && sessionEnded(failure)) onLogout('Your session ended. Sign in again.'); }); }, 10000);
    return () => { disposed = true; clearInterval(timer); };
  }, [client, snapshot?.capabilities.controlConnected]);
  useEffect(() => {
    if (!snapshot) return;
    const query = new URLSearchParams(location.hash.replace(/^#/, ''));
    const link = sessionStorage.getItem('lemonbot.pending-link') || query.get('link') || (location.pathname.startsWith('/app/workspace/') ? location.href : null);
    if (link) { try { openWorkspaceLink(link, snapshot.workspace.id, navigate); sessionStorage.removeItem('lemonbot.pending-link'); } catch (failure) { reportError(failure); } }
    const push = (event: MessageEvent) => { if (event.data?.type === 'notification_navigation' && event.data.deepLink) { try { openWorkspaceLink(event.data.deepLink, snapshot.workspace.id, navigate); } catch (failure) { reportError(failure); } } };
    navigator.serviceWorker?.addEventListener('message', push); return () => navigator.serviceWorker?.removeEventListener('message', push);
  }, [snapshot?.workspace.id]);
  useEffect(() => { if (!realtime) return; const presence = () => { if (realtime.state !== 'live') return; try { realtime.send({ type: 'presence', foreground: document.visibilityState === 'visible', conversationId: route.screen === 'conversation' ? route.id || null : null }); } catch (failure) { reportError(failure); } }; const timer = window.setInterval(presence, 25000); document.addEventListener('visibilitychange', presence); if (connection === 'live') presence(); return () => { clearInterval(timer); document.removeEventListener('visibilitychange', presence); }; }, [realtime, route.id, route.screen, connection]);
  useEffect(() => {
    const keyboard = (event: KeyboardEvent) => {
      const modifier = event.metaKey || event.ctrlKey; const key = event.key.toLowerCase();
      if (modifier && key === 'k') { event.preventDefault(); setPalette(value => !value); return; }
      if (modifier && event.altKey && key === 'i') { event.preventDefault(); window.dispatchEvent(new Event('lemonbot:toggle-inspector')); return; }
      if (modifier && !event.shiftKey && key === 'i') { event.preventDefault(); window.dispatchEvent(new Event('lemonbot:focus-composer')); return; }
      if ((event.target instanceof HTMLElement) && (event.target.closest('input,textarea,select,[contenteditable="true"]') || event.target.closest('[role="dialog"]'))) return;
      if (event.key === 'Escape') { setSidebar(false); setPalette(false); return; }
      const current = snapshotRef.current; if (!current) return;
      const ordered = current.bots.filter(item => !item.sidebar.hidden).sort((a, b) => Number(b.sidebar.pinned) - Number(a.sidebar.pinned) || a.sidebar.rank - b.sidebar.rank || a.name.localeCompare(b.name));
      const step = modifier && (event.key === '[' || event.key === ']') ? (event.key === '[' ? -1 : 1) : event.altKey && !modifier && (event.key === 'ArrowUp' || event.key === 'ArrowDown') ? (event.key === 'ArrowUp' ? -1 : 1) : 0;
      if (step) { const index = ordered.findIndex(bot => bot.id === routeRef.current.botId || bot.mainConversationId === routeRef.current.id); const next = ordered[Math.min(ordered.length - 1, Math.max(0, index < 0 ? 0 : index + step))]; if (next) { event.preventDefault(); navigate({ screen: 'conversation', id: next.mainConversationId, botId: next.id }); } return; }
      if (!modifier) return;
      if (event.shiftKey && key === 'f') { event.preventDefault(); navigate({ screen: 'search', tab: 'bot' }); }
      else if (event.shiftKey && key === 'm') { event.preventDefault(); navigate({ screen: 'connect.apps' }); }
      else if (event.shiftKey && key === 'w') { event.preventDefault(); navigate({ screen: 'skills' }); }
      else if (key === 'n') { event.preventDefault(); navigate({ screen: 'bot.create' }); }
      else if (key === 'b') { event.preventDefault(); setSidebar(value => !value); }
      else if (event.key === ',' || event.key === '<') { event.preventDefault(); navigate(event.shiftKey ? { screen: 'bot.settings', id: routeRef.current.botId, botId: routeRef.current.botId } : { screen: 'settings' }); }
      else if (/^[1-9]$/.test(event.key)) { const bot = ordered[Number(event.key) - 1]; if (bot) { event.preventDefault(); navigate({ screen: 'conversation', id: bot.mainConversationId, botId: bot.id }); } }
    }; window.addEventListener('keydown', keyboard); return () => window.removeEventListener('keydown', keyboard);
  }, []);
  const connecting = ['connecting', 'authenticating', 'syncing', 'replaying'].includes(connection);
  const recoveryPanel = <ConnectionPanel client={client} state={connection} browserOnline={browserOnline} controlConnected={snapshot?.capabilities.controlConnected} error={connectionError} nextRetryAtMs={bootRetryAt ?? realtime?.nextRetryAtMs ?? null} lastAttemptAtMs={lastAttemptAt} retry={retry} busy={connecting} role={snapshot?.member.role} onInstance={applyInstance} onRunning={setRuntimeRunning}/>;
  if (!snapshot) return <main className="boot stack"><div className="brand"><LemonMark/>Lemon Bot</div>{recoveryPanel}<button onClick={() => onLogout()}>Choose another account</button></main>;
  const requiredVersion = snapshot.capabilities.minClientVersions.web;
  const requiredParts = requiredVersion.split('.').map(Number);
  const updateRequired = requiredParts[0] > 1 || requiredParts[0] === 1 && (requiredParts[1] > 0 || requiredParts[2] > 0);
  if (updateRequired) return <main className="boot stack"><div className="brand"><LemonMark/>Lemon Bot</div><h1>A client update is required</h1><p>This web client is 1.0.0; your backend requires {requiredVersion}. Ask the operator to build and deploy the matching web assets, then reload. Updating the client does not recreate your machines or remove work.</p><button className="primary" onClick={() => location.reload()}>Reload installed assets</button><button onClick={() => void logout()}>Sign out</button></main>;
  const activeBot = snapshot.bots.find(bot => bot.id === (route.botId || (route.screen.startsWith('bot.') || route.screen === 'memory' ? route.id : undefined))) || (route.screen === 'conversation' ? snapshot.bots.find(bot => bot.mainConversationId === route.id || snapshot.conversations.find(room => room.id === route.id)?.botIds.includes(bot.id)) : undefined);
  const appearance = snapshot.user.preferences.appearance;
  const context: AppContextValue = { client, realtime, snapshot, device, online: browserOnline && connection === 'live' && snapshot.capabilities.controlConnected !== false, navigate, refresh, reportError, logout, forgetConversation, draftPrompt: (conversationId, text) => {
    sessionStorage.setItem(`lemonbot.prompt:${snapshot.workspace.id}:${snapshot.user.id}:${conversationId}`, text);
    window.dispatchEvent(new CustomEvent('lemonbot:draft-prompt', { detail: { conversationId, text } })); navigate({ screen: 'conversation', id: conversationId, botId: snapshot.conversations.find(room => room.id === conversationId)?.botIds[0] });
  } };
  const unreadInbox = snapshot.notifications.filter(item => item.readAtMs === null && item.dismissedAtMs === null).length;
  const conversationScreen = route.screen === 'conversation';
  const settingsScreen = isSettingsScreen(route.screen);
  const atHome = route.screen === 'home';
  const connected = connection === 'live' && browserOnline && snapshot.capabilities.controlConnected !== false;
  return <AppContext.Provider value={context}><div className={`workspace ${sidebar ? 'sidebar-open' : ''} ${conversationScreen ? 'in-conversation' : ''} ${settingsScreen ? 'in-settings' : ''} ${atHome ? 'at-home' : ''} ${connected ? '' : 'disconnected'}`} data-theme={appearance}><a className="skip-link" href="#main-content">Skip to workspace content</a><Roster route={route} close={() => setSidebar(false)} openPalette={() => setPalette(true)} unreadInbox={unreadInbox} connection={connected ? null : connectionLabel(connection, browserOnline, snapshot.capabilities.controlConnected)} reconnect={retry} recovery={(!connected || runtimeRunning) && phone && atHome ? recoveryPanel : undefined}/><div className="workspace-main">{!conversationScreen && !atHome && !settingsScreen && <header className="workspace-bar"><button className="icon-button mobile-menu" aria-label="Open Bot list" onClick={() => setSidebar(value => !value)}><Menu size={20}/></button>{activeBot ? <button className="companion-anchor" onClick={() => navigate({ screen: 'conversation', id: activeBot.mainConversationId, botId: activeBot.id })}><BotAvatar bot={activeBot} size={22}/><strong>{activeBot.name}</strong></button> : <span/>}<div className="row workspace-tools"><button className="ghost-circle" aria-label="Search everything (⌘K)" title="Search (⌘K)" onClick={() => setPalette(true)}><Search size={15}/></button></div></header>}<main id="main-content" className="main-content" tabIndex={-1}>{!!error && <div className="global-error"><ErrorNotice error={error}/><button onClick={() => setError(undefined)}>Dismiss</button></div>}{(!connected || runtimeRunning) && !(phone && atHome) && recoveryPanel}<Destination route={route} activeBot={activeBot}/></main></div>{palette && <Palette close={() => setPalette(false)}/>}<VoiceOverlay/></div></AppContext.Provider>;
}
function Destination({ route, activeBot }: { route: Route; activeBot?: Bot }) {
  const { snapshot, navigate } = useApp();
  if (route.screen === 'home') return <Home/>;
  if (route.screen === 'conversation') return <ConversationScreen route={route}/>;
  if (route.screen === 'file.viewer') return <FileViewer route={route}/>;
  if (route.screen === 'decision') return <DecisionLink route={route}/>;
  if (['search'].includes(route.screen)) return <SearchScreen route={route}/>;
  if (['activity', 'upcoming'].includes(route.screen)) return <ActivityScreen route={route}/>;
  if (isSettingsScreen(route.screen)) return <SettingsRoute route={route}/>;
  if (route.screen === 'inbox') return <SettingsScreen route={route}/>;
  if (route.screen.startsWith('bot.') || ['memory', 'memory.import', 'preference.changes', 'group.create', 'group.edit', 'voice.preview'].includes(route.screen)) return <BotsScreen route={{ ...route, id: route.id || activeBot?.id, botId: route.botId || activeBot?.id }}/>;
  return <EmptyState title="This destination is unavailable" action={<button onClick={() => navigate({ screen: 'home' })}>Return to your Bots</button>}/>;
}
function DecisionLink({ route }: { route: Route }) {
  const { client, navigate, reportError } = useApp(); const [loading, setLoading] = useState(true);
  useEffect(() => { let cancelled = false; void (async () => { try { const approval = await client.call('GET /approvals/:id', { params: { id: route.id! } }); if (approval.botId !== route.botId || (route.tab && approval.conversationId !== route.tab) || (route.entryId && approval.entryId !== route.entryId)) throw new Error('Decision link identifiers do not match the authorized current request.'); await client.call('GET /entries/:id', { params: { id: approval.entryId } }); if (!cancelled) navigate({ screen: 'conversation', id: approval.conversationId, botId: approval.botId, entryId: approval.entryId }); } catch (failure) { if (!cancelled) { reportError(failure); setLoading(false); } } })(); return () => { cancelled = true; }; }, [route.id]);
  return loading ? <Loading/> : <EmptyState title="Decision unavailable">It may have expired, been deleted, or no longer be accessible. Opening a link never approves an action.</EmptyState>;
}
function Home() {
  const { snapshot, navigate } = useApp();
  const online = snapshot.machines.some(machine => machine.status === 'online');
  if (snapshot.bots.length === 0) return <div className="home"><EmptyState title="Create your first Bot" action={<div className="row"><button className="primary" onClick={() => navigate({ screen: online ? 'bot.create' : 'machine.attach' })}>{online ? 'Create a Bot' : 'Attach your host'}</button><button onClick={() => navigate({ screen: 'templates' })}>Explore templates</button></div>}><p>Bots run on an enrolled host you own, even when this app is closed. Attach a trusted host, wait for verified online status, then give your Bot a name and a focused job.</p></EmptyState></div>;
  return <div className="home"><EmptyState title="Message a Bot"><p>Pick a Bot on the left to pick up where you left off. Bots keep working on their machines while the app is closed.</p></EmptyState></div>;
}
interface Preview { entryId: string; text: string }
/** Last-message previews keyed by conversation, refreshed when a conversation's lastEntryId changes. */
function usePreviews(conversations: Conversation[]) {
  const { client, online } = useApp();
  const [previews, setPreviews] = useState<Record<string, Preview>>({});
  const key = conversations.map(room => `${room.id}:${room.lastEntryId || ''}`).join('|');
  useEffect(() => {
    if (!online) return;
    let cancelled = false;
    void (async () => {
      for (const room of conversations) {
        const lastId = room.lastEntryId;
        if (!lastId || previews[room.id]?.entryId === lastId) continue;
        try { const entry = await client.call('GET /entries/:id', { params: { id: lastId } }); const text = previewText(entry); if (!cancelled && text) setPreviews(current => ({ ...current, [room.id]: { entryId: lastId, text } })); } catch { /* A missing preview falls back to the Bot's job. */ }
      }
    })();
    return () => { cancelled = true; };
  }, [key, online]);
  return previews;
}
function sidebarDate(ms: number) { const date = new Date(ms), now = new Date(); if (date.toDateString() === now.toDateString()) return new Intl.DateTimeFormat(undefined, { hour: 'numeric', minute: '2-digit' }).format(date); if (now.getTime() - ms < 6 * 86400000) return date.toDateString() === new Date(now.getTime() - 86400000).toDateString() ? 'Yesterday' : new Intl.DateTimeFormat(undefined, { weekday: 'short' }).format(date); return new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric' }).format(date); }
interface MenuTarget { bot: Bot; x: number; y: number }
function Roster({ route, close, openPalette, unreadInbox, connection, reconnect, recovery }: { route: Route; close: () => void; openPalette: () => void; unreadInbox: number; connection: string | null; reconnect: () => void; recovery?: ReactNode }) {
  const { snapshot, client, navigate, refresh, online } = useApp();
  const [searching, setSearching] = useState(false); const [query, setQuery] = useState(''); const [unreadOnly, setUnreadOnly] = useState(false); const [showHidden, setShowHidden] = useState(false);
  const [menu, setMenu] = useState<MenuTarget>(); const [moreUnreads, setMoreUnreads] = useState(false);
  const [phone, setPhone] = useState(() => matchMedia('(max-width: 760px)').matches); useEffect(() => { const query = matchMedia('(max-width: 760px)'); const change = () => setPhone(query.matches); query.addEventListener('change', change); return () => query.removeEventListener('change', change); }, []);
  const phoneHome = phone && route.screen === 'home';
  const scroller = useRef<HTMLDivElement>(null); const searchInput = useRef<HTMLInputElement>(null);
  const action = useAction({ reconcileOnRefresh: true, available: online });
  const ordered = snapshot.bots.slice().sort((a, b) => a.sidebar.rank - b.sidebar.rank || a.name.localeCompare(b.name));
  const matches = (bot: Bot) => (!query || `${bot.name} ${bot.title} ${bot.job}`.toLowerCase().includes(query.toLowerCase())) && (!unreadOnly || bot.sidebar.unread);
  const visible = ordered.filter(bot => !bot.sidebar.hidden && matches(bot));
  const pinned = visible.filter(bot => bot.sidebar.pinned);
  const listed = visible.filter(bot => !bot.sidebar.pinned);
  const hidden = ordered.filter(bot => bot.sidebar.hidden && matches(bot));
  const rooms = snapshot.conversations.filter(room => room.kind === 'group' || room.kind === 'task').filter(room => !query || room.name.toLowerCase().includes(query.toLowerCase())).filter(room => !unreadOnly || room.unreadCount > 0).sort((a, b) => b.updatedAtMs - a.updatedAtMs).slice(0, 12);
  const previews = usePreviews(snapshot.conversations.filter(room => room.kind === 'group' || room.kind === 'task' || snapshot.bots.some(bot => bot.mainConversationId === room.id)));
  const selectedBot = (bot: Bot) => route.botId === bot.id || route.id === bot.mainConversationId;
  const open = (bot: Bot) => navigate({ screen: 'conversation', id: bot.mainConversationId, botId: bot.id });
  const mutate = (bot: Bot, changes: { pinned?: boolean; hidden?: boolean; unread?: boolean; sectionId?: string | null; rank?: number }) => void action.run(async () => { await client.call('PATCH /bots/:id/sidebar', { params: { id: bot.id }, body: { clientNonce: nonce(), revision: bot.revision, ...changes } }); await refresh(); });
  const live = (bot: Bot) => { const runs = snapshot.activeRuns.filter(run => run.botId === bot.id); const room = snapshot.conversations.find(item => item.id === bot.mainConversationId); return currentStep(runs, [], room); };
  useEffect(() => {
    const root = scroller.current; if (!root) return;
    const check = () => { const box = root.getBoundingClientRect(); setMoreUnreads([...root.querySelectorAll<HTMLElement>('[data-unread="true"]')].some(element => element.getBoundingClientRect().top > box.bottom - 8)); };
    check(); root.addEventListener('scroll', check, { passive: true }); window.addEventListener('resize', check);
    return () => { root.removeEventListener('scroll', check); window.removeEventListener('resize', check); };
  }, [snapshot.bots, snapshot.conversations]);
  useEffect(() => { if (!menu) return; const dismiss = (event: Event) => { if (!(event.target instanceof Element) || !event.target.closest('.context-menu')) setMenu(undefined); }; const key = (event: KeyboardEvent) => { if (event.key === 'Escape') setMenu(undefined); }; window.addEventListener('pointerdown', dismiss); window.addEventListener('keydown', key); return () => { window.removeEventListener('pointerdown', dismiss); window.removeEventListener('keydown', key); }; }, [menu]);
  const openMenu = (bot: Bot, x: number, y: number) => setMenu({ bot, x: Math.min(x, window.innerWidth - 250), y: Math.min(y, window.innerHeight - 380) });
  const renderBot = (bot: Bot) => {
    const step = live(bot); const needsYou = step?.needsInput || bot.activity === 'needs_input';
    const preview = previews[bot.mainConversationId]?.text;
    return <div key={bot.id} className={`roster-item ${selectedBot(bot) ? 'selected' : ''}`} data-unread={bot.sidebar.unread} onContextMenu={event => { event.preventDefault(); openMenu(bot, event.clientX, event.clientY); }}>
      <button className="bot-select" onClick={() => open(bot)} aria-current={selectedBot(bot) ? 'page' : undefined}>
        <BotAvatar bot={bot} size={40} presence={!connection}/>
        <span className="roster-text"><span className="roster-name"><strong>{bot.name}</strong>{bot.title && <span className="label-chip">{bot.title}</span>}</span>
          {needsYou ? <small className="needs-you">✋ Needs you</small> : step ? <small className="live-step">··· {step.title}…</small> : <small>{preview || bot.job || 'No messages yet'}</small>}</span>
        {bot.sidebar.unread && <span className="unread-dot" aria-label="Unread"/>}
      </button>
      <button className="row-more" aria-label={`More for ${bot.name}`} onClick={event => { const box = event.currentTarget.getBoundingClientRect(); openMenu(bot, box.left, box.bottom + 4); }}><MoreHorizontal size={16}/></button>
    </div>;
  };
  const sectioned = snapshot.sections.slice().sort((a, b) => a.rank - b.rank);
  const unsectioned = listed.filter(bot => !bot.sidebar.sectionId || !sectioned.some(section => section.id === bot.sidebar.sectionId));
  return <><button className="sidebar-scrim" aria-label="Close Bot list" onClick={close}/><aside className="roster" aria-label="Bots and chats">
    <div className="roster-top">
      <button className="roster-brand" aria-label="Lemon Bot home" onClick={() => navigate({ screen: 'home' })}><LemonMark size={26}/></button>
      <h1 className="roster-title">Chats</h1>
      {connection && <span className="connection-pill"><span className="status-dot needs_input"/>{connection}</span>}
      {connection && <button className="pill-button warning compact" onClick={reconnect}>Try again</button>}
      {phoneHome ? <details className="roster-filter"><summary className="ghost-circle" aria-label="Filter chats"><ListFilter size={18}/></summary><div className="menu" role="menu">
        <button role="menuitemcheckbox" aria-checked={unreadOnly} onClick={() => setUnreadOnly(value => !value)}>{unreadOnly ? '✓ ' : ''}Unread only</button>
        <button role="menuitemcheckbox" aria-checked={showHidden} onClick={() => setShowHidden(value => !value)}>{showHidden ? '✓ ' : ''}Show hidden</button>
        <button role="menuitem" onClick={openPalette}>Search everything</button>
        <button role="menuitem" onClick={() => navigate({ screen: 'group.create' })}>New group</button>
      </div></details> : <button className={`ghost-circle ${searching ? 'selected' : ''}`} aria-label="Search Bots and groups" aria-expanded={searching} title="Search" onClick={() => { setSearching(value => !value); if (searching) { setQuery(''); setUnreadOnly(false); } else requestAnimationFrame(() => searchInput.current?.focus()); }}><Search size={15}/></button>}
      <button className="ghost-circle" aria-label="New Bot (⌘N)" title="New Bot (⌘N)" onClick={() => navigate({ screen: 'bot.create' })}>{phoneHome ? <SquarePen size={18}/> : <Plus size={16}/>}</button>
    </div>
    {recovery}
    {(searching || phoneHome) && <div className="roster-search"><label className="search-field"><Search size={15} aria-hidden="true"/><span className="sr-only">Search Bots and groups</span><input ref={searchInput} placeholder="Search Bots and groups" value={query} onChange={event => setQuery(event.target.value)} onKeyDown={event => { if (event.key === 'Escape') { setQuery(''); setSearching(false); setUnreadOnly(false); } }}/></label>{!phoneHome && <><button className={`pill-button compact ${unreadOnly ? 'unread-on' : 'secondary'}`} aria-pressed={unreadOnly} onClick={() => setUnreadOnly(value => !value)}>Unread</button><button className="pill-button compact secondary" onClick={openPalette}>All</button></>}</div>}
    <div className="roster-scroll" ref={scroller}>
      {pinned.length > 0 && <div className="pinned-row" role="list" aria-label="Pinned Bots">{pinned.map(bot => <button key={bot.id} role="listitem" className={`pinned-tile ${selectedBot(bot) ? 'selected' : ''}`} data-unread={bot.sidebar.unread} onClick={() => open(bot)} onContextMenu={event => { event.preventDefault(); openMenu(bot, event.clientX, event.clientY); }}><BotAvatar bot={bot} size={56} presence={!connection} unread={bot.sidebar.unread}/><span>{bot.name}</span></button>)}</div>}
      <nav className="utility-rows" aria-label="Updates">
        <button className={route.screen === 'inbox' ? 'selected' : ''} onClick={() => navigate({ screen: 'inbox' })}><Inbox size={17}/><span>Inbox</span>{unreadInbox > 0 && <span className="count">{unreadInbox}</span>}</button>
        <button className={route.screen === 'activity' || route.screen === 'upcoming' ? 'selected' : ''} onClick={() => navigate({ screen: 'activity' })}><History size={17}/><span>Activity</span></button>
      </nav>
      {unsectioned.map(renderBot)}
      {sectioned.map(section => { const members = listed.filter(bot => bot.sidebar.sectionId === section.id); return <section className="roster-section" key={section.id}>
        <div className="roster-heading"><button aria-expanded={!section.collapsed} onClick={() => void action.run(async () => { await client.call('PATCH /sections/:id', { params: { id: section.id }, body: { clientNonce: nonce(), revision: section.revision, collapsed: !section.collapsed } }); await refresh(); })}><ChevronRight size={13} className="chevron"/>{section.name}</button>
          <details className="section-actions"><summary aria-label={`Edit ${section.name}`}><MoreHorizontal size={15}/></summary><div className="menu stack">
            <form onSubmit={event => { event.preventDefault(); const data = new FormData(event.currentTarget); void action.run(async () => { await client.call('PATCH /sections/:id', { params: { id: section.id }, body: { clientNonce: nonce(), revision: section.revision, name: String(data.get('name')) } }); await refresh(); }); }}><input name="name" aria-label="Section name" defaultValue={section.name} required/><button>Rename</button></form>
            <button onClick={() => void action.run(async () => { await client.call('PATCH /sections/:id', { params: { id: section.id }, body: { clientNonce: nonce(), revision: section.revision, rank: section.rank - 1 } }); await refresh(); })}>Move section up</button>
            <button onClick={() => { if (window.confirm(`Delete section “${section.name}”? Its Bots move to Unassigned; no Bot is deleted.`)) void action.run(async () => { await client.call('DELETE /sections/:id', { params: { id: section.id }, body: { clientNonce: nonce(), revision: section.revision } }); await refresh(); }); }}>Delete section only</button>
          </div></details>
        </div>
        {!section.collapsed && members.map(renderBot)}
      </section>; })}
      <div className="roster-heading"><span>Groups and tasks</span><button className="heading-plus" aria-label="New group" title="New group" onClick={() => navigate({ screen: 'group.create' })}><Plus size={14}/></button></div>
      {rooms.map(room => { const members = room.botIds.map(id => snapshot.bots.find(bot => bot.id === id)).filter((bot): bot is Bot => !!bot); const lead = members.find(bot => bot.id === room.leadBotId) || members[0]; return <div key={room.id} className={`roster-item ${route.id === room.id ? 'selected' : ''}`} data-unread={room.unreadCount > 0}><button className="bot-select" onClick={() => navigate({ screen: 'conversation', id: room.id })} aria-current={route.id === room.id ? 'page' : undefined}>
        {room.kind === 'group' ? <span className="avatar-stack" aria-hidden="true">{members.slice(0, 3).map(bot => <BotAvatar key={bot.id} bot={bot} size={26}/>)}</span> : <span className="task-avatar">{lead ? <BotAvatar bot={lead} size={30}/> : <LemonFace size={30}/>}<span className="branch-badge"><GitBranch size={9}/></span></span>}
        <span className="roster-text"><span className="roster-name"><strong>{room.name}</strong></span><small>{room.activity.length ? <span className="live-step">··· {room.activity[0].phase === 'typing' ? 'Writing a reply' : room.activity[0].phase === 'reading' ? 'Reading' : 'Working'}…</span> : previews[room.id]?.text || (room.kind === 'task' ? `Task · ${sidebarDate(room.updatedAtMs)}` : members.map(bot => bot.name).join(', '))}</small></span>
        {room.unreadCount > 0 && <span className="unread-dot" aria-label={`${room.unreadCount} unread`}/>}
      </button></div>; })}
      {rooms.length === 0 && <p className="roster-empty">No groups or tasks yet.</p>}
      {hidden.length > 0 && <button className="show-hidden" aria-expanded={showHidden} onClick={() => setShowHidden(value => !value)}>{showHidden ? 'Hide hidden Bots' : `Show ${hidden.length} hidden Bot${hidden.length === 1 ? '' : 's'}`}</button>}
      {showHidden && hidden.map(renderBot)}
      {visible.length === 0 && (query || unreadOnly) && <p className="roster-empty">{unreadOnly ? 'All caught up.' : 'No matching Bots.'}</p>}
      <ErrorNotice error={action.error}/>
    </div>
    {moreUnreads && <button className="more-unreads" onClick={() => { const root = scroller.current; const box = root?.getBoundingClientRect(); const target = root && box ? [...root.querySelectorAll<HTMLElement>('[data-unread="true"]')].find(element => element.getBoundingClientRect().top > box.bottom - 8) : undefined; target?.scrollIntoView({ behavior: 'smooth', block: 'center' }); }}><ArrowDown size={14}/>More unreads</button>}
    <div className="roster-footer">
      <button className="account-button" aria-label={`Settings — ${snapshot.user.displayName}`} title="Settings (⌘,)" onClick={() => navigate({ screen: 'settings' })}><AccountAvatar name={snapshot.user.displayName}/></button>
      <button className="connect-pill" onClick={() => navigate({ screen: 'connect.apps' })}>Connect apps<LayoutGrid size={14}/></button>
    </div>
    {menu && <div className="menu context-menu" role="menu" style={{ left: menu.x, top: menu.y }} onClick={event => { if ((event.target as Element).closest('button')) setMenu(undefined); }}>
      <button role="menuitem" onClick={() => open(menu.bot)}>Open chat</button>
      <button role="menuitem" onClick={() => navigate({ screen: 'bot.overview', id: menu.bot.id, botId: menu.bot.id })}>Bot details</button>
      <button role="menuitem" onClick={() => navigate({ screen: 'activity', botId: menu.bot.id })}>Activity</button>
      <hr/>
      <button role="menuitem" onClick={() => mutate(menu.bot, { pinned: !menu.bot.sidebar.pinned })}>{menu.bot.sidebar.pinned ? 'Unpin' : 'Pin'}</button>
      <button role="menuitem" onClick={() => mutate(menu.bot, { unread: !menu.bot.sidebar.unread })}>{menu.bot.sidebar.unread ? 'Mark read' : 'Mark unread'}</button>
      <button role="menuitem" onClick={() => mutate(menu.bot, { hidden: !menu.bot.sidebar.hidden })}>{menu.bot.sidebar.hidden ? 'Unhide' : 'Hide (work continues)'}</button>
      <hr/>
      <label className="menu-item menu-select" onClick={event => event.stopPropagation()}>Move to section<select value={menu.bot.sidebar.sectionId || ''} onChange={event => { const bot = menu.bot; setMenu(undefined); if (event.target.value === '__new') { const name = window.prompt('New section name'); if (name?.trim()) void action.run(async () => { const section = await client.call('POST /sections', { body: { clientNonce: nonce(), name: name.trim(), rank: snapshot.sections.length } }); await client.call('PATCH /bots/:id/sidebar', { params: { id: bot.id }, body: { clientNonce: nonce(), revision: bot.revision, sectionId: section.id } }); await refresh(); }); } else mutate(bot, { sectionId: event.target.value || null }); }}><option value="">None</option>{snapshot.sections.map(section => <option key={section.id} value={section.id}>{section.name}</option>)}<option value="__new">New section…</option></select></label>
      <button role="menuitem" onClick={() => mutate(menu.bot, { rank: menu.bot.sidebar.rank - 1 })}>Move up</button>
      <button role="menuitem" onClick={() => mutate(menu.bot, { rank: menu.bot.sidebar.rank + 1 })}>Move down</button>
      <hr/>
      <button role="menuitem" onClick={() => navigate({ screen: 'bot.settings', id: menu.bot.id, botId: menu.bot.id })}>Bot settings</button>
    </div>}
  </aside></>;
}
