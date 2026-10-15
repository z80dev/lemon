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
import { AccountCleanupScreen } from './cleanup';
import './settings.css';

export function SettingsScreen({ route }: { route: Route }) {
  const { snapshot } = useApp();
  let content;
  switch (route.screen) {
    case 'settings.workspace': content = <WorkspaceSettings />; break;
    case 'settings.account-cleanup': content = <AccountCleanupScreen id={route.id} />; break;
    case 'settings.notifications': content = <NotificationSettings />; break;
    case 'settings.voice': content = <VoiceSettingsScreen />; break;
    case 'settings.policies': content = <PolicySettings />; break;
    case 'settings.usage': content = <UsageSettings />; break;
    case 'settings.about': content = <AboutSettings />; break;
    case 'inbox': content = <InboxScreen />; break;
    case 'settings.account': content = <AccountSettings />; break;
    default: content = <section className="panel"><h2>Settings page not found</h2><p>Select a section from the settings list.</p></section>;
  }
  return <main className="page settings-page">{route.screen === 'inbox' && <PageHeader title="Inbox" eyebrow={snapshot.workspace.name} />}{content}</main>;
}
