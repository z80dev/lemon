import { flatten } from "./loader.js";
import { mergeArtifacts } from "./merge.js";
import { resolveArtifact } from "./paths.js";
export function compileManifest(documents, entry, env = {}) {
  const resolved = flatten(documents, entry).map((record) => ({ ...record, ...resolveArtifact(record, env) }));
  return mergeArtifacts(resolved).map(({ id, path }) => ({ id, path }));
}
