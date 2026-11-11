/** Display only: never pass escaped or shortened text back to execution. */
export function approvalTextPresentation(value: string) {
  let hasControls = false;
  const text = value.replace(/[\p{Cf}\p{Default_Ignorable_Code_Point}\u0000-\u0008\u000b-\u001f\u007f-\u009f\u2028\u2029]/gu, control => {
    hasControls = true;
    return `⟨U+${control.codePointAt(0)!.toString(16).toUpperCase().padStart(4, '0')}⟩`;
  });
  const characters = Array.from(text);
  const truncated = characters.length > 160;
  return { text, preview: truncated ? characters.slice(0, 159).join('') + '…' : text, truncated, hasControls };
}
