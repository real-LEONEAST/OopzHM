export function normalizeChatText(content?: string | number | null, text?: string | number | null): string {
  const message = typeof content === 'number' ? String(content) : content;
  if (typeof message === 'string' && message.trim().length > 0) {
    return message;
  }
  if (typeof text === 'number') {
    return String(text);
  }
  return typeof text === 'string' ? text : '';
}
