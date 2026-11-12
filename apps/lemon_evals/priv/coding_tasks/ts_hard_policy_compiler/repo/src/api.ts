import * as assets from "../gateways/assets/gateway.ts";
import * as billing from "../gateways/billing/gateway.ts";
import * as catalog from "../gateways/catalog/gateway.ts";
import * as delivery from "../gateways/delivery/gateway.ts";
import * as exports from "../gateways/exports/gateway.ts";
import * as fraud from "../gateways/fraud/gateway.ts";
import * as gateway from "../gateways/gateway/gateway.ts";
import * as hosting from "../gateways/hosting/gateway.ts";
import * as identity from "../gateways/identity/gateway.ts";
import * as jobs from "../gateways/jobs/gateway.ts";
import * as keys from "../gateways/keys/gateway.ts";
import * as logging from "../gateways/logging/gateway.ts";
import * as metrics from "../gateways/metrics/gateway.ts";
import * as notices from "../gateways/notices/gateway.ts";
import * as orders from "../gateways/orders/gateway.ts";
import * as payments from "../gateways/payments/gateway.ts";
export const gateways = ["assets", "billing", "catalog", "delivery", "exports", "fraud", "gateway", "hosting", "identity", "jobs", "keys", "logging", "metrics", "notices", "orders", "payments"];
const registry = new Map([["assets",assets],["billing",billing],["catalog",catalog],["delivery",delivery],["exports",exports],["fraud",fraud],["gateway",gateway],["hosting",hosting],["identity",identity],["jobs",jobs],["keys",keys],["logging",logging],["metrics",metrics],["notices",notices],["orders",orders],["payments",payments]]);
export function create(name:string,layers:unknown){const gateway=registry.get(name);if(!gateway)throw Error('unknown gateway');return gateway.create(layers);}
export function check(name:string,layers:unknown,request:unknown){return create(name,layers).authorize(request);}
