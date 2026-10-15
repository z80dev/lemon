import { useApp, type Route } from '../../app';
import { PageHeader } from '../../ui';
import { IdentityScreen } from './identity';
import { NetworkScreen } from './network';
import { SetupScreen } from './setup';
import { SpendScreen } from './spend';
import './enterprise.css';

const destinations = [
  { screen: 'settings.identity', title: 'Sign-in providers', description: 'Your verified identities and configured provider prerequisites' },
  { screen: 'settings.network', title: 'Network access', description: 'Choose which network connections your Bots can use' },
  { screen: 'settings.setup', title: 'Startup scripts', description: 'Configure optional scripts and secrets for your machines, and review past runs' },
  { screen: 'settings.usage.limit', title: 'Spend limits', description: 'Review provider spending and set limits for new work' },
];

export function OwnerControlsScreen({ route }: { route: Route }) {
  const { navigate, online } = useApp();
  const destination = destinations.find(item => item.screen === route.screen);
  return <main className="page enterprise-page"><PageHeader title={destination?.title ?? 'Owner settings'} eyebrow="Your workspace"><p className="muted">{destination?.description ?? 'Choose an owner control. No enterprise setup is required.'}</p></PageHeader><nav className="tabs enterprise-tabs" aria-label="Owner settings">{destinations.map(item => <button type="button" className={route.screen === item.screen ? 'selected' : ''} aria-current={route.screen === item.screen ? 'page' : undefined} key={item.screen} onClick={() => navigate({ screen: item.screen })}>{item.title}</button>)}</nav>{!online && <aside className="error-notice" role="status">Offline. Displayed records may be stale. Reads report errors rather than empty state; mutations are never queued.</aside>}
    {route.screen === 'settings.identity' && <IdentityScreen />}
    {route.screen === 'settings.network' && <NetworkScreen />}
    {route.screen === 'settings.setup' && <SetupScreen />}
    {route.screen === 'settings.usage.limit' && <SpendScreen />}
    {!destination && <section className="panel"><h2>Choose an owner settings area</h2><p>Provider sign-in and optional host controls remain separate from normal assistant use.</p></section>}
  </main>;
}
