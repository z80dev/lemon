import type { Config } from '../config/types.ts';
import type { Message } from '../domain/message.ts';
import { envelope } from '../domain/envelope.ts';
import { render } from '../render/index.ts';
import { validateDestination } from '../routing/destination.ts';
export function prepare(config: Config, item: Message) {
  validateDestination(config, item.recipient);
  return envelope(config, item, render(config, item));
}
