import {schema} from './schema.ts';
import type {NodeSpec} from '../../src/graph.ts';
export function compile(raw:any):NodeSpec[] {
  return raw.map((n:any)=>({id:n[schema.id],deps:n[schema.deps],kind:n[schema.kind]}));
}
