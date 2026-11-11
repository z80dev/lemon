import type { Hub } from './hub.ts';
export interface Reading { sensor: string; value: number }
export interface Alarm extends Reading { limit: number }
export interface MonitorEvents { reading: Reading; alarm: Alarm }

export function attachAlarmRule(hub: Hub<MonitorEvents>, limit: number): () => void {
  return hub.subscribe('reading', reading => {
    if (reading.value > limit) hub.publish('alarm', { ...reading, limit });
  });
}

export function collectAlarms(hub: Hub<MonitorEvents>): { alarms: Alarm[]; stop: () => void } {
  const alarms: Alarm[] = [];
  const stop = hub.subscribe('alarm', alarm => { alarms.push(alarm); });
  return { alarms, stop };
}
