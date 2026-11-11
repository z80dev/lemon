import type { Config } from '../config/types.ts';
export function metricKey(config: Config, tenant: string): string { return `dispatch.${tenant}.${config.deliveryChannel}`; }
