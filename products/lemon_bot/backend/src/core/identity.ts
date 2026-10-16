import type { BackendDescriptor } from '../../../contracts/protocol';
import type { BackendServices } from './services';
import { fail } from './errors';
import { productVersion } from './version';

/** Product/database identity, independent of listener aliases and controller identity. */
export function backendDescriptor(services: BackendServices): BackendDescriptor {
  const instanceId = services.store.metadata<unknown>('instanceId');
  if (typeof instanceId !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(instanceId)) {
    fail('internal_error', 'The stored Bot backend identity is invalid.', false);
  }
  return { product: 'lemon_bot', apiVersion: 1, version: productVersion, instanceId, publicUrl: services.config.publicUrl, capabilities: { pairing: true } };
}
