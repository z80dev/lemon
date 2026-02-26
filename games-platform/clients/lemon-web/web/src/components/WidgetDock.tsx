import { useMemo } from 'react';
import { useLemonStore } from '../store/useLemonStore';

export function WidgetDock() {
  const widgets = useLemonStore((state) => state.ui.widgets);

  const widgetEntries = useMemo(() => Object.values(widgets), [widgets]);

  if (widgetEntries.length === 0) {
    return null;
  }

  return (
    <section className="widget-dock">
      {widgetEntries.map((widget) => (
        <div key={widget.key} className="widget-card">
          <div className="widget-card__title">{widget.key}</div>
          <pre>{JSON.stringify(widget.content, null, 2)}</pre>
        </div>
      ))}
    </section>
  );
}
