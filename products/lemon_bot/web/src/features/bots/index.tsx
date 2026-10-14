/**
 * Owner-only Bot destinations consume canonical SDK REST endpoints only.
 * Identity, Job and assigned-profile Memory are separate editors. Bot groups
 * contain only this owner's Bots; templates create separate reviewed copies.
 * Lifecycle operations
 * require server previews; uncertain effects retain input and offer read-only
 * reconciliation rather than replay. Templates produce reviewed owned copies,
 * and selecting an Idea only drafts an unsent prompt.
 */
import type { Route } from '../../app';
import { useApp } from '../../app';
import { ErrorNotice, Field, Loading, PageHeader } from '../../ui';
import { CreateBot } from './editor';
import { GroupScreen } from './group';
import { MemoryPanel } from './memory';
import { BotOverview } from './overview';
import { TemplatesScreen } from './templates';
import { useBot } from './shared';
import './bots.css';

export function BotsScreen({ route }: { route: Route }) {
  if (route.screen === 'bot.create') return <CreateBot />;
  if (route.screen === 'group.create' || route.screen === 'group.edit') return <GroupScreen id={route.id} />;
  if (route.screen === 'templates') return <TemplatesScreen id={route.id} botId={route.botId} />;
  if (route.screen === 'memory' || route.screen === 'memory.import') return <MemoryScreen botId={route.botId ?? route.id} />;
  const id = route.botId ?? route.id;
  if (!id) return <BotPicker screen={route.screen} />;
  const tab = route.tab ?? (route.screen === 'bot.settings' || route.screen === 'bot.reset' ? 'settings' : route.screen === 'bot.edit' || route.screen === 'voice.preview' ? 'identity' : route.screen === 'preference.changes' ? 'job' : 'activity');
  return <BotOverview key={id} id={id} tab={tab} />;
}
function BotPicker({ screen }: { screen: string }) {
  const { snapshot, navigate } = useApp();
  return <main className="page stack"><PageHeader title="Choose a Bot" /><Field label="Bot"><select defaultValue="" onChange={event => event.target.value && navigate({ screen, botId: event.target.value })}><option value="">Select teammate</option>{snapshot.bots.map(bot => <option key={bot.id} value={bot.id}>{bot.name}</option>)}</select></Field><button onClick={() => navigate({ screen: 'bot.create' })}>Create a Bot</button></main>;
}
function MemoryScreen({ botId }: { botId?: string }) {
  const { snapshot, navigate } = useApp();
  const id = botId ?? snapshot.bots[0]?.id;
  if (!id) return <BotPicker screen="memory" />;
  return <SelectedMemory key={id} id={id} onSelect={next => navigate({ screen: 'memory', botId: next })} />;
}
function SelectedMemory({ id, onSelect }: { id: string; onSelect: (id: string) => void }) {
  const { snapshot } = useApp(); const bot = useBot(id);
  return <main className="page stack"><PageHeader title="Scoped memory" /><Field label="Selected Bot"><select value={id} onChange={event => onSelect(event.target.value)}>{snapshot.bots.map(item => <option key={item.id} value={item.id}>{item.name}</option>)}{!snapshot.bots.some(item => item.id === id) && <option value={id}>{id}</option>}</select></Field><ErrorNotice error={bot.error} />{bot.loading && <Loading />}{bot.data && <MemoryPanel bot={bot.data} />}<button onClick={() => void bot.reload()}>Reload Bot</button></main>;
}
