import { describe, it, expect } from 'vitest';

import { JsonLineDecoder, encodeJsonLine } from './codec';
import {
  CORE_FRAME_CONTRACT,
  CORE_FRAME_TYPES,
  getRequiredCoreFrameFields,
  isCoreServerFrame,
  validateCoreServerFrame,
} from './protocolContract';

function sampleValueForField(field: string): unknown {
  switch (field) {
    case 'type':
      return 'placeholder_type';
    case 'cwd':
      return '/tmp';
    case 'model':
      return { provider: 'openai', id: 'gpt-4o' };
    case 'debug':
      return false;
    case 'ui':
      return true;
    case 'primary_session_id':
      return null;
    case 'active_session_id':
      return null;
    case 'session_id':
      return 'sess_1';
    case 'event':
      return { type: 'agent_start' };
    case 'stats':
      return { session_id: 'sess_1', cwd: '/tmp', message_count: 1, turn_count: 1, is_streaming: false };
    case 'message':
      return 'message';
    case 'ok':
      return true;
    case 'sessions':
      return [];
    case 'providers':
      return [];
    case 'reason':
      return 'normal';
    case 'config':
      return { claude_skip_permissions: false, codex_auto_approve: true };
    default:
      return `value_for_${field}`;
  }
}

function buildSampleFrame(frameType: string): Record<string, unknown> {
  const required = getRequiredCoreFrameFields(frameType);
  if (!required) {
    throw new Error(`Unknown frame type: ${frameType}`);
  }

  const frame: Record<string, unknown> = {};
  for (const field of required) {
    frame[field] = sampleValueForField(field);
  }

  frame.type = frameType;
  return frame;
}

describe('protocol contract core frames', () => {
  it('can derive sample coverage for every core frame type from the contract', () => {
    const derivedTypes = CORE_FRAME_TYPES.map((frameType) => buildSampleFrame(frameType).type);
    expect(derivedTypes.sort()).toEqual(CORE_FRAME_TYPES.slice().sort());
  });

  it('accepts all sample core frames', () => {
    for (const frameType of CORE_FRAME_TYPES) {
      const frame = buildSampleFrame(frameType);
      const result = validateCoreServerFrame(frame);

      expect(result.ok).toBe(true);
      expect(result.type).toBe(frameType);
      expect(result.missing).toEqual([]);
      expect(isCoreServerFrame(frame)).toBe(true);
    }
  });

  it('decoder + guard accepts all core frames', () => {
    const decodedTypes: string[] = [];

    const decoder = new JsonLineDecoder({
      onMessage: (value) => {
        expect(isCoreServerFrame(value)).toBe(true);
        decodedTypes.push((value as { type: string }).type);
      },
    });

    for (const frameType of CORE_FRAME_TYPES) {
      decoder.write(encodeJsonLine(buildSampleFrame(frameType)));
    }

    expect(decodedTypes.sort()).toEqual(CORE_FRAME_TYPES.slice().sort());
  });

  it('rejects frames missing required fields', () => {
    for (const frameType of CORE_FRAME_TYPES) {
      const required = getRequiredCoreFrameFields(frameType);
      expect(required).not.toBeNull();

      const fieldToRemove = required![0];
      const invalidFrame = { ...buildSampleFrame(frameType) };
      delete invalidFrame[fieldToRemove];

      const result = validateCoreServerFrame(invalidFrame);
      expect(result.ok).toBe(false);
      if (fieldToRemove === 'type') {
        expect(result.type).toBeUndefined();
      } else {
        expect(result.type).toBe(frameType);
      }
      expect(result.missing).toContain(fieldToRemove);
      expect(isCoreServerFrame(invalidFrame)).toBe(false);
    }
  });

  it('rejects unknown frame types', () => {
    const unknown = { type: 'totally_unknown_type' };
    const result = validateCoreServerFrame(unknown);

    expect(result.ok).toBe(false);
    expect(result.type).toBe('totally_unknown_type');
    expect(result.missing).toContain('<unknown_type>');
    expect(isCoreServerFrame(unknown)).toBe(false);
  });

  it('contract requires `type` for all core frames', () => {
    for (const [frameType, schema] of Object.entries(CORE_FRAME_CONTRACT)) {
      expect(schema.required).toContain('type');
      expect(schema.required.length).toBeGreaterThan(0);
      expect(frameType).toBeTypeOf('string');
    }
  });
});
