import { buildReceipt } from './receipts.js';
export async function printReceipt(id,store) {
  const receipt=await buildReceipt(id,store);
  return `${receipt.id} | ${receipt.customer} | ${receipt.totalCents}`;
}
