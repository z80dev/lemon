import { flatten } from "./loader.js";
import { mergeArtifacts } from "./merge.js";
import { resolveArtifact } from "./paths.js";
export function compileManifest(documents, entry, env = {}) {
  return mergeArtifacts(flatten(documents, entry)).map((record) => resolveArtifact(record, env));
}
