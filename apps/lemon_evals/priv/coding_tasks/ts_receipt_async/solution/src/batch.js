import { printReceipt } from './console.js';
export async function collectReceipts(ids,store) {
  const results=[];
  for(const id of ids) results.push(await printReceipt(id,store));
  return results;
}
