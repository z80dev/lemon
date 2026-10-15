import { describe, expect, test } from 'bun:test';
import { integrationConfiguration, parseOperatorConfiguration } from '../../src/integrations/config';
import { closeFixture, fixture as ownerFixture } from './channels-fixture';
describe('private operator configuration validation', () => {
  test('minimal local setup has no fabricated provider capabilities', () => {
    const config = parseOperatorConfiguration({ version: 1 });
    expect(config.channelProviders).toEqual([]); expect(config.emailProviders).toEqual([]); expect(config.xProvider).toBeNull();
    expect(config.hostDrivers).toEqual([]); expect(config.serverSecrets).toEqual({});
  });
  test('unknown settings and inline credential strings are rejected', () => {
    expect(() => parseOperatorConfiguration({ version: 1, apiKey: 'never-inline' })).toThrow();
    expect(() => parseOperatorConfiguration({ version: 1, serverSecrets: { provider: { kind: 'inline', value: 'private' } } })).toThrow();
  });
  test('configured OAuth token and authorize endpoints must match pinned origins and known references', () => {
    const oauth = { id: 'oauth', clientId: 'client', clientSecretRef: 'oauth-secret', authorizeUrl: 'https://auth.example/authorize', tokenUrl: 'https://foreign.example/token', scopes: ['tools.read'], redirectUris: ['https://bot.example/v1/connectors/oauth/callback'], allowedOrigins: ['https://auth.example'] };
    const base = { version: 1, serverSecrets: { 'oauth-secret': { kind: 'env', name: 'OAUTH_SECRET' } }, connectorProviders: [{ id: 'mcp', origins: ['https://mcp.example'], oauth, sharedServiceAccount: false }] };
    expect(() => parseOperatorConfiguration(base)).toThrow();
    expect(parseOperatorConfiguration({ ...base, connectorProviders: [{ ...base.connectorProviders[0], oauth: { ...oauth, tokenUrl: 'https://auth.example/token' } }] }).connectorProviders?.[0]?.oauth?.tokenUrl).toBe('https://auth.example/token');
    expect(() => parseOperatorConfiguration({ ...base, serverSecrets: {} })).toThrow();
  });
  test('private export exception requires explicit origin membership and provider refs exist', () => {
    expect(() => parseOperatorConfiguration({ version: 1, exportPrivateOrigins: ['https://private.example'] })).toThrow();
    expect(() => parseOperatorConfiguration({ version: 1, xPublicAccountSecretRef: 'missing' })).toThrow();
    expect(parseOperatorConfiguration({ version: 1, exportPrivateOrigins: ['https://private.example'], exportAllowedOrigins: ['https://private.example'] }).exportAllowedOrigins).toEqual(['https://private.example']);
  });
  test('reviewed setup scripts retain named secret references not values and hard timeouts', () => {
    const entries = [{ id: 'install', setupScript: '/opt/lemon/setup', checkScript: '/opt/lemon/check', secretNames: ['SERVICE_TOKEN'], timeoutMs: 1800000 }];
    const value = parseOperatorConfiguration({ version: 1, reviewedSetupManifests: [{ name: 'Reviewed', directoryGroupId: null, machineIds: ['m'], entries }] });
    expect(value.reviewedSetupManifests?.[0]?.entries[0]?.secretNames).toEqual(['SERVICE_TOKEN']);
    expect(() => parseOperatorConfiguration({ version: 1, reviewedSetupManifests: [{ name: 'Reviewed', directoryGroupId: null, machineIds: ['m'], entries: [{ ...entries[0], timeoutMs: 1800001 }] }] })).toThrow();
  });
  test('explicit first-party literal-loopback HTTP MCP approval is exact and never relaxes provider origins', () => {
    const own = 'http://127.0.0.1:57512', input = { version: 1, approvedPrivateMcpOrigins: [own] };
    expect(() => parseOperatorConfiguration(input)).toThrow();
    expect(parseOperatorConfiguration(input, { firstPartyOrigin: own }).approvedPrivateMcpOrigins).toEqual([own]);
    const ipv6 = 'http://[::1]:57512';
    expect(parseOperatorConfiguration({ ...input, approvedPrivateMcpOrigins: [ipv6] }, { firstPartyOrigin: ipv6 }).approvedPrivateMcpOrigins).toEqual([ipv6]);
    for (const wrong of ['http://127.0.0.1:57513', 'http://localhost:57512', 'http://10.0.0.1:57512', `${own}/mcp`, `http://user:password@127.0.0.1:57512`]) {
      expect(() => parseOperatorConfiguration({ ...input, approvedPrivateMcpOrigins: [wrong] }, { firstPartyOrigin: own })).toThrow();
    }
    expect(() => parseOperatorConfiguration({ ...input, connectorProviders: [{ id: 'third-party', origins: [own], oauth: null, sharedServiceAccount: false }] }, { firstPartyOrigin: own })).toThrow();
    expect(() => parseOperatorConfiguration({ version: 1, exportAllowedOrigins: [own] }, { firstPartyOrigin: own })).toThrow();
  });
  test('runtime revalidation cannot reuse another first-party backend port approval', () => {
    const state = ownerFixture();
    try {
      const own = 'http://127.0.0.1:57512';
      state.services.config.publicUrl = own;
      state.services.config.operator = parseOperatorConfiguration({ version: 1, approvedPrivateMcpOrigins: [own] }, { firstPartyOrigin: own });
      expect(integrationConfiguration(state.services).approvedPrivateMcpOrigins).toEqual([own]);
      state.services.config.publicUrl = 'http://127.0.0.1:57513';
      expect(() => integrationConfiguration(state.services)).toThrow();
    } finally { closeFixture(state.services); }
  });
});
