export function flatten(documents, entry) {
  const seen = new Set;
  const stack = [];
  const output = [];
  function visit(name) {
    if (seen.has(name))
      throw new Error(`Manifest cycle: ${[...stack, name].join(" -> ")}`);
    const doc = documents[name];
    if (!doc)
      throw new Error(`Unknown manifest: ${name}`);
    seen.add(name);
    stack.push(name);
    for (const included of doc.includes ?? [])
      visit(included);
    output.push(...doc.artifacts ?? []);
    stack.pop();
  }
  visit(entry);
  return output;
}
