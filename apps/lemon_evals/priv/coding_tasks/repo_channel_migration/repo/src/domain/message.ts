export type Message = { id: string; recipient: string; text: string };
export function message(id: string, recipient: string, text: string): Message {
  if (!id.trim() || !recipient.trim() || !text.trim()) throw new Error('message fields must be nonempty');
  return { id, recipient, text };
}
