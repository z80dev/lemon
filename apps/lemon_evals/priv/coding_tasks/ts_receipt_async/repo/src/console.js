import { loadReceipt } from './receipts.js';
export async function printReceipt(id,store) {
  const receipt=await new Promise((resolve,reject)=>loadReceipt(id,store,(error,value)=>error?reject(error):resolve(value)));
  return `${receipt.id} | ${receipt.customer} | ${receipt.totalCents}`;
}
