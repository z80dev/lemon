import type { Config } from '../config/types.ts';
import type { Message } from '../domain/message.ts';
import { receipt } from '../domain/receipt.ts';
import { plan } from './plan.ts';
export function dispatch(config: Config, items: Message[]) { return plan(config, items).batches.flat().map(receipt); }
