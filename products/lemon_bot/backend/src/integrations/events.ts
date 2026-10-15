import { channelGatewayIngress } from './channels';
import { createEmailRoutes } from './email';
import { z } from 'zod';
import type * as P from '../../../contracts/protocol';
import type { BackendServices, Route } from '../core/services';
import { IntegrationError } from './common';
import { dedupeIngress, id, ignored, jsonObject, object, ownedBot, parse, principalFor, rawBody, runEventRoutine, senderMatches, signedTime, verifyIngress } from './channel-security';

export const emptyFilterSchema: P.JSONObject = { type: 'object', properties: {}, additionalProperties: false };
export function validateEventFilters(schema: P.JSONObject, value: P.JSONValue): void {
  const supported: Record<string, true> = { type: true, properties: true, required: true, additionalProperties: true, items: true, enum: true, const: true, minLength: true, maxLength: true, minItems: true, maxItems: true, minimum: true, maximum: true, pattern: true, description: true, title: true, $schema: true };
  if (Object.keys(schema).some(key => !supported[key])) throw new IntegrationError('capability_unavailable', 'Configured event filter uses an unsupported schema keyword.');
  if (Array.isArray(schema.enum) && !schema.enum.some(item => JSON.stringify(item) === JSON.stringify(value)) || schema.const !== undefined && JSON.stringify(schema.const) !== JSON.stringify(value)) throw new IntegrationError('invalid_request', 'Event filter value is outside its registered options.');
  if (schema.type === 'object') {
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new IntegrationError('invalid_request', 'Event filters must be an object.');
    const properties = object(schema.properties); const required = Array.isArray(schema.required) ? schema.required : [];
    if (required.some(key => typeof key !== 'string' || value[key] === undefined)) throw new IntegrationError('invalid_request', 'Required event filter is missing.');
    for (const [key, item] of Object.entries(value)) {
      if (!Object.hasOwn(properties, key)) throw new IntegrationError('invalid_request', 'Event filter is not registered by this provider.');
      validateEventFilters(parse(jsonObject, properties[key]), item);
    }
  } else if (schema.type === 'array') {
    if (!Array.isArray(value) || typeof schema.minItems === 'number' && value.length < schema.minItems || typeof schema.maxItems === 'number' && value.length > schema.maxItems) throw new IntegrationError('invalid_request', 'Event filter array is invalid.');
    for (const item of value) validateEventFilters(parse(jsonObject, schema.items), item);
  } else {
    if (schema.type === 'integer' ? typeof value !== 'number' || !Number.isSafeInteger(value) : schema.type === 'null' ? value !== null : typeof value !== schema.type) throw new IntegrationError('invalid_request', 'Event filter has an invalid registered type.');
    if (typeof value === 'string' && (typeof schema.minLength === 'number' && value.length < schema.minLength || typeof schema.maxLength === 'number' && value.length > schema.maxLength || typeof schema.pattern === 'string' && !new RegExp(schema.pattern).test(value))) throw new IntegrationError('invalid_request', 'Event filter text is invalid.');
    if (typeof value === 'number' && (typeof schema.minimum === 'number' && value < schema.minimum || typeof schema.maximum === 'number' && value > schema.maximum)) throw new IntegrationError('invalid_request', 'Event filter number is invalid.');
  }
}
export function matchesFilters(filters: P.JSONObject, payload: P.JSONObject, schema: P.JSONObject = emptyFilterSchema): boolean {
  validateEventFilters(schema, filters);
  for (const [key, expected] of Object.entries(filters)) {
    let actual: unknown = payload;
    for (const segment of key.split('.')) { const current = object(actual); actual = Object.hasOwn(current, segment) ? current[segment] : undefined; }
    if (Array.isArray(expected) ? !expected.some(item => JSON.stringify(item) === JSON.stringify(actual)) : JSON.stringify(actual) !== JSON.stringify(expected)) return false;
  }
  return true;
}
export function createEventServices(services: BackendServices) {
  return {
    inventory: (): P.ExternalSource[] => (['github', 'linear', 'sentry', 'pagerduty'] as const).map(source => {
      const providers = services.config.operator.eventProviders.filter(provider => provider.source === source);
      return { source, events: [...new Set(providers.flatMap(provider => provider.eventNames))].sort(), configured: providers.length > 0 };
    }),
    definition: (source: P.ExternalSource['source']): P.ExternalSourceDefinition => {
      const providers = services.config.operator.eventProviders.filter(provider => provider.source === source);
      const definitions: Record<string, P.EventDefinition> = {};
      for (const provider of providers) for (const name of provider.eventNames) {
        const supplied = provider.eventDefinitions?.find(event => event.name === name);
        const definition = supplied ?? { name, label: name, description: 'New verified provider event; no historical backfill.', filterSchema: emptyFilterSchema };
        if (definitions[name] && services.mutations.digest(definitions[name].filterSchema) !== services.mutations.digest(definition.filterSchema)) throw new IntegrationError('capability_unavailable', 'Providers disagree on the registered event filter schema.');
        definitions[name] = definition;
      }
      return { source, configured: providers.length > 0, events: Object.values(definitions).sort((a, b) => a.name.localeCompare(b.name)) };
    },
  };
}
export function createEventRoutes(services: BackendServices): Route[] {
  return [
    { method: 'GET', path: '/v1/event-sources', auth: 'member', handler: () => createEventServices(services).inventory() },
    { method: 'GET', path: '/v1/event-sources/:source', auth: 'member', handler: context => createEventServices(services).definition(parse(z.enum(['github', 'linear', 'sentry', 'pagerduty']), context.params.source)) },
    { method: 'POST', path: '/v1/integrations/:providerId/events', auth: 'public', mutation: false, body: 'none', handler: async context => {
      const provider = services.config.operator.eventProviders.find(item => item.id === context.params.providerId);
      if (!provider && services.config.operator.channelProviders.some(item => item.id === context.params.providerId)) return channelGatewayIngress(services, context);
      if (!provider && services.config.operator.emailProviders.some(item => item.id === context.params.providerId)) {
        const route = createEmailRoutes(services).find(item => item.path === '/v1/integrations/email/events' && item.method === 'POST')!;
        return route.handler(context);
      }
      if (!provider) throw new IntegrationError('capability_unavailable', 'Register this event provider and verification credentials.');
      const raw = await rawBody(context.request); let decoded: unknown;
      try { decoded = JSON.parse(raw); } catch { throw new IntegrationError('invalid_request', 'Invalid provider JSON.'); }
      await verifyIngress(services, context.request, raw, provider.id, provider.source, provider.signingSecretRef, provider.maxAgeMs, decoded);
      const root = object(decoded);
      const normalized = root.deliveryId ? parse(z.strictObject({ deliveryId: id, event: z.string().min(1).max(128), payload: jsonObject }), decoded) : {
        deliveryId: context.request.headers.get('x-github-delivery') ?? context.request.headers.get('linear-delivery') ?? context.request.headers.get('request-id') ?? String(object(root.event).id ?? services.mutations.digest(decoded)),
        event: context.request.headers.get('x-github-event') ?? String(root.type ?? object(root.event).event_type ?? context.request.headers.get('sentry-hook-resource') ?? ''),
        payload: parse(jsonObject, decoded),
      };
      if (!root.deliveryId && provider.source === 'github') {
        const payloadField: Record<string, string> = { issues: 'issue', issue_comment: 'comment', pull_request: 'pull_request', pull_request_review: 'review', pull_request_review_comment: 'comment', push: 'ref', release: 'release', workflow_run: 'workflow_run', check_run: 'check_run', check_suite: 'check_suite', discussion: 'discussion', discussion_comment: 'comment', star: 'starred_at' };
        const field = payloadField[normalized.event];
        if (!field) throw new IntegrationError('capability_unavailable', 'This native GitHub event requires the registered signed normalization bridge.');
        if (!Object.hasOwn(root, field)) throw new IntegrationError('unauthenticated', 'GitHub event header does not match its signed payload.');
      }
      if (!root.deliveryId && provider.source === 'sentry') {
        const field = normalized.event === 'event_alert' ? 'event' : normalized.event;
        if (!Object.hasOwn(object(root.data), field)) throw new IntegrationError('unauthenticated', 'Sentry resource header does not match its signed payload.');
      }
      parse(id, normalized.deliveryId);
      const configuredPrincipal = principalFor(services, provider.principalUserId);
      const eligibleRoutineIds = provider.routineIds.filter(routineId => {
        const routine = services.store.get<P.Routine>('routines', routineId);
        const bot = routine ? services.store.get<P.Bot>('bots', routine.botId) : null;
        return !!routine && routine.ownerUserId === configuredPrincipal.userId && bot?.ownerUserId === configuredPrincipal.userId;
      });
      if (!eligibleRoutineIds.length) return ignored('Configured event principal must own the routine and its Bot.');
      if (!(await services.integrations.effectivePolicy(configuredPrincipal)).productAccess) return ignored('Configured event principal is blocked by product access policy.');
      return dedupeIngress(services, provider.id, normalized.deliveryId, decoded, async () => {
        if (!provider.eventNames.includes(normalized.event)) return ignored('Unsupported registered event.');
        const principal = principalFor(services, provider.principalUserId);
        let result = ignored('No enabled routine matched this event.');
        for (const routineId of eligibleRoutineIds) {
          const routine = services.store.get<P.Routine>('routines', routineId);
          const occurredAtMs = Number(context.request.headers.get('x-lemon-timestamp')) || signedTime(provider.source, decoded);
          if (!routine || routine.createdAtMs > occurredAtMs || !routine.enabled) continue;
          ownedBot(services, principal, routine.botId);
          const trigger = routine.trigger;
          if (trigger.kind === 'external_event') {
            const definition = provider.eventDefinitions?.find(event => event.name === normalized.event);
            if (trigger.source !== provider.source || !trigger.eventNames.includes(normalized.event) || !matchesFilters(trigger.filters, normalized.payload, definition?.filterSchema ?? emptyFilterSchema)) continue;
          } else if (trigger.kind === 'channel_event') {
            if (provider.source !== 'slack' && provider.source !== 'email' || trigger.event !== normalized.event || normalized.payload.channelBindingId !== trigger.channelBindingId) continue;
            const binding = services.store.get<P.ChannelBinding>('channelBindings', trigger.channelBindingId);
            if (!binding?.enabled || binding.state !== 'connected' || binding.botId !== routine.botId || binding.adapter !== provider.source || binding.ownerUserId !== principal.userId) continue;
            const governance = services.store.list<P.Governance>('governance')[0] ?? services.store.metadata<P.Governance>('governance');
            if (provider.source === 'email' ? !governance?.emailEnabled : !governance?.allowedChannelAdapters.includes('slack')) continue;
            if (trigger.channel && normalized.payload.channel !== trigger.channel || trigger.phrase && (typeof normalized.payload.text !== 'string' || !normalized.payload.text.includes(trigger.phrase)) || trigger.reaction && normalized.payload.reaction !== trigger.reaction) continue;
            if (provider.source === 'email' && (normalized.payload.authentication !== 'passed' || normalized.payload.scan !== 'passed' || !trigger.senders?.length || typeof normalized.payload.from !== 'string' || !senderMatches(normalized.payload.from, trigger.senders))) continue;
            if (trigger.event === 'message' && !trigger.phrase?.trim()) {
              const consent = services.store.metadata<{ userId: string; botId: string; channelBindingId: string; channel: string | null }>(`routineListenerConsent:${routine.id}`);
              if (!trigger.noisyListenerConsent || consent?.userId !== routine.ownerUserId || consent.botId !== routine.botId || consent.channelBindingId !== trigger.channelBindingId || consent.channel !== (trigger.channel ?? null)) continue;
            }
          } else continue;
          result = await runEventRoutine(services, principal, routine, normalized.payload, `${provider.id}:${normalized.deliveryId}`);
        }
        return result;
      }, configuredPrincipal, eligibleRoutineIds.map(routineId => services.store.require<P.Routine>('routines', routineId).botId));
    } },
  ];
}
