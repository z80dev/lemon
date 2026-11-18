import { lookup } from 'node:dns/promises';
import net from 'node:net';

// Mirrors LemonBrowser.RoutePolicy: cloud metadata and link-local destinations
// are refused on every route. `blockedDestination` is a pre-check for
// navigate/tabOpen requests; for Lemon-launched Chrome the egress proxy
// (egress-proxy.ts) enforces `isBlockedAddress` on every actual connection.
const METADATA_HOSTNAMES: Record<string, true> = {
  metadata: true,
  'metadata.google.internal': true,
  'metadata.goog': true,
};

const BLOCKED = new net.BlockList();
BLOCKED.addSubnet('169.254.0.0', 16, 'ipv4');
BLOCKED.addAddress('100.100.100.200', 'ipv4');
BLOCKED.addSubnet('fe80::', 10, 'ipv6');
BLOCKED.addAddress('fd00:ec2::254', 'ipv6');
// IPv4-mapped, NAT64 and IPv4-compatible forms of the IPv4 ranges above.
for (const prefix of ['::ffff:', '64:ff9b::', '::']) {
  BLOCKED.addSubnet(`${prefix}169.254.0.0`, 112, 'ipv6');
  BLOCKED.addAddress(`${prefix}100.100.100.200`, 'ipv6');
}

export type Resolver = (hostname: string) => Promise<string[]>;

const systemResolver: Resolver = async (hostname) =>
  (await lookup(hostname, { all: true, verbatim: true })).map((entry) => entry.address);

export function isBlockedAddress(address: string): boolean {
  const ip = address.replace(/^\[|\]$/g, '').split('%')[0];
  const family = net.isIP(ip);
  if (family === 4) return BLOCKED.check(ip, 'ipv4');
  if (family === 6) return BLOCKED.check(ip, 'ipv6');
  return false;
}

/** Returns a reason when `url` targets a blocked destination, or null when allowed. */
export async function blockedDestination(url: string, resolve: Resolver = systemResolver): Promise<string | null> {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return 'invalid navigation url';
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return null;

  // WHATWG URL parsing already canonicalizes numeric, hex and octal IPv4 hosts.
  const host = parsed.hostname.toLowerCase().replace(/\.+$/, '').replace(/^\[|\]$/g, '');
  if (Object.hasOwn(METADATA_HOSTNAMES, host)) return `metadata endpoint ${host}`;
  if (net.isIP(host)) return isBlockedAddress(host) ? `metadata endpoint ${host}` : null;
  if (host === 'localhost' || host.endsWith('.localhost')) return null;

  let addresses: string[];
  try {
    addresses = await resolve(host);
  } catch {
    return `could not resolve host ${host}`;
  }
  if (addresses.length === 0) return `could not resolve host ${host}`;
  const blocked = addresses.find(isBlockedAddress);
  return blocked ? `metadata endpoint ${host} (${blocked})` : null;
}
