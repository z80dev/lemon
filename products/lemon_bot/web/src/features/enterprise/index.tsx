import { useApp, type Route } from '../../app';
import { PageHeader } from '../../ui';
import { DirectoryScreen } from './directory';
import { ExportsScreen } from './exports';
import { IdentityScreen } from './identity';
import { EffectivePolicyPanel, NetworkScreen } from './network';
import { SetupScreen } from './setup';
import { SpendScreen } from './spend';
import './enterprise.css';

const destinations = [
  { screen: 'settings.identity', title: 'Identity', description: 'Verified sign-in, OIDC providers and SCIM provisioning' },
  { screen: 'settings.directory', title: 'Directory & governance', description: 'Groups, access, required bots and capability ceilings' },
  { screen: 'settings.network', title: 'Network & egress', description: 'Explainable policy and measured host enforcement' },
  { screen: 'settings.setup', title: 'Reviewed setup', description: 'Ordered host scripts, named secrets and real run records' },
  { screen: 'settings.exports', title: 'Exports & privacy', description: 'Separate metadata streams, participant consent and artifacts' },
  { screen: 'settings.usage.limit', title: 'Spend limits', description: 'Attributed provider usage and explicit new-work ceilings' },
];

export function EnterpriseScreen({ route }: { route: Route }) {
  const { navigate, online } = useApp();
  const destination = destinations.find(item => item.screen === route.screen);
  return <main className="page enterprise-page"><PageHeader title={destination?.title ?? 'Enterprise settings'} eyebrow="Workspace controls"><p className="muted">{destination?.description ?? 'Choose a configured enterprise control.'}</p></PageHeader><nav className="tabs enterprise-tabs" aria-label="Enterprise settings">{destinations.map(item => <button type="button" className={route.screen === item.screen ? 'selected' : ''} aria-current={route.screen === item.screen ? 'page' : undefined} key={item.screen} onClick={() => navigate({ screen: item.screen })}>{item.title}</button>)}</nav>{!online && <aside className="error-notice" role="status">Offline. Displayed records may be stale. Reads report errors rather than empty state; no configuration changes, approvals or host operations are queued.</aside>}
    {route.screen === 'settings.identity' && <IdentityScreen />}
    {route.screen === 'settings.directory' && <><DirectoryScreen /><EffectivePolicyPanel /></>}
    {route.screen === 'settings.network' && <NetworkScreen />}
    {route.screen === 'settings.setup' && <SetupScreen />}
    {route.screen === 'settings.exports' && <ExportsScreen />}
    {route.screen === 'settings.usage.limit' && <SpendScreen />}
    {!destination && <section className="panel"><h2>Choose a settings area</h2><p>Identity providers, governance, network enforcement, reviewed setup, exports and spend limits each have a separate authorized scope.</p></section>}
  </main>;
}
