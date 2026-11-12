import {Policy} from '../../src/policy.ts';
import {decodeLayer,decodeRequest} from './codec.ts';
function layers(raw:unknown){if(!Array.isArray(raw))throw Error('wire layers');return raw.map(decodeLayer);}
export function create(raw:unknown) {
 const policy=new Policy(layers(raw));
 return {
  authorize:(request:unknown)=>policy.decide(decodeRequest(request)),
  explain:(request:unknown)=>policy.explain(decodeRequest(request)),
  reload:(next:unknown)=>policy.replace(layers(next)),
  snapshot:()=>policy.exportLayers(),
 };
}
