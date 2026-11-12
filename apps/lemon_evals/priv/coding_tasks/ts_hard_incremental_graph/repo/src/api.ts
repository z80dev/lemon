import * as assets from "../products/assets/frontend.ts";
import * as billing from "../products/billing/frontend.ts";
import * as catalog from "../products/catalog/frontend.ts";
import * as delivery from "../products/delivery/frontend.ts";
import * as exports from "../products/exports/frontend.ts";
import * as fraud from "../products/fraud/frontend.ts";
import * as gateway from "../products/gateway/frontend.ts";
import * as hosting from "../products/hosting/frontend.ts";
import * as identity from "../products/identity/frontend.ts";
import * as jobs from "../products/jobs/frontend.ts";
import * as keys from "../products/keys/frontend.ts";
import * as logging from "../products/logging/frontend.ts";
import * as metrics from "../products/metrics/frontend.ts";
import * as notices from "../products/notices/frontend.ts";
import * as orders from "../products/orders/frontend.ts";
import * as payments from "../products/payments/frontend.ts";
export const products = ["assets", "billing", "catalog", "delivery", "exports", "fraud", "gateway", "hosting", "identity", "jobs", "keys", "logging", "metrics", "notices", "orders", "payments"];
const frontends = new Map([["assets",assets],["billing",billing],["catalog",catalog],["delivery",delivery],["exports",exports],["fraud",fraud],["gateway",gateway],["hosting",hosting],["identity",identity],["jobs",jobs],["keys",keys],["logging",logging],["metrics",metrics],["notices",notices],["orders",orders],["payments",payments]]);
export function create(product:string,raw:unknown) {
  const frontend=frontends.get(product);if(!frontend) throw Error('unknown product');return frontend.create(raw);
}
export function summarize(product:string,raw:unknown,targets:string[],inputs:Record<string,number>) {
  return create(product,raw).run(targets,inputs).values;
}
