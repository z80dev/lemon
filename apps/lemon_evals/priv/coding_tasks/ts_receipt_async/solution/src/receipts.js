export class OrderNotFoundError extends Error {
  constructor(id) { super(`order not found: ${id}`); this.name='OrderNotFoundError'; this.id=id; }
}
export async function buildReceipt(id,store) {
  const session=await store.open();
  let failed=false;
  try {
    const order=await session.order(id);
    if(order===null) throw new OrderNotFoundError(id);
    const customer=await session.customer(order.customerId);
    let totalCents=0;
    for(const line of order.lines) totalCents+=(await session.price(line.sku))*line.quantity;
    return {id,customer:customer?.name ?? 'Guest',totalCents};
  } catch(error) { failed=true; throw error; }
  finally { try { await session.close(); } catch(error) { if(!failed) throw error; } }
}
