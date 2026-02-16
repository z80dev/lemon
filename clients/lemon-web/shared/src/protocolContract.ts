import protocolContractJson from './protocol_contract.json';

import type { ServerMessage } from './types.js';

export interface FrameContractEntry {
  required: readonly string[];
}

export interface ProtocolContract {
  version: number;
  core_frames: Record<string, FrameContractEntry>;
}

export const PROTOCOL_CONTRACT: ProtocolContract = protocolContractJson as ProtocolContract;

export const CORE_FRAME_CONTRACT: Record<string, FrameContractEntry> = PROTOCOL_CONTRACT.core_frames;

export const CORE_FRAME_TYPES = Object.keys(CORE_FRAME_CONTRACT);

export interface ContractValidationResult {
  ok: boolean;
  type?: string;
  missing: string[];
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function getFrameType(value: Record<string, unknown>): string | null {
  const frameType = value.type;
  return typeof frameType === 'string' ? frameType : null;
}

function hasField(value: Record<string, unknown>, field: string): boolean {
  return Object.prototype.hasOwnProperty.call(value, field);
}

export function getRequiredCoreFrameFields(frameType: string): readonly string[] | null {
  const entry = CORE_FRAME_CONTRACT[frameType];
  if (!entry || !Array.isArray(entry.required)) {
    return null;
  }

  return entry.required;
}

export function validateCoreServerFrame(value: unknown): ContractValidationResult {
  if (!isRecord(value)) {
    return { ok: false, missing: ['type'] };
  }

  const frameType = getFrameType(value);
  if (!frameType) {
    return { ok: false, missing: ['type'] };
  }

  const required = getRequiredCoreFrameFields(frameType);
  if (!required) {
    return { ok: false, type: frameType, missing: ['<unknown_type>'] };
  }

  const missing = required.filter((field) => !hasField(value, field));

  return {
    ok: missing.length === 0,
    type: frameType,
    missing,
  };
}

export function isCoreServerFrame(value: unknown): value is ServerMessage {
  return validateCoreServerFrame(value).ok;
}
