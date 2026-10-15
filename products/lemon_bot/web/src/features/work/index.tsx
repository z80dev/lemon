import type { Route } from '../../app';
import { EmptyState } from '../../ui';
import { ChannelsScreen } from './channels';
import { ConnectorsScreen } from './connectors';
import { EmailScreen } from './email';
import { RoutinesScreen } from './routines';
import { SkillsScreen } from './skills';
import { XScreen } from './x';

export function WorkScreen({ route }: { route: Route }) {
  switch (route.screen) {
    case 'skills': return <SkillsScreen route={route} />;
    case 'routines': return <RoutinesScreen route={route} />;
    case 'connect.apps':
    case 'connector.setup': return <ConnectorsScreen route={route} />;
    case 'integrations.channels': return <ChannelsScreen route={route} />;
    case 'integrations.email': return <EmailScreen route={route} />;
    case 'integrations.x': return <XScreen route={route} />;
    default: return <EmptyState title="Work destination unavailable">This route is not a supported work screen.</EmptyState>;
  }
}
