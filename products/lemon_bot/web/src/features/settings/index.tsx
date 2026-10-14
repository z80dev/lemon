import { type Route, useApp } from '../../app';
import { PageHeader } from '../../ui';
import { AccountSettings } from './account';
import { WorkspaceSettings } from './workspace';
import { NotificationSettings } from './notifications';
import { VoiceSettingsScreen } from './voice';
import { PolicySettings } from './policies';
import { UsageSettings } from './usage';
import { AboutSettings } from './about';
import { InboxScreen } from './inbox';
import './settings.css';

const titles: Record<string, string> = { 'settings.account': 'Account', 'settings.workspace': 'Workspace', 'settings.notifications': 'Notifications', 'settings.voice': 'Voice', 'settings.policies': 'Policies & permissions', 'settings.usage': 'Usage', 'settings.about': 'About & diagnostics', inbox: 'Inbox' };
export function SettingsScreen({ route }: { route: Route }) {
  const { navigate, snapshot } = useApp();
  let content;
  switch (route.screen) {
    case 'settings.workspace': content = <WorkspaceSettings />; break;
    case 'settings.notifications': content = <NotificationSettings />; break;
    case 'settings.voice': content = <VoiceSettingsScreen />; break;
    case 'settings.policies': content = <PolicySettings />; break;
    case 'settings.usage': content = <UsageSettings />; break;
    case 'settings.about': content = <AboutSettings />; break;
    case 'inbox': content = <InboxScreen />; break;
    case 'settings.account': content = <AccountSettings />; break;
    default: content = <section className="panel"><h2>Settings page not found</h2><p>Select a destination below.</p></section>;
  }
  return <main className="page settings-page"><PageHeader title={titles[route.screen] ?? 'Settings'} eyebrow={snapshot.workspace.name} /><nav className="tabs settings-tabs" aria-label="Settings pages">{Object.entries(titles).map(([screen, title]) => <button type="button" key={screen} className={route.screen === screen ? 'selected' : ''} aria-current={route.screen === screen ? 'page' : undefined} onClick={() => navigate({ screen })}>{title}</button>)}</nav>{content}</main>;
}
