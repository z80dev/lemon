import { lookup } from 'node:dns/promises';
import net from 'node:net';

// The browser driver's one destination classifier, a port of
// LemonCore.Net.Address (apps/lemon_core/lib/lemon_core/net/address.ex); keep
// the two in step. A destination is `public`, `private` or `metadata`:
//
// - metadata: link-local space (169.254.0.0/16, fe80::/10) and known cloud
//   metadata endpoints (100.100.100.200, fd00:ec2::254, the `metadata`,
//   `metadata.goog` and `metadata.google.internal` names). Refused on every route.
// - private: every address that is not allocated global unicast, including all
//   of 6to4 (2002::/16, which can conceal an embedded IPv4 hop). `localhost`
//   names are private without resolution.
// - public: everything else.
//
// IPv4 literals are recognised in every inet_aton alias form, IPv6 forms that
// deliver to an embedded IPv4 destination (IPv4-mapped, IPv4-compatible, NAT64)
// are classified as that IPv4 address, and a hostname takes the strictest class
// of all its DNS answers. DNS failure is never public.
//
// `blockedDestination` is the navigate/tabOpen pre-check; for Lemon-launched
// Chrome the egress proxy (egress-proxy.ts) applies `authorize` to every
// connection it makes.

export type AddressClass = 'public' | 'private' | 'metadata';
/** IPv4 as 4 bytes or IPv6 as 8 16-bit words. */
export type IpAddress = readonly number[];
export type Resolver = (hostname: string) => Promise<string[]>;
export type DnsError = 'invalid_host' | 'dns_resolution_failed' | 'too_many_dns_addresses';
export type HostClassification =
  | { ok: true; class: AddressClass; addresses: IpAddress[] }
  | { ok: false; error: DnsError };
export type Authorization =
  | { ok: true; addresses: string[] }
  | { ok: false; error: DnsError | 'destination_not_public' | 'metadata_blocked' };

const MAX_ADDRESSES = 64;
const MAX_HOST_BYTES = 1024;
const METADATA_NAMES: Record<string, true> = { metadata: true, 'metadata.goog': true, 'metadata.google.internal': true };
const LOCALHOST_NAMES: Record<string, true> = {
  localhost: true,
  'localhost.localdomain': true,
  localhost6: true,
  'ip6-localhost': true,
  'ip6-loopback': true,
};
const STRICTNESS: Record<AddressClass, number> = { public: 0, private: 1, metadata: 2 };
const EC2_METADATA_IPV6: IpAddress = [0xfd00, 0xec2, 0, 0, 0, 0, 0, 0x254];

export const systemResolver: Resolver = async (hostname) =>
  (await lookup(hostname, { all: true, verbatim: true })).map((entry) => entry.address);

/** Parses an IP literal host (brackets allowed) in any alias form. */
export function parseLiteral(host: string): IpAddress | null {
  const bare = host.replace(/^\[+/, '').replace(/\]+$/, '');
  if (bare === '' || Buffer.byteLength(bare) > MAX_HOST_BYTES || bare.includes('%')) return null;
  return bare.includes(':') ? parseIpv6(bare) : parseInetAton(bare);
}

function parseIpv6(host: string): IpAddress | null {
  if (net.isIP(host) !== 6) return null;
  // Rewrite a dotted IPv4 tail as two hex words, then expand `::`.
  let text = host;
  const tailStart = text.lastIndexOf(':') + 1;
  const tail = text.slice(tailStart);
  if (tail.includes('.')) {
    const [a, b, c, d] = tail.split('.').map(Number);
    text = `${text.slice(0, tailStart)}${((a << 8) | b).toString(16)}:${((c << 8) | d).toString(16)}`;
  }
  const groups = (part: string) => (part === '' ? [] : part.split(':').map((word) => parseInt(word, 16)));
  const [left, right] = text.split('::');
  const head = groups(left);
  const words = right === undefined ? head : [...head, ...Array<number>(8 - head.length - groups(right).length).fill(0), ...groups(right)];
  return words.length === 8 && words.every((word) => word >= 0 && word <= 0xffff) ? words : null;
}

// inet_aton: 1-4 dot-separated parts, each decimal, 0x-hex or 0-octal; the last
// part fills the remaining bytes (`2852039166`, `0xa9.0xfe.0xa9.0xfe`, `0177.1`).
function parseInetAton(host: string): IpAddress | null {
  const parts = host.split('.');
  if (parts.length > 4) return null;
  const values: number[] = [];
  for (const part of parts) {
    if (/^0[xX][0-9a-fA-F]{1,8}$/.test(part)) values.push(parseInt(part.slice(2), 16));
    else if (/^0[0-7]{1,11}$/.test(part)) values.push(parseInt(part, 8));
    else if (/^(?:[1-9][0-9]{0,9}|0)$/.test(part)) values.push(Number(part));
    else return null;
  }
  const last = values.pop() as number;
  const tailBits = 8 * (4 - values.length);
  if (values.some((byte) => byte > 255) || last >= 2 ** tailBits) return null;
  const integer = values.reduce((acc, byte) => acc * 256 + byte, 0) * 2 ** tailBits + last;
  return [(integer >>> 24) & 0xff, (integer >>> 16) & 0xff, (integer >>> 8) & 0xff, integer & 0xff];
}

/** Canonical text for a parsed address (compressed IPv6), as connections use it. */
export function formatAddress(address: IpAddress): string {
  if (address.length === 4) return address.join('.');
  return new URL(`http://[${address.map((word) => word.toString(16)).join(':')}]/`).hostname.slice(1, -1);
}

/** Classifies one IP address. */
export function classify(address: IpAddress): AddressClass {
  const ipv4 = embeddedIpv4(address);
  return ipv4 ? classifyIpv4(ipv4) : classifyIpv6(address);
}

/** Returns the most restrictive class of a list of addresses. */
export function classifyAll(addresses: readonly IpAddress[]): AddressClass {
  return addresses.map(classify).reduce<AddressClass>((a, b) => (STRICTNESS[b] > STRICTNESS[a] ? b : a), 'public');
}

/**
 * Resolves and classifies a host (DNS name or IP literal). Metadata and
 * `localhost` names are classified by name and return no addresses.
 */
export async function classifyHost(host: string, resolve: Resolver = systemResolver): Promise<HostClassification> {
  const literal = parseLiteral(host.replace(/\.+$/, ''));
  if (literal) return { ok: true, class: classify(literal), addresses: [literal] };

  const name = host.trim().toLowerCase().replace(/\.+$/, '');
  if (name === '' || Buffer.byteLength(name) > 253 || !/^[a-z0-9_](?:[a-z0-9_.-]*[a-z0-9_])?$/.test(name)) {
    return { ok: false, error: 'invalid_host' };
  }
  if (Object.hasOwn(METADATA_NAMES, name)) return { ok: true, class: 'metadata', addresses: [] };
  if (Object.hasOwn(LOCALHOST_NAMES, name) || name.endsWith('.localhost')) {
    return { ok: true, class: 'private', addresses: [] };
  }

  const resolved = await resolveHost(name, resolve);
  return resolved.ok ? { ok: true, class: classifyAll(resolved.addresses), addresses: resolved.addresses } : resolved;
}

/**
 * Authorizes a host for an outbound connection and returns the addresses to
 * connect to. Public destinations are always allowed, private ones only with
 * `allowPrivate`, metadata never. `localhost` names pin to 127.0.0.1.
 */
export async function authorize(
  host: string,
  options: { allowPrivate?: boolean; resolve?: Resolver } = {},
): Promise<Authorization> {
  const result = await classifyHost(host, options.resolve);
  if (!result.ok) return result;
  if (result.class === 'metadata') return { ok: false, error: 'metadata_blocked' };
  if (result.class === 'private' && options.allowPrivate !== true) return { ok: false, error: 'destination_not_public' };
  if (result.addresses.length === 0) return { ok: true, addresses: ['127.0.0.1'] };
  // Erlang term order, as LemonCore.Net.Address sorts: IPv4 before IPv6, then numerically.
  const sorted = [...result.addresses].sort((a, b) => a.length - b.length || compareWords(a, b));
  return { ok: true, addresses: sorted.map(formatAddress) };
}

/** Returns a reason when `url` targets a metadata destination or cannot be resolved, or null when allowed. */
export async function blockedDestination(url: string, resolve: Resolver = systemResolver): Promise<string | null> {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return 'invalid navigation url';
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return null;

  const host = parsed.hostname;
  const result = await classifyHost(host, resolve);
  if (!result.ok) return result.error === 'invalid_host' ? `invalid navigation host ${host}` : `could not resolve host ${host}`;
  if (result.class !== 'metadata') return null;
  const answer = parseLiteral(host.replace(/\.+$/, '')) ? undefined : result.addresses.find((ip) => classify(ip) === 'metadata');
  return answer ? `metadata endpoint ${host} (${formatAddress(answer)})` : `metadata endpoint ${host}`;
}

async function resolveHost(
  name: string,
  resolve: Resolver,
): Promise<{ ok: true; addresses: IpAddress[] } | { ok: false; error: 'dns_resolution_failed' | 'too_many_dns_addresses' }> {
  let answers: unknown;
  try {
    answers = await resolve(name);
  } catch {
    return { ok: false, error: 'dns_resolution_failed' };
  }
  if (!Array.isArray(answers)) return { ok: false, error: 'dns_resolution_failed' };
  if (answers.length > MAX_ADDRESSES) return { ok: false, error: 'too_many_dns_addresses' };
  const unique = new Map<string, IpAddress>();
  for (const answer of answers) {
    const address = typeof answer === 'string' && net.isIP(answer) !== 0 ? parseLiteral(answer) : null;
    if (!address) return { ok: false, error: 'dns_resolution_failed' };
    unique.set(address.join(','), address);
  }
  return unique.size === 0 ? { ok: false, error: 'dns_resolution_failed' } : { ok: true, addresses: [...unique.values()] };
}

function compareWords(a: IpAddress, b: IpAddress): number {
  const index = a.findIndex((word, i) => word !== b[i]);
  return index === -1 ? 0 : a[index] - b[index];
}

// IPv6 forms that deliver to an embedded IPv4 destination.
function embeddedIpv4(address: IpAddress): IpAddress | null {
  if (address.length === 4) return address;
  const [a, b, c, d, e, f, hi, lo] = address;
  const ipv4 = [hi >> 8, hi & 0xff, lo >> 8, lo & 0xff];
  if (a === 0 && b === 0 && c === 0 && d === 0 && e === 0 && f === 0xffff) return ipv4; // IPv4-mapped
  if (a === 0x64 && b === 0xff9b && c === 0 && d === 0 && e === 0 && f === 0) return ipv4; // NAT64
  // IPv4-compatible (deprecated ::a.b.c.d), excluding :: and ::1.
  if (a === 0 && b === 0 && c === 0 && d === 0 && e === 0 && f === 0 && (hi !== 0 || lo > 1)) return ipv4;
  return null;
}

function classifyIpv4([a, b, c, d]: IpAddress): AddressClass {
  if ((a === 169 && b === 254) || (a === 100 && b === 100 && c === 100 && d === 200)) return 'metadata';
  const reserved =
    a === 0 ||
    a === 10 ||
    a === 127 ||
    a >= 224 ||
    (a === 100 && b >= 64 && b <= 127) ||
    (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 0 && (c === 0 || c === 2)) ||
    (a === 192 && b === 88 && c === 99) ||
    (a === 192 && b === 168) ||
    (a === 198 && (b === 18 || b === 19)) ||
    (a === 198 && b === 51 && c === 100) ||
    (a === 203 && b === 0 && c === 113);
  return reserved ? 'private' : 'public';
}

function classifyIpv6(address: IpAddress): AddressClass {
  const [first, second, third] = address;
  if (compareWords(address, EC2_METADATA_IPV6) === 0) return 'metadata';
  if ((first & 0xffc0) === 0xfe80) return 'metadata';
  // 6to4 is never public, and is metadata when it embeds a metadata address.
  if (first === 0x2002) {
    return classifyIpv4([second >> 8, second & 0xff, third >> 8, third & 0xff]) === 'metadata' ? 'metadata' : 'private';
  }
  // Only allocated global unicast (2000::/3) is public; exclude special-purpose
  // 2001::/23 (Teredo, ORCHID, benchmarking), documentation and 3fff::/20.
  const global =
    first >= 0x2000 &&
    first <= 0x3fff &&
    !((first === 0x2001 && second < 0x0200) || (first === 0x2001 && second === 0x0db8) || (first === 0x3fff && second < 0x1000));
  return global ? 'public' : 'private';
}
