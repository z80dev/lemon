export class OrderNotFoundError extends Error {
  constructor(id) { super(`order not found: ${id}`); this.name='OrderNotFoundError'; this.id=id; }
}
export function loadReceipt(id, store, callback) {
  store.open((error,session) => {
    if(error) return callback(error);
    session.order(id,(error,order)=>{
      if(error || !order) return session.close(()=>callback(error ?? new OrderNotFoundError(id)));
      session.customer(order.customerId,(error,customer)=>{
        if(error) return session.close(()=>callback(error));
        let totalCents=0, index=0;
        function next() {
          if(index===order.lines.length) return session.close(error=>callback(error,{id,customer:customer?.name ?? 'Guest',totalCents}));
          const line=order.lines[index++];
          session.price(line.sku,(error,price)=>{if(error) return session.close(()=>callback(error)); totalCents+=price*line.quantity; next();});
        }
        next();
      });
    });
  });
}
