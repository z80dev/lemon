import { useLemonStore } from '../store/useLemonStore';

export function WorkingBanner() {
  const workingMessage = useLemonStore((state) => state.ui.workingMessage);

  if (!workingMessage) {
    return null;
  }

  return (
    <div className="working-banner">
      <span className="spinner" />
      <span>{workingMessage}</span>
    </div>
  );
}
