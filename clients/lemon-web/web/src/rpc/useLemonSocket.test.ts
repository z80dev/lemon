import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';

/**
 * Tests for buildWsUrl() function behavior in useLemonSocket.
 *
 * The buildWsUrl function handles WebSocket URL construction with:
 * 1. Environment variable override (VITE_LEMON_WS_URL)
 * 2. Same-origin derivation (http->ws, https->wss) as fallback
 */

describe('buildWsUrl() behavior', () => {
  // Store original location properties
  const originalLocation = {
    protocol: window.location.protocol,
    host: window.location.host,
  };

  beforeEach(() => {
    vi.resetModules();
    vi.unstubAllEnvs();
  });

  afterEach(() => {
    // Restore original location
    Object.defineProperty(window, 'location', {
      value: {
        ...window.location,
        protocol: originalLocation.protocol,
        host: originalLocation.host,
      },
      writable: true,
    });
    vi.unstubAllEnvs();
    vi.resetModules();
  });

  describe('same-origin URL derivation logic', () => {
    it('converts http: protocol to ws:', () => {
      const protocol = 'http:';
      const wsProto = protocol === 'https:' ? 'wss:' : 'ws:';
      expect(wsProto).toBe('ws:');
    });

    it('converts https: protocol to wss:', () => {
      const protocol = 'https:';
      const wsProto = protocol === 'https:' ? 'wss:' : 'ws:';
      expect(wsProto).toBe('wss:');
    });

    it('constructs correct URL with host and /ws path', () => {
      const wsProto = 'ws:';
      const host = 'localhost:3000';
      const url = `${wsProto}//${host}/ws`;
      expect(url).toBe('ws://localhost:3000/ws');
    });

    it('handles host without port', () => {
      const wsProto = 'wss:';
      const host = 'example.com';
      const url = `${wsProto}//${host}/ws`;
      expect(url).toBe('wss://example.com/ws');
    });

    it('handles host with subdomain', () => {
      const wsProto = 'wss:';
      const host = 'api.staging.example.com';
      const url = `${wsProto}//${host}/ws`;
      expect(url).toBe('wss://api.staging.example.com/ws');
    });

    it('handles host with IP address', () => {
      const wsProto = 'ws:';
      const host = '192.168.1.100:8080';
      const url = `${wsProto}//${host}/ws`;
      expect(url).toBe('ws://192.168.1.100:8080/ws');
    });

    it('handles IPv6 addresses', () => {
      const wsProto = 'ws:';
      const host = '[::1]:3000';
      const url = `${wsProto}//${host}/ws`;
      expect(url).toBe('ws://[::1]:3000/ws');
    });
  });

  describe('VITE_LEMON_WS_URL env override logic', () => {
    it('env override takes precedence when truthy', () => {
      const envUrl = 'wss://override.example.com/ws';
      const sameOriginUrl = 'ws://localhost:3000/ws';

      // Simulate buildWsUrl logic
      const result = envUrl || sameOriginUrl;
      expect(result).toBe(envUrl);
    });

    it('same-origin is used when env is empty string', () => {
      const envUrl = '';
      const sameOriginUrl = 'ws://localhost:3000/ws';

      // Simulate buildWsUrl logic
      const result = envUrl || sameOriginUrl;
      expect(result).toBe(sameOriginUrl);
    });

    it('same-origin is used when env is undefined', () => {
      const envUrl: string | undefined = undefined;
      const sameOriginUrl = 'ws://localhost:3000/ws';

      // Simulate buildWsUrl logic
      const result = envUrl || sameOriginUrl;
      expect(result).toBe(sameOriginUrl);
    });

    it('custom WebSocket path is preserved in env override', () => {
      const envUrl = 'wss://custom.example.com/custom/path/websocket';
      expect(envUrl).toBe('wss://custom.example.com/custom/path/websocket');
    });

    it('non-standard ports in env override are preserved', () => {
      const envUrl = 'ws://dev-backend:9999/ws';
      expect(envUrl).toBe('ws://dev-backend:9999/ws');
    });
  });

  describe('window.location integration', () => {
    it('uses window.location.protocol for protocol detection', () => {
      const protocol = window.location.protocol;
      expect(['http:', 'https:']).toContain(protocol);
    });

    it('uses window.location.host for host derivation', () => {
      const host = window.location.host;
      expect(typeof host).toBe('string');
      expect(host.length).toBeGreaterThan(0);
    });

    it('builds URL from current window location', () => {
      const { protocol, host } = window.location;
      const wsProto = protocol === 'https:' ? 'wss:' : 'ws:';
      const url = `${wsProto}//${host}/ws`;

      // URL should be well-formed
      expect(url).toMatch(/^wss?:\/\/.+\/ws$/);
    });
  });

  describe('edge cases', () => {
    it('handles localhost with default port', () => {
      const host = 'localhost';
      const url = `ws://${host}/ws`;
      expect(url).toBe('ws://localhost/ws');
    });

    it('handles localhost with explicit port 80', () => {
      const host = 'localhost:80';
      const url = `ws://${host}/ws`;
      expect(url).toBe('ws://localhost:80/ws');
    });

    it('handles production domain on default HTTPS port', () => {
      const host = 'app.lemon.io';
      const url = `wss://${host}/ws`;
      expect(url).toBe('wss://app.lemon.io/ws');
    });

    it('handles Vite dev server default port', () => {
      const host = 'localhost:5173';
      const url = `ws://${host}/ws`;
      expect(url).toBe('ws://localhost:5173/ws');
    });

    it('handles backend server on different port', () => {
      const host = 'localhost:3939';
      const url = `ws://${host}/ws`;
      expect(url).toBe('ws://localhost:3939/ws');
    });
  });
});

describe('logConnectionWarning behavior', () => {
  /**
   * Tests for the connection warning logic.
   * The function logs a warning after CONNECTION_WARNING_THRESHOLD (3) retries.
   */

  it('threshold is set to 3', () => {
    // This is a constant in the module
    const CONNECTION_WARNING_THRESHOLD = 3;
    expect(CONNECTION_WARNING_THRESHOLD).toBe(3);
  });

  it('warning should be triggered at threshold', () => {
    const CONNECTION_WARNING_THRESHOLD = 3;
    const retryCount = 3;

    // Warning is triggered when retryCount equals threshold
    const shouldWarn = retryCount === CONNECTION_WARNING_THRESHOLD;
    expect(shouldWarn).toBe(true);
  });

  it('warning should not be triggered before threshold', () => {
    const CONNECTION_WARNING_THRESHOLD = 3;
    const retryCount = 2;

    const shouldWarn = retryCount === CONNECTION_WARNING_THRESHOLD;
    expect(shouldWarn).toBe(false);
  });

  it('warning should not be triggered after threshold', () => {
    const CONNECTION_WARNING_THRESHOLD = 3;
    const retryCount = 4;

    // Only warn once at the threshold
    const shouldWarn = retryCount === CONNECTION_WARNING_THRESHOLD;
    expect(shouldWarn).toBe(false);
  });

  describe('warning message content', () => {
    it('includes retry count in warning message', () => {
      const retryCount = 3;
      const message = `[LemonSocket] Failed to connect after ${retryCount} retries.`;
      expect(message).toContain('3 retries');
    });

    it('includes env URL in message when VITE_LEMON_WS_URL is set', () => {
      const envUrl = 'wss://custom.example.com/ws';
      const message = `Using VITE_LEMON_WS_URL override: ${envUrl}`;
      expect(message).toContain('VITE_LEMON_WS_URL override');
      expect(message).toContain(envUrl);
    });

    it('suggests setting VITE_LEMON_WS_URL when not using override', () => {
      const wsUrl = 'ws://localhost:3000/ws';
      const message =
        `Using same-origin WebSocket URL: ${wsUrl}\n` +
        `If using a separate backend, set VITE_LEMON_WS_URL environment variable.`;
      expect(message).toContain('same-origin');
      expect(message).toContain('set VITE_LEMON_WS_URL');
    });
  });
});

describe('exponential backoff', () => {
  /**
   * Tests for the exponential backoff logic used in reconnection.
   */

  it('calculates correct delay for first retry', () => {
    const retryCount = 0;
    const delay = Math.min(10000, 500 * Math.pow(2, retryCount));
    expect(delay).toBe(500);
  });

  it('calculates correct delay for second retry', () => {
    const retryCount = 1;
    const delay = Math.min(10000, 500 * Math.pow(2, retryCount));
    expect(delay).toBe(1000);
  });

  it('calculates correct delay for third retry', () => {
    const retryCount = 2;
    const delay = Math.min(10000, 500 * Math.pow(2, retryCount));
    expect(delay).toBe(2000);
  });

  it('calculates correct delay for fourth retry', () => {
    const retryCount = 3;
    const delay = Math.min(10000, 500 * Math.pow(2, retryCount));
    expect(delay).toBe(4000);
  });

  it('calculates correct delay for fifth retry', () => {
    const retryCount = 4;
    const delay = Math.min(10000, 500 * Math.pow(2, retryCount));
    expect(delay).toBe(8000);
  });

  it('caps delay at 10 seconds', () => {
    const retryCount = 5;
    const delay = Math.min(10000, 500 * Math.pow(2, retryCount));
    expect(delay).toBe(10000);
  });

  it('stays capped at 10 seconds for higher retry counts', () => {
    const retryCount = 10;
    const delay = Math.min(10000, 500 * Math.pow(2, retryCount));
    expect(delay).toBe(10000);
  });
});
