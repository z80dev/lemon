import {vocabulary as v} from './vocabulary.ts';
import type {Layer,Request} from '../../src/policy.ts';
export function decodeLayer(raw:any):Layer {
 return {name:raw[v.layer],remove:[],rules:raw[v.rules].map((r:any)=>({id:r[v.id],effect:r[v.effect],resource:r[v.path],actions:r[v.actions],priority:r[v.priority],conditions:{}}))};
}
export function decodeRequest(raw:any):Request{return {resource:raw[v.path],action:raw[v.action],attributes:{}};}
