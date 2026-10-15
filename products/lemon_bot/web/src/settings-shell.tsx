import type { ComponentType, CSSProperties } from 'react';
import { BarChart3, Briefcase, ChevronLeft, ChevronRight, Globe, Info, LayoutGrid, Library, Monitor, ShieldCheck, SlidersHorizontal, Smartphone, UserCircle, type LucideProps } from 'lucide-react';
import { useApp, type Route } from './app';
import { AccountAvatar } from './ui';
import { BotsScreen } from './features/bots';
import { OwnerControlsScreen } from './features/enterprise';
import { MachinesScreen } from './features/machines';
import { PairingScreen } from './features/pairing';
import { SettingsScreen } from './features/settings';
import { WorkScreen } from './features/work';
import './settings-shell.css';

type PaneId = 'account' | 'devices' | 'machines' | 'apps' | 'library' | 'policies' | 'usage' | 'network' | 'workspace' | 'preferences' | 'instance' | 'about';
interface Segment { screen: string; label: string; owner?: boolean; match?: (screen: string) => boolean }
interface Pane { id: PaneId; title: string; subtitle: string; icon: ComponentType<LucideProps>; color: string; segments: Segment[] }

const panes: Pane[] = [
  { id: 'account', title: 'Account', subtitle: 'Your profile, saved accounts and sign-in.', icon: UserCircle, color: '#8A9A5B', segments: [{ screen: 'settings.account', label: 'Account' }] },
  { id: 'devices', title: 'Devices', subtitle: 'Connect a phone and manage devices signed in to your account.', icon: Smartphone, color: '#3F6FA3', segments: [{ screen: 'device.pairing', label: 'Devices' }] },
  { id: 'machines', title: 'Computers', subtitle: 'The computers your Bots work on.', icon: Monitor, color: '#5F6B73', segments: [{ screen: 'machines', label: 'Computers', match: screen => screen.startsWith('machine') }, { screen: 'settings.setup', label: 'Host setup' }] },
  { id: 'apps', title: 'Connections', subtitle: 'Connected apps, channels, email and X.', icon: LayoutGrid, color: '#6A5CA8', segments: [{ screen: 'connect.apps', label: 'Apps', match: screen => screen === 'connect.apps' || screen === 'connector.setup' }, { screen: 'integrations.channels', label: 'Channels' }, { screen: 'integrations.email', label: 'Email' }, { screen: 'integrations.x', label: 'X' }] },
  { id: 'library', title: 'Library', subtitle: 'Skills, routines, templates and Bot memory.', icon: Library, color: '#B0643A', segments: [{ screen: 'skills', label: 'Skills' }, { screen: 'routines', label: 'Routines' }, { screen: 'templates', label: 'Templates' }] },
  { id: 'policies', title: 'Policies', subtitle: 'What Bots may do on their own and when they ask first.', icon: ShieldCheck, color: '#4F7D55', segments: [{ screen: 'settings.policies', label: 'Policies' }] },
  { id: 'usage', title: 'Usage', subtitle: 'Token use, measured cost and spend limits.', icon: BarChart3, color: '#A2557A', segments: [{ screen: 'settings.usage', label: 'Usage' }, { screen: 'settings.usage.limit', label: 'Spend limits' }] },
  { id: 'network', title: 'Network', subtitle: 'Outbound network rules for Bot work.', icon: Globe, color: '#2F7F8F', segments: [{ screen: 'settings.network', label: 'Network' }] },
  { id: 'workspace', title: 'Workspace', subtitle: 'Workspace name, Bot sections, providers and cleanup.', icon: Briefcase, color: '#7A6A3A', segments: [{ screen: 'settings.workspace', label: 'Workspace' }, { screen: 'settings.identity', label: 'Sign-in providers' }, { screen: 'settings.account-cleanup', label: 'Account cleanup', owner: true }] },
  { id: 'preferences', title: 'Preferences', subtitle: 'Appearance, notifications, voice and accessibility.', icon: SlidersHorizontal, color: '#6E766B', segments: [{ screen: 'settings.notifications', label: 'Notifications' }, { screen: 'settings.voice', label: 'Voice' }] },
  { id: 'instance', title: 'Lemon instance', subtitle: 'The Lemon Bot service, its Lemon link and runtime controls.', icon: Monitor, color: '#4F7D55', segments: [{ screen: 'settings.instance', label: 'Lemon instance' }] },
  { id: 'about', title: 'About', subtitle: 'Web client, worker versions and support diagnostics.', icon: Info, color: '#8E8E86', segments: [{ screen: 'settings.about', label: 'About' }] },
];
const account = panes[0];
const listed = panes.slice(1);

const segmentMatches = (segment: Segment, screen: string) => segment.match ? segment.match(screen) : segment.screen === screen;

/** Every `route.screen` the settings shell renders. Machine screens are matched by prefix (`machine*`) in {@link isSettingsScreen}; the explicit ones are listed here. */
export const settingsScreens: Record<string, true> = Object.fromEntries([
  'settings',
  ...panes.flatMap(pane => pane.segments.map(segment => segment.screen)),
  'machine.detail', 'machine.attach', 'machine.terminal', 'machine.secrets', 'machine.files', 'machines.operations', 'connector.setup',
].map(screen => [screen, true as const]));

/** Includes stale settings links so they receive the settings recovery screen. */
export const isSettingsScreen = (screen: string) => Boolean(settingsScreens[screen]) || screen.startsWith('machine') || screen.startsWith('settings.');

const darken = (hex: string, amount = 0.12) => `#${[1, 3, 5].map(index => Math.round(parseInt(hex.slice(index, index + 2), 16) * (1 - amount)).toString(16).padStart(2, '0')).join('')}`;

function Tile({ pane, size }: { pane: Pane; size: 24 | 30 }) {
  const Icon = pane.icon;
  const style: CSSProperties = { width: size, height: size, borderRadius: size === 24 ? 6 : 8, background: `linear-gradient(180deg, ${pane.color}, ${darken(pane.color)})` };
  return <span className="settings-tile" style={style} aria-hidden="true"><Icon size={size === 24 ? 14 : 18} strokeWidth={2} color="#fff"/></span>;
}

function PaneContent({ route }: { route: Route }) {
  switch (route.screen) {
    case 'device.pairing': return <PairingScreen/>;
    case 'settings.identity': case 'settings.network': case 'settings.setup': case 'settings.usage.limit': return <OwnerControlsScreen route={route}/>;
    case 'skills': case 'routines': case 'connect.apps': case 'integrations.channels': case 'integrations.email': case 'integrations.x': return <WorkScreen route={route}/>;
    case 'connector.setup': return <WorkScreen route={{ ...route, screen: 'connect.apps' }}/>;
    case 'templates': return <BotsScreen route={{ ...route }}/>;
    case 'settings': return <SettingsScreen route={{ ...route, screen: 'settings.account' }}/>;
    default: return route.screen.startsWith('machine') ? <MachinesScreen route={route}/> : <SettingsScreen route={route}/>;
  }
}

export function SettingsRoute({ route }: { route: Route }) {
  const { navigate, snapshot } = useApp();
  const index = route.screen === 'settings';
  const pane = index ? account : panes.find(item => item.segments.some(segment => segmentMatches(segment, route.screen))) ?? account;
  const owner = snapshot.workspace.ownerUserId === snapshot.user.id;
  const segments = pane.segments.filter(segment => !segment.owner || owner);
  const subtitle = snapshot.user.email || snapshot.workspace.name;
  const name = snapshot.user.displayName;
  const open = (screen: string) => navigate({ screen });
  return <div className={`settings-shell ${index ? 'is-index' : 'is-pane'}`}>
    <aside className="settings-side">
      <div className="settings-account-head"><AccountAvatar name={name} size={40}/><div className="settings-account-text"><strong>{name}</strong><small>{subtitle}</small></div></div>
      <nav className="settings-pane-list" aria-label="Settings">
        {panes.map(item => <button type="button" key={item.id} className={`settings-pane-row ${item.id === pane.id ? 'selected' : ''}`} aria-current={item.id === pane.id ? 'page' : undefined} onClick={() => open(item.segments[0].screen)}><Tile pane={item} size={24}/><span>{item.title}</span></button>)}
      </nav>
    </aside>
    <div className="settings-phone-index">
      <div className="settings-phone-top"><button type="button" className="settings-done" onClick={() => open('home')}>Done</button></div>
      <h1 className="settings-phone-title">Settings</h1>
      <button type="button" className="settings-phone-account" onClick={() => open(account.segments[0].screen)}><AccountAvatar name={name} size={56}/><span className="settings-account-text"><strong>{name}</strong><small>{subtitle}</small></span><ChevronRight size={18} aria-hidden="true"/></button>
      <nav className="settings-phone-group" aria-label="Settings sections">
        {listed.map(item => <button type="button" key={item.id} className="settings-phone-row" onClick={() => open(item.segments[0].screen)}><Tile pane={item} size={30}/><span className="settings-phone-label">{item.title}</span><ChevronRight size={18} aria-hidden="true"/></button>)}
      </nav>
    </div>
    <div className="settings-main">
      <div className="settings-phone-bar"><button type="button" className="settings-back" onClick={() => open('settings')}><ChevronLeft size={20} aria-hidden="true"/>Settings</button><strong>{pane.title}</strong></div>
      <div className="settings-pane">
        <header className="settings-pane-head"><h1>{pane.title}</h1><p>{pane.subtitle}</p></header>
        {segments.length > 1 && <div className="settings-segments" role="group" aria-label={`${pane.title} sections`}>{segments.map(segment => { const selected = segmentMatches(segment, route.screen); return <button type="button" key={segment.screen} className={selected ? 'selected' : ''} aria-current={selected ? 'page' : undefined} onClick={() => open(segment.screen)}>{segment.label}</button>; })}</div>}
        <div className="settings-content"><PaneContent route={route}/></div>
      </div>
    </div>
  </div>;
}
