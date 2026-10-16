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
import { InstanceSettings } from './instance';
import { ProvidersSettings } from './providers';
import './settings.css';

export function SettingsScreen({ route }: { route: Route }) {
  const { snapshot, navigate } = useApp();
  let content;
  switch (route.screen) {
    case 'settings.workspace': content = <WorkspaceSettings />; break;
    case 'settings.account-cleanup': content = <AccountCleanupScreen id={route.id} />; break;
    case 'settings.notifications': content = <NotificationSettings />; break;
    case 'settings.voice': content = <VoiceSettingsScreen />; break;
    case 'settings.policies': content = <PolicySettings />; break;
    case 'settings.usage': content = <UsageSettings />; break;
    case 'settings.about': content = <AboutSettings />; break;
    case 'settings.instance': content = <InstanceSettings />; break;
    case 'settings.providers': content = <ProvidersSettings />; break;
    case 'inbox': content = <InboxScreen />; break;
    case 'settings.account': content = <AccountSettings />; break;
    default: content = <section className="panel"><h2>This page isn’t available.</h2><button onClick={() => navigate({ screen: 'settings.account' })}>Back to settings</button></section>;
  }
  return <main className="page settings-page">{route.screen === 'inbox' && <PageHeader title="Inbox" eyebrow={snapshot.workspace.name} />}{content}</main>;
}
