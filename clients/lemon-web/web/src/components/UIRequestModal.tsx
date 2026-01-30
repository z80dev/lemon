import { useEffect, useMemo, useState } from 'react';
import type { SelectOption } from '@lemon-web/shared';
import { useLemonStore } from '../store/useLemonStore';

export function UIRequestModal() {
  const request = useLemonStore((state) => state.ui.requestsQueue[0]);
  const dequeue = useLemonStore((state) => state.dequeueUIRequest);
  const send = useLemonStore((state) => state.send);
  const connectionState = useLemonStore((state) => state.connection.state);
  const enqueueNotification = useLemonStore((state) => state.enqueueNotification);

  const [inputValue, setInputValue] = useState('');
  const [selectedOption, setSelectedOption] = useState<SelectOption | null>(null);
  const [filter, setFilter] = useState('');

  useEffect(() => {
    setSelectedOption(null);
    setFilter('');
    if (!request) {
      setInputValue('');
      return;
    }
    if (request.method === 'input' || request.method === 'editor') {
      const prefill = (request.params as { prefill?: string; placeholder?: string }).prefill;
      setInputValue(prefill ?? '');
    } else {
      setInputValue('');
    }
  }, [request]);

  const options = useMemo(() => {
    if (!request || request.method !== 'select') return [];
    const list = (request.params as { options?: SelectOption[] }).options ?? [];
    if (!filter.trim()) return list;
    return list.filter((opt) =>
      `${opt.label} ${opt.description ?? ''}`.toLowerCase().includes(filter.toLowerCase())
    );
  }, [request, filter]);

  if (!request) {
    return null;
  }

  const respond = (result: unknown, error: string | null = null) => {
    if (connectionState !== 'connected') {
      enqueueNotification({
        id: `ui-response-${request.id}-${Date.now()}`,
        message: 'Cannot send response while disconnected. Reconnect and try again.',
        level: 'error',
        createdAt: Date.now(),
      });
      return;
    }
    send({ type: 'ui_response', id: request.id, result, error });
    dequeue();
  };

  const onCancel = () => respond(null, null);

  return (
    <div className="modal-overlay">
      <div className="modal">
        <header className="modal__header">
          <h3>{request.params.title}</h3>
          <button className="ghost-button" onClick={onCancel}>
            Close
          </button>
        </header>

        {request.method === 'select' ? (
          <div className="modal__body">
            <input
              className="modal-input"
              placeholder="Filter options"
              value={filter}
              onChange={(event) => setFilter(event.target.value)}
            />
            <div className="modal-options">
              {options.map((option) => (
                <button
                  key={option.value}
                  className={`option-button ${
                    selectedOption?.value === option.value ? 'option-button--active' : ''
                  }`}
                  onClick={() => setSelectedOption(option)}
                >
                  <div>
                    <div className="option-button__label">{option.label}</div>
                    {option.description ? (
                      <div className="option-button__desc">{option.description}</div>
                    ) : null}
                  </div>
                  <span className="option-button__value">{option.value}</span>
                </button>
              ))}
            </div>
          </div>
        ) : null}

        {request.method === 'confirm' ? (
          <div className="modal__body">
            <p>{(request.params as { message?: string }).message}</p>
          </div>
        ) : null}

        {request.method === 'input' ? (
          <div className="modal__body">
            <input
              className="modal-input"
              placeholder={(request.params as { placeholder?: string }).placeholder ?? ''}
              value={inputValue}
              onChange={(event) => setInputValue(event.target.value)}
            />
          </div>
        ) : null}

        {request.method === 'editor' ? (
          <div className="modal__body">
            <textarea
              className="modal-textarea"
              rows={8}
              value={inputValue}
              onChange={(event) => setInputValue(event.target.value)}
            />
          </div>
        ) : null}

        <footer className="modal__footer">
          {request.method === 'confirm' ? (
            <>
              <button className="pill-button" onClick={() => respond(false, null)}>
                Cancel
              </button>
              <button className="pill-button pill-button--primary" onClick={() => respond(true, null)}>
                Confirm
              </button>
            </>
          ) : null}
          {request.method === 'select' ? (
            <>
              <button className="pill-button" onClick={onCancel}>
                Cancel
              </button>
              <button
                className="pill-button pill-button--primary"
                onClick={() => respond(selectedOption?.value ?? null, null)}
                disabled={!selectedOption}
              >
                Choose
              </button>
            </>
          ) : null}
          {request.method === 'input' ? (
            <>
              <button className="pill-button" onClick={onCancel}>
                Cancel
              </button>
              <button className="pill-button pill-button--primary" onClick={() => respond(inputValue, null)}>
                Submit
              </button>
            </>
          ) : null}
          {request.method === 'editor' ? (
            <>
              <button className="pill-button" onClick={onCancel}>
                Cancel
              </button>
              <button className="pill-button pill-button--primary" onClick={() => respond(inputValue, null)}>
                Save
              </button>
            </>
          ) : null}
        </footer>
      </div>
    </div>
  );
}
