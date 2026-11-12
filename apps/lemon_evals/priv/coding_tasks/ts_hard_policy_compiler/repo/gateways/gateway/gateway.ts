import {Policy} from '../../src/policy.ts';
import {decodeLayer,decodeRequest} from './codec.ts';
export function create(raw:any) {
 const policy=new Policy(raw.map(decodeLayer));
 return {authorize:(request:unknown)=>policy.decide(decodeRequest(request))};
}
