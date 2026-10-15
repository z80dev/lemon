import { createContext, useContext, useEffect, useMemo, useRef, useState } from 'react';
import { LemonBotClient, nonce, type Bot, type Device, type RealtimeConnection, type RealtimeEvent, type Resource, type Snapshot } from '@lemon-bot/sdk';
import { AuthScreen, savedAccounts, type WebSession } from './auth';
import { Bell, CalendarClock, Menu, Plus, RefreshCw, Search, Activity as ActivityIcon, Plug } from 'lucide-react';
import { Badge, BotAvatar, EmptyState, ErrorNotice, Field, LemonFace, LemonMark, Loading, presenceLabel, useAction } from './ui';
import { BotsScreen } from './features/bots';
import { ConversationScreen, FileViewer, VoiceOverlay } from './features/chat';
import { MachinesScreen } from './features/machines';
import { WorkScreen } from './features/work';
import { SettingsScreen } from './features/settings';
import { OwnerControlsScreen } from './features/enterprise';
import { PairingScreen } from './features/pairing';
import { ActivityScreen, Palette, SearchScreen, settingsDestinations } from './navigation';

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
  return session ? <Workspace key={`${session.baseUrl}:${session.token}`} session={session} onLogout={forget} /> : <AuthScreen onAuth={setSession} initialBackend={initialBackend}/>;
}
function Workspace({ session, onLogout }: { session: WebSession; onLogout: () => void }) {
  const client = useMemo(() => new LemonBotClient({ baseUrl: session.baseUrl, token: session.token }), [session]);
  const [snapshot, setSnapshot] = useState<Snapshot>(); const snapshotRef = useRef<Snapshot | undefined>(undefined);
  const [device, setDevice] = useState<Device | null>(null); const [realtime, setRealtime] = useState<RealtimeConnection | null>(null);
  const [error, setError] = useState<unknown>(); const [connection, setConnection] = useState('connecting'); const [browserOnline, setBrowserOnline] = useState(navigator.onLine);
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
  const sync = async () => {
    const value = await client.call('GET /sync');
    // Snapshot bounds are explicit. Page each flagged collection, keeping newer revisions.
    if (value.hasMore.bots) { let cursor: string | undefined; do { const page = await client.call('GET /bots', { query: { limit: 200, cursor } }); for (const item of page.items) value.bots = upsert(value.bots, item); cursor = page.nextCursor || undefined; } while (cursor); }
    if (value.hasMore.machines) { let cursor: string | undefined; do { const page = await client.call('GET /machines', { query: { limit: 200, cursor } }); for (const item of page.items) value.machines = upsert(value.machines, item); cursor = page.nextCursor || undefined; } while (cursor); }
    if (value.hasMore.conversations) { let cursor: string | undefined; do { const page = await client.call('GET /conversations', { query: { limit: 200, cursor } }); for (const item of page.items) value.conversations = upsert(value.conversations, item); cursor = page.nextCursor || undefined; } while (cursor); }
    if (value.hasMore.notifications) { let cursor: string | undefined; do { const page = await client.call('GET /notifications', { query: { limit: 200, cursor } }); for (const item of page.items) value.notifications = upsert(value.notifications, item); cursor = page.nextCursor || undefined; } while (cursor); }
    if (value.sections.length >= 200) { let cursor: string | undefined; do { const page = await client.call('GET /sections', { query: { limit: 200, cursor } }); for (const item of page.items) value.sections = upsert(value.sections, item); cursor = page.nextCursor || undefined; } while (cursor); }
    update(value); return value;
  };
  const refresh = async () => { await sync(); window.dispatchEvent(new Event('lemon:refresh')); };
  const logout = async () => { try { await client.call('POST /auth/logout', { body: { clientNonce: nonce() } }); } catch (failure) { setError(failure); } finally { realtime?.close(); sessionStorage.removeItem(`lemonbot.cursor:${session.baseUrl}:${session.workspaceId}`); onLogout(); } };
  useEffect(() => {
    let disposed = false; let socket: RealtimeConnection | undefined;
    void (async () => {
      try {
        const value = await sync(); if (disposed) return;
        let registration: Device | undefined;
        try { let installationId = localStorage.getItem('lemonbot.installation'); if (!installationId) { installationId = nonce(); localStorage.setItem('lemonbot.installation', installationId); }
          registration = await client.call('POST /devices', { body: { clientNonce: nonce(), installationId, platform: 'web', name: 'Web browser', appVersion: '1.0.0' } }); if (disposed) return; setDevice(registration);
        } catch (failure) { if (!disposed) reportError(failure); }
        socket = client.realtime({ deviceId: registration?.id, cursor: value.cursor, onEvent: async event => {
          if (disposed) return; if (snapshotRef.current) update(applySnapshotEvent(snapshotRef.current, event));
          if (event.event === 'conversation.deleted') forgetConversation(event.payload.id);
          window.dispatchEvent(new CustomEvent('lemon:event', { detail: event }));
        }, onState: (state, failure) => { if (disposed) return; setConnection(state); if (failure) reportError(failure); if (state === 'unauthenticated' || state === 'forbidden') { sessionStorage.removeItem('lemonbot.session'); onLogout(); } }, onReset: async () => { const fresh = await sync(); window.dispatchEvent(new Event('lemon:refresh')); return fresh; }, saveCursor: cursor => sessionStorage.setItem(`lemonbot.cursor:${session.baseUrl}:${session.workspaceId}`, cursor) });
        setRealtime(socket); socket.start();
      } catch (failure) { if (!disposed) { setError(failure); setConnection('error'); } }
    })();
    return () => { disposed = true; socket?.close(); };
  }, [client]);
  useEffect(() => { const change = () => setRoute(initialRoute()); const online = () => setBrowserOnline(navigator.onLine); window.addEventListener('hashchange', change); window.addEventListener('online', online); window.addEventListener('offline', online); return () => { window.removeEventListener('hashchange', change); window.removeEventListener('online', online); window.removeEventListener('offline', online); }; }, []);
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
      const modifier = event.metaKey || event.ctrlKey;
      if (modifier && event.key.toLowerCase() === 'k') { event.preventDefault(); setPalette(value => !value); return; }
      if ((event.target instanceof HTMLElement) && (event.target.closest('input,textarea,select,[contenteditable="true"]') || event.target.closest('[role="dialog"]'))) return;
      if (event.key === 'Escape') { setSidebar(false); setPalette(false); return; }
      if (!modifier || !snapshotRef.current) return;
      if (event.shiftKey && event.key.toLowerCase() === 'f') { event.preventDefault(); navigate({ screen: 'search', tab: 'bot' }); }
      else if (event.key.toLowerCase() === 'n') { event.preventDefault(); navigate({ screen: 'bot.create' }); }
      else if (event.key.toLowerCase() === 'b') { event.preventDefault(); setSidebar(value => !value); }
      else if (event.key === ',') { event.preventDefault(); navigate({ screen: event.shiftKey ? 'bot.settings' : 'settings.account', id: route.botId, botId: route.botId }); }
      else if (/^[1-9]$/.test(event.key)) { const bot = snapshotRef.current.bots.filter(item => !item.sidebar.hidden).sort((a, b) => a.sidebar.rank - b.sidebar.rank)[Number(event.key) - 1]; if (bot) { event.preventDefault(); navigate({ screen: 'conversation', id: bot.mainConversationId, botId: bot.id }); } }
    }; window.addEventListener('keydown', keyboard); return () => window.removeEventListener('keydown', keyboard);
  }, [route.botId]);
  if (!snapshot) return <main className="boot stack"><div className="brand"><LemonMark/>Lemon Bot</div>{error ? <><ErrorNotice error={error}/><button onClick={() => void refresh().catch(reportError)}>Reconnect to backend</button><button onClick={onLogout}>Choose another account</button></> : <Loading/>}</main>;
  const requiredVersion = snapshot.capabilities.minClientVersions.web;
  const requiredParts = requiredVersion.split('.').map(Number);
  const updateRequired = requiredParts[0] > 1 || requiredParts[0] === 1 && (requiredParts[1] > 0 || requiredParts[2] > 0);
  if (updateRequired) return <main className="boot stack"><div className="brand"><LemonMark/>Lemon Bot</div><h1>A client update is required</h1><p>This web client is 1.0.0; your backend requires {requiredVersion}. Ask the operator to build and deploy the matching web assets, then reload. Updating the client does not recreate your machines or remove work.</p><button className="primary" onClick={() => location.reload()}>Reload installed assets</button><button onClick={() => void logout()}>Sign out</button></main>;
  const activeBot = snapshot.bots.find(bot => bot.id === (route.botId || (route.screen.startsWith('bot.') || route.screen === 'memory' ? route.id : undefined))) || (route.screen === 'conversation' ? snapshot.bots.find(bot => bot.mainConversationId === route.id || snapshot.conversations.find(room => room.id === route.id)?.botIds.includes(bot.id)) : undefined);
  const appearance = snapshot.user.preferences.appearance;
  const context: AppContextValue = { client, realtime, snapshot, device, online: browserOnline && connection === 'live', navigate, refresh, reportError, logout, forgetConversation, draftPrompt: (conversationId, text) => {
    sessionStorage.setItem(`lemonbot.prompt:${snapshot.workspace.id}:${snapshot.user.id}:${conversationId}`, text);
    window.dispatchEvent(new CustomEvent('lemonbot:draft-prompt', { detail: { conversationId, text } })); navigate({ screen: 'conversation', id: conversationId, botId: snapshot.conversations.find(room => room.id === conversationId)?.botIds[0] });
  } };
  const unreadInbox = snapshot.notifications.filter(item => item.readAtMs === null && item.dismissedAtMs === null).length;
  const conversationScreen = route.screen === 'conversation';
  return <AppContext.Provider value={context}><div className={`workspace ${sidebar ? 'sidebar-open' : ''} ${conversationScreen ? 'in-conversation' : ''} ${route.screen === 'home' ? 'at-home' : ''}`} data-theme={appearance}><a className="skip-link" href="#main-content">Skip to workspace content</a><Roster route={route} close={() => setSidebar(false)} openPalette={() => setPalette(true)} unreadInbox={unreadInbox}/><div className="workspace-main">{!conversationScreen && <header className="workspace-bar"><button className="icon-button mobile-menu" aria-label="Open Bot roster" onClick={() => setSidebar(value => !value)}><Menu size={20}/></button>{activeBot ? <button className="companion-anchor" onClick={() => navigate({ screen: 'conversation', id: activeBot.mainConversationId, botId: activeBot.id })}><BotAvatar bot={activeBot} size={28}/><span><strong>{activeBot.name}</strong><small><span className={`status-dot ${activeBot.activity}`}/>{presenceLabel(activeBot.activity)} · {snapshot.machines.find(machine => machine.id === activeBot.machineId)?.name || 'Assigned machine'}</small></span></button> : <button className="workspace-label brand" onClick={() => navigate({ screen: 'home' })}><LemonMark size={26}/><strong>Lemon Bot</strong></button>}<div className="row workspace-tools">{!(connection === 'live' && browserOnline) && <Badge tone="warning">{!browserOnline ? 'Offline' : connection === 'live' ? 'Live' : connection}</Badge>}<button aria-label="Search and commands" className="search-command" onClick={() => setPalette(true)}><Search size={15}/><span>Search</span><kbd>⌘K</kbd></button><button className="icon-button" aria-label="Inbox" onClick={() => navigate({ screen: 'inbox' })}><Bell size={18}/>{unreadInbox > 0 && <span className="icon-badge">{unreadInbox}</span>}</button><button className="icon-button" aria-label="Refresh workspace" onClick={() => void refresh().catch(reportError)}><RefreshCw size={17}/></button></div></header>}<main id="main-content" className="main-content" tabIndex={-1}>{!!error && <div className="global-error"><ErrorNotice error={error}/><button onClick={() => setError(undefined)}>Dismiss local notice</button></div>}{!context.online && <div className="connection-banner" role="status">{browserOnline ? 'Reconnecting. Retained activity may be stale; do not assume work stopped.' : 'Offline. Unsent drafts are kept, but approvals and destructive actions are never queued.'}</div>}<Destination route={route} activeBot={activeBot}/></main></div>{palette && <Palette close={() => setPalette(false)}/>}<VoiceOverlay/></div></AppContext.Provider>;
}
function Destination({ route, activeBot }: { route: Route; activeBot?: Bot }) {
  const { snapshot, navigate } = useApp();
  if (route.screen === 'home') return <Home/>;
  if (route.screen === 'conversation') return <ConversationScreen route={route}/>;
  if (route.screen === 'file.viewer') return <FileViewer route={route}/>;
  if (route.screen === 'decision') return <DecisionLink route={route}/>;
  if (['search'].includes(route.screen)) return <SearchScreen route={route}/>;
  if (['activity', 'upcoming'].includes(route.screen)) return <ActivityScreen route={route}/>;
  if (route.screen.startsWith('machine') || route.screen === 'machines') return <MachinesScreen route={route}/>;
  if (['skills', 'routines', 'connect.apps', 'connector.setup', 'integrations.channels', 'integrations.email', 'integrations.x'].includes(route.screen)) return <WorkScreen route={{ ...route, screen: route.screen === 'connector.setup' ? 'connect.apps' : route.screen }}/>;
  if (route.screen.startsWith('settings.') || route.screen === 'device.pairing') {
    const controls = ['settings.identity', 'settings.network', 'settings.setup', 'settings.usage.limit'].includes(route.screen);
    return <><nav className="settings-nav" aria-label="Settings sections">{settingsDestinations.map(([screen, label]) => <button key={screen} className={route.screen === screen ? 'selected' : ''} onClick={() => navigate({ screen })}>{label}</button>)}</nav>{route.screen === 'device.pairing' ? <PairingScreen/> : controls ? <OwnerControlsScreen route={route}/> : <SettingsScreen route={route}/>}</>;
  }
  if (route.screen === 'inbox') return <SettingsScreen route={route}/>;
  if (route.screen.startsWith('bot.') || ['templates', 'memory', 'memory.import', 'preference.changes', 'group.create', 'group.edit', 'voice.preview'].includes(route.screen)) return <BotsScreen route={{ ...route, id: route.id || activeBot?.id, botId: route.botId || activeBot?.id }}/>;
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
  const bots = snapshot.bots.filter(bot => !bot.sidebar.hidden).sort((a, b) => Number(b.sidebar.pinned) - Number(a.sidebar.pinned) || a.sidebar.rank - b.sidebar.rank || a.name.localeCompare(b.name));
  const recent = snapshot.conversations.filter(room => room.kind !== 'dm' || snapshot.bots.some(bot => bot.mainConversationId === room.id && !bot.sidebar.hidden)).sort((a, b) => b.updatedAtMs - a.updatedAtMs).slice(0, 12);
  const unreadInbox = snapshot.notifications.filter(item => item.readAtMs === null && item.dismissedAtMs === null).length;
  const when = (ms: number) => { const date = new Date(ms); return date.toDateString() === new Date().toDateString() ? new Intl.DateTimeFormat(undefined, { timeStyle: 'short' }).format(date) : new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric' }).format(date); };
  return <div className="home">
    <section className="home-hero"><LemonFace size={64}/><h1>Message a Bot</h1><p className="muted">Pick up where you left off, or start something new.</p></section>
    <div className="home-bots" role="list" aria-label="Your Bots">{bots.slice(0, 10).map(bot => <button role="listitem" className="home-bot" key={bot.id} onClick={() => navigate({ screen: 'conversation', id: bot.mainConversationId, botId: bot.id })}><span className="avatar-wrap"><BotAvatar bot={bot} size={60}/>{bot.activity !== 'idle' && <span className={`presence-badge ${bot.activity}`} aria-label={presenceLabel(bot.activity)}/>}{bot.sidebar.unread && <span className="unread-badge" aria-label="Unread"/>}</span><strong>{bot.name}</strong></button>)}<button className="home-bot home-bot-new" onClick={() => navigate({ screen: 'bot.create' })}><span className="new-avatar"><Plus size={24}/></span><strong>New Bot</strong></button></div>
    <section className="home-recent" aria-labelledby="home-recent-title"><h2 id="home-recent-title" className="section-label">Recent conversations</h2>
      <div className="list-plain">{recent.map(room => { const bot = snapshot.bots.find(item => room.kind === 'dm' ? item.mainConversationId === room.id : item.id === (room.leadBotId || room.botIds[0])); const name = room.kind === 'dm' && bot ? bot.name : room.name; const subtitle = room.activity.length ? `${snapshot.bots.find(item => item.id === room.activity[0].botId)?.name || 'A Bot'} is ${room.activity[0].phase}…` : room.kind === 'dm' ? (bot?.title || bot?.job || presenceLabel(bot?.activity || 'idle')) : room.kind === 'task' ? `Task${bot ? ` · ${bot.name}` : ''}` : `${room.botIds.length} Bots`; return <button className="convo-row" key={room.id} onClick={() => navigate({ screen: 'conversation', id: room.id, botId: room.kind === 'dm' ? bot?.id : undefined })}>{bot ? <BotAvatar bot={bot} size={44}/> : <LemonFace size={44}/>}<span className="convo-text"><span className="convo-top"><strong>{name}</strong>{room.kind !== 'dm' && <span className="chip">{room.kind === 'task' ? 'Task' : room.kind === 'group' ? 'Group' : 'Channel'}</span>}<time>{when(room.updatedAtMs)}</time></span><small>{subtitle}</small></span>{(room.unreadCount > 0 || (room.kind === 'dm' && bot?.sidebar.unread)) && <span className="unread-dot" aria-label="Unread"/>}</button>; })}</div>
    </section>
    <nav className="home-links" aria-label="Updates"><button onClick={() => navigate({ screen: 'inbox' })}><Bell size={15}/>Inbox{unreadInbox > 0 && <span className="count">{unreadInbox}</span>}</button><button onClick={() => navigate({ screen: 'activity' })}><ActivityIcon size={15}/>Activity</button><button onClick={() => navigate({ screen: 'upcoming' })}><CalendarClock size={15}/>Upcoming</button></nav>
  </div>;
}
function Roster({ route, close, openPalette, unreadInbox }: { route: Route; close: () => void; openPalette: () => void; unreadInbox: number }) {
  const { snapshot, client, navigate, refresh, logout, online } = useApp();
  const [filter, setFilter] = useState<'all' | 'unread' | 'hidden'>('all');
  const [sectionName, setSectionName] = useState('');
  const action = useAction({ reconcileOnRefresh: true, available: online });
  const bots = snapshot.bots.filter(bot => filter === 'hidden' ? bot.sidebar.hidden : !bot.sidebar.hidden && (filter !== 'unread' || bot.sidebar.unread)).sort((a, b) => Number(b.sidebar.pinned) - Number(a.sidebar.pinned) || a.sidebar.rank - b.sidebar.rank || a.name.localeCompare(b.name));
  const mutate = (bot: Bot, changes: { pinned?: boolean; hidden?: boolean; unread?: boolean; sectionId?: string | null; rank?: number }) => void action.run(async () => { await client.call('PATCH /bots/:id/sidebar', { params: { id: bot.id }, body: { clientNonce: nonce(), revision: bot.revision, ...changes } }); await refresh(); });
  const renderBot = (bot: Bot) => <div key={bot.id} className={`roster-item ${route.botId === bot.id || route.id === bot.mainConversationId ? 'selected' : ''}`}>
    <button className="bot-select" onClick={() => navigate({ screen: 'conversation', id: bot.mainConversationId, botId: bot.id })}><span className="avatar-wrap"><BotAvatar bot={bot} size={40}/>{bot.activity !== 'idle' && <span className={`presence-badge ${bot.activity}`} aria-hidden="true"/>}</span><span className="roster-text"><span className="roster-name"><strong>{bot.name}</strong>{bot.sidebar.pinned && <span className="pin-mark" aria-label="Pinned">•</span>}</span><small className={bot.activity}>{bot.activity === 'idle' ? (bot.title || bot.job || 'Idle') : `${presenceLabel(bot.activity)}${bot.activity === 'working' || bot.activity === 'making' ? '…' : ''}`}</small></span>{bot.sidebar.unread && <span className="unread-dot" aria-label="Unread"/>}</button>
    <details className="roster-actions"><summary aria-label={`Organize ${bot.name}`}>⋯</summary><div className="menu stack">
      <button onClick={() => mutate(bot, { pinned: !bot.sidebar.pinned })}>{bot.sidebar.pinned ? 'Unpin' : 'Pin'}</button>
      <button onClick={() => mutate(bot, { hidden: !bot.sidebar.hidden })}>{bot.sidebar.hidden ? 'Unhide' : 'Hide · work continues'}</button>
      <button onClick={() => mutate(bot, { unread: !bot.sidebar.unread })}>{bot.sidebar.unread ? 'Mark read' : 'Mark unread'}</button>
      <Field label="Section"><select value={bot.sidebar.sectionId || ''} onChange={event => mutate(bot, { sectionId: event.target.value || null })}><option value="">Unassigned</option>{snapshot.sections.map(section => <option key={section.id} value={section.id}>{section.name}</option>)}</select></Field>
      <div className="row"><button onClick={() => mutate(bot, { rank: bot.sidebar.rank - 1 })}>Move up</button><button onClick={() => mutate(bot, { rank: bot.sidebar.rank + 1 })}>Move down</button></div>
      <button onClick={() => navigate({ screen: 'bot.settings', id: bot.id, botId: bot.id })}>Bot settings</button>
    </div></details>
  </div>;
  return <><button className="sidebar-scrim" aria-label="Close roster" onClick={close}/><aside className="roster">
    <div className="roster-top">
      <button className="brand" onClick={() => navigate({ screen: 'home' })}><LemonMark size={28}/>Lemon Bot</button>
      <button className="round-button" aria-label="Search (⌘K)" title="Search (⌘K)" onClick={openPalette}><Search size={17}/></button>
      <details className="roster-new"><summary className="round-button" aria-label="New Bot, section or group" title="New (⌘N)"><Plus size={18}/></summary><div className="menu stack">
        <button onClick={() => navigate({ screen: 'bot.create' })}>New Bot</button><button onClick={() => navigate({ screen: 'templates' })}>Templates</button>
        <form onSubmit={event => { event.preventDefault(); void action.run(async () => { await client.call('POST /sections', { body: { clientNonce: nonce(), name: sectionName, rank: snapshot.sections.length } }); setSectionName(''); await refresh(); }); }}><Field label="New section"><input required value={sectionName} onChange={event => setSectionName(event.target.value)}/></Field><button>Create section</button></form>
        <button onClick={() => navigate({ screen: 'group.create' })}>Group your Bots</button>
      </div></details>
    </div>
    <nav className="roster-shortcuts" aria-label="Updates">
      <button className={route.screen === 'inbox' ? 'selected' : ''} onClick={() => navigate({ screen: 'inbox' })}><Bell size={14}/>Inbox{unreadInbox > 0 && <span className="count">{unreadInbox}</span>}</button>
      <button className={route.screen === 'activity' ? 'selected' : ''} onClick={() => navigate({ screen: 'activity' })}>Activity</button>
      <button className={route.screen === 'upcoming' ? 'selected' : ''} onClick={() => navigate({ screen: 'upcoming' })}>Upcoming</button>
    </nav>
    <div className="roster-filters" aria-label="Roster filter">{(['all', 'unread', 'hidden'] as const).map(value => <button key={value} aria-pressed={filter === value} className={filter === value ? 'selected' : ''} onClick={() => setFilter(value)}>{value}</button>)}</div>
    <div className="roster-scroll">
      {bots.filter(bot => bot.sidebar.pinned).map(renderBot)}
      {snapshot.sections.slice().sort((a, b) => a.rank - b.rank).map(section => <section className="roster-section" key={section.id}>
        <div className="roster-heading"><button aria-expanded={!section.collapsed} onClick={() => void action.run(async () => { await client.call('PATCH /sections/:id', { params: { id: section.id }, body: { clientNonce: nonce(), revision: section.revision, collapsed: !section.collapsed } }); await refresh(); })}>{section.collapsed ? '›' : '⌄'} {section.name}</button>
          <details><summary aria-label={`Edit ${section.name}`}>⋯</summary><div className="menu stack">
            <form onSubmit={event => { event.preventDefault(); const data = new FormData(event.currentTarget); void action.run(async () => { await client.call('PATCH /sections/:id', { params: { id: section.id }, body: { clientNonce: nonce(), revision: section.revision, name: String(data.get('name')) } }); await refresh(); }); }}><input name="name" aria-label="Section name" defaultValue={section.name} required/><button>Rename</button></form>
            <button onClick={() => void action.run(async () => { await client.call('PATCH /sections/:id', { params: { id: section.id }, body: { clientNonce: nonce(), revision: section.revision, rank: section.rank - 1 } }); await refresh(); })}>Move section up</button>
            <button onClick={() => { if (window.confirm(`Delete section “${section.name}”? Its Bots move to Unassigned; no Bot is deleted.`)) void action.run(async () => { await client.call('DELETE /sections/:id', { params: { id: section.id }, body: { clientNonce: nonce(), revision: section.revision } }); await refresh(); }); }}>Delete section only</button>
          </div></details>
        </div>
        {!section.collapsed && bots.filter(bot => !bot.sidebar.pinned && bot.sidebar.sectionId === section.id).map(renderBot)}
      </section>)}
      {bots.filter(bot => !bot.sidebar.pinned && (!bot.sidebar.sectionId || !snapshot.sections.some(section => section.id === bot.sidebar.sectionId))).map(renderBot)}
      {snapshot.conversations.some(room => room.kind === 'group') && <><div className="roster-heading">Groups</div>{snapshot.conversations.filter(room => room.kind === 'group').map(room => <div key={room.id} className={`roster-item ${route.id === room.id ? 'selected' : ''}`}><button className="bot-select" onClick={() => navigate({ screen: 'conversation', id: room.id })}><LemonFace size={40}/><span className="roster-text"><span className="roster-name"><strong>{room.name}</strong></span><small>{room.botIds.length} Bots</small></span>{room.unreadCount > 0 && <span className="unread-dot" aria-label={`${room.unreadCount} unread`}/>}</button></div>)}</>}
      {bots.length === 0 && <p className="muted small roster-empty">{filter === 'unread' ? 'All caught up.' : filter === 'hidden' ? 'No hidden Bots.' : 'Your first Bot starts here.'}</p>}
      <ErrorNotice error={action.error}/>
    </div>
    <div className="roster-footer">
      <details className="roster-account"><summary className="user-initial" aria-label="Account and settings" title={`${snapshot.user.displayName} · ${snapshot.workspace.name}`}>{snapshot.user.displayName.slice(0, 1)}</summary><div className="menu account-menu stack">
        <div className="account-who"><strong>{snapshot.user.displayName}</strong><small>{snapshot.workspace.name}</small></div>
        <button onClick={() => navigate({ screen: 'settings.account' })}>Settings & account</button>
        <button onClick={() => navigate({ screen: 'machines' })}>Hosts & files</button>
        <button onClick={() => navigate({ screen: 'skills' })}>Skills</button>
        <button onClick={() => navigate({ screen: 'routines' })}>Routines</button>
        <button onClick={() => navigate({ screen: 'device.pairing' })}>Connect iPhone</button>
        <button onClick={() => navigate({ screen: 'settings.workspace' })}>Cluster settings</button>
        <button onClick={() => void logout()}>Sign out / switch account</button>
      </div></details>
      <button className="connect-pill" onClick={() => navigate({ screen: 'connect.apps' })}><Plug size={15}/>Connect apps</button>
    </div>
  </aside></>;
}
