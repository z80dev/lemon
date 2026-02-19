/* ── Lemon Poker – Elite Spectator App ── */

const SUIT_MAP = { c: '♣', d: '♦', h: '♥', s: '♠' };
const SUIT_COLOR = { c: 'black', d: 'red', h: 'red', s: 'black' };
const RANK_DISPLAY = { T: '10' };
const PLAYER_MIN = 2;
const PLAYER_MAX = 9;
const FALLBACK_PERSONAS = [
  'grinder',
  'aggro',
  'friendly',
  'silent',
  'tourist',
  'showman',
  'professor',
  'road_dog',
  'dealer_friend',
  'homegame_legend'
];
const MODEL_SUGGESTIONS = [
  'gpt-5.3-codex',
  'gpt-5-codex',
  'openai-codex:gpt-5.3-codex',
  'openai-codex:gpt-5-codex',
  'claude-opus-4.1',
  'claude-sonnet-4.5',
  'gemini-2.5-pro',
  'o3'
];
const MODEL_SUGGESTIONS_DATALIST_ID = 'poker-model-suggestions';

const state = {
  status: 'idle',
  config: null,
  table: null,
  seats: [],
  hand_index: 0,
  events: [],
  started_at: null,
  finished_at: null,
  wsConnected: false
};

/* ── Diff tracking ── */
let lastBoardKey = '';
let lastBoardLabel = '';
let lastPotAmount = null;
let lastPotVisible = false;
let lastHandBadge = '';
let lastStatusText = '';
let lastStatusClass = '';
let lastWsText = '';
let lastWsClass = '';
let lastMatchInfo = '';
let lastIdleVisible = null;
let lastScoreboardKey = '';
let lastSidePotsKey = '';
let feedActionRendered = 0;   // index into state.events for actions
let feedTalkRendered = 0;     // index into state.events for talk
let feedSnapshotGeneration = 0; // bumped on snapshot to force full rebuild

/* ── Thinking timer state ── */
let actingTimerInterval = null;
let actingTimerSeat = null;
let actingTimerStart = null;
let actingTimerEl = null;

/* ── DOM refs ── */
const $ = (sel) => document.querySelector(sel);
const statusPill = $('#status-pill');
const wsPill = $('#ws-pill');
const matchInfo = $('#match-info');
const pokerTable = $('#poker-table');
const boardCards = $('#board-cards');
const boardLabel = $('#board-label');
const potDisplay = $('#pot-display');
const potAmount = $('#pot-amount');
const potChips = $('#pot-chips');
const handBadge = $('#hand-badge');
const idleOverlay = $('#idle-overlay');
const actionFeed = $('#action-feed');
const talkFeed = $('#talk-feed');
const actionCount = $('#action-count');
const talkCount = $('#talk-count');
const scoreboard = $('#scoreboard');
const sidePotsEl = $('#side-pots');
const showdownOverlay = $('#showdown-overlay');
const showdownBoard = $('#showdown-board');
const showdownHands = $('#showdown-hands');
const winnerToast = $('#winner-toast');

const startForm = $('#start-form');
const talkForm = $('#talk-form');
const pauseBtn = $('#pause-btn');
const resumeBtn = $('#resume-btn');
const stopBtn = $('#stop-btn');
const adminToggle = $('#admin-toggle');
const playersInput = $('#f-players');
const personaGrid = $('#persona-grid');
const modelGrid = $('#model-grid');

let seatEls = [];        // seat wrapper elements
let seatData = [];       // cached per‐seat data for diffing
let toastTimeout = null;
let availablePersonas = [...FALLBACK_PERSONAS];
const personaSelectionBySeat = new Map();
const modelSelectionBySeat = new Map();

/* ── Init ── */
init();

async function init() {
  await loadPersonaOptions();
  bindControls();
  syncPersonaControls();
  syncModelControls();
  await refreshState();
  connectWebSocket();
}

/* ── Controls ── */
function bindControls() {
  adminToggle.addEventListener('click', () => {
    document.body.classList.toggle('drawer-open');
  });

  startForm.addEventListener('submit', async (e) => {
    e.preventDefault();
    await postJson('/api/match/start', readStartPayload());
  });

  if (playersInput) {
    const onPlayersChanged = () => {
      syncPersonaControls();
      syncModelControls();
    };
    playersInput.addEventListener('input', onPlayersChanged);
    playersInput.addEventListener('change', onPlayersChanged);
  }

  pauseBtn.addEventListener('click', () => postJson('/api/match/pause', {}));
  resumeBtn.addEventListener('click', () => postJson('/api/match/resume', {}));
  stopBtn.addEventListener('click', () => postJson('/api/match/stop', {}));

  talkForm.addEventListener('submit', async (e) => {
    e.preventDefault();
    const fd = new FormData(talkForm);
    await postJson('/api/table-talk', {
      seat: parseInt(fd.get('seat'), 10),
      actor: (fd.get('actor') || 'host').trim(),
      text: (fd.get('text') || '').trim()
    });
    talkForm.reset();
  });
}

function readStartPayload() {
  const fd = new FormData(startForm);
  const players = clamp(toInt(fd.get('players'), 6), PLAYER_MIN, PLAYER_MAX);
  return {
    players,
    hands: toInt(fd.get('hands'), 20),
    stack: toInt(fd.get('stack'), 1000),
    smallBlind: toInt(fd.get('smallBlind'), 50),
    bigBlind: toInt(fd.get('bigBlind'), 100),
    seed: blankToNull(fd.get('seed')),
    timeoutMs: toInt(fd.get('timeoutMs'), 90000),
    maxDecisions: toInt(fd.get('maxDecisions'), 200),
    tableId: blankToNull(fd.get('tableId')),
    agentId: blankToNull(fd.get('agentId')),
    model: blankToNull(fd.get('model')),
    playerAgentIds: parseCsv(fd.get('playerAgentIds')),
    playerModels: readPlayerModels(players),
    playerLabels: parseCsv(fd.get('playerLabels')),
    playerPersonas: readPlayerPersonas(players),
    systemPrompt: blankToNull(fd.get('systemPrompt')),
    tableTalkEnabled: !!fd.get('tableTalkEnabled')
  };
}

async function loadPersonaOptions() {
  try {
    const res = await fetch('/api/personas', { headers: { Accept: 'application/json' } });
    const payload = await res.json();

    if (res.ok && payload?.ok && Array.isArray(payload.personas)) {
      const loaded = normalizePersonaNames(payload.personas);
      if (loaded.length > 0) {
        availablePersonas = loaded;
        return;
      }
    }
  } catch {
    // Fall back to local defaults when persona endpoint is unavailable.
  }

  availablePersonas = [...FALLBACK_PERSONAS];
}

function syncPersonaControls() {
  if (!personaGrid || !playersInput) return;

  capturePersonaSelections();

  const playerCount = clamp(toInt(playersInput.value, 6), PLAYER_MIN, PLAYER_MAX);
  personaGrid.innerHTML = '';

  for (let seat = 1; seat <= playerCount; seat++) {
    const row = document.createElement('div');
    row.className = 'persona-row';

    const seatLabel = document.createElement('span');
    seatLabel.className = 'persona-seat';
    seatLabel.textContent = `Seat ${seat}`;

    const select = document.createElement('select');
    select.name = `playerPersonaSeat${seat}`;
    select.dataset.seat = String(seat);

    const emptyOption = document.createElement('option');
    emptyOption.value = '';
    emptyOption.textContent = '(none)';
    select.appendChild(emptyOption);

    availablePersonas.forEach((persona) => {
      const option = document.createElement('option');
      option.value = persona;
      option.textContent = persona;
      select.appendChild(option);
    });

    const hasCached = personaSelectionBySeat.has(seat);
    let selected = hasCached ? personaSelectionBySeat.get(seat) : defaultPersonaForSeat(seat);

    if (selected && !availablePersonas.includes(selected)) {
      selected = hasCached ? '' : defaultPersonaForSeat(seat);
      if (selected && !availablePersonas.includes(selected)) selected = '';
    }

    select.value = selected || '';
    personaSelectionBySeat.set(seat, select.value);

    select.addEventListener('change', () => {
      personaSelectionBySeat.set(seat, String(select.value || '').trim());
    });

    row.appendChild(seatLabel);
    row.appendChild(select);
    personaGrid.appendChild(row);
  }
}

function capturePersonaSelections() {
  if (!personaGrid) return;

  personaGrid.querySelectorAll('select[data-seat]').forEach((select) => {
    const seat = toInt(select.dataset.seat, 0);
    if (seat > 0) {
      personaSelectionBySeat.set(seat, String(select.value || '').trim());
    }
  });
}

function readPlayerPersonas(playerCount) {
  capturePersonaSelections();

  const personas = [];
  for (let seat = 1; seat <= playerCount; seat++) {
    const selected = personaSelectionBySeat.has(seat)
      ? personaSelectionBySeat.get(seat)
      : defaultPersonaForSeat(seat);

    personas.push(selected && availablePersonas.includes(selected) ? selected : null);
  }

  return personas;
}

function defaultPersonaForSeat(seat) {
  if (availablePersonas.length === 0) return '';
  return availablePersonas[(seat - 1) % availablePersonas.length];
}

function syncModelControls() {
  if (!modelGrid || !playersInput) return;

  captureModelSelections();
  ensureModelSuggestionList();

  const playerCount = clamp(toInt(playersInput.value, 6), PLAYER_MIN, PLAYER_MAX);
  modelGrid.innerHTML = '';

  for (let seat = 1; seat <= playerCount; seat++) {
    const row = document.createElement('div');
    row.className = 'persona-row';

    const seatLabel = document.createElement('span');
    seatLabel.className = 'persona-seat';
    seatLabel.textContent = `Seat ${seat}`;

    const input = document.createElement('input');
    input.type = 'text';
    input.name = `playerModelSeat${seat}`;
    input.dataset.seat = String(seat);
    input.placeholder = '(inherit global model)';
    input.setAttribute('list', MODEL_SUGGESTIONS_DATALIST_ID);

    const selected = modelSelectionBySeat.has(seat) ? modelSelectionBySeat.get(seat) : '';
    input.value = selected || '';
    modelSelectionBySeat.set(seat, input.value);

    input.addEventListener('input', () => {
      modelSelectionBySeat.set(seat, String(input.value || '').trim());
    });

    row.appendChild(seatLabel);
    row.appendChild(input);
    modelGrid.appendChild(row);
  }
}

function ensureModelSuggestionList() {
  if (document.getElementById(MODEL_SUGGESTIONS_DATALIST_ID)) return;

  const datalist = document.createElement('datalist');
  datalist.id = MODEL_SUGGESTIONS_DATALIST_ID;

  MODEL_SUGGESTIONS.forEach((model) => {
    const option = document.createElement('option');
    option.value = model;
    datalist.appendChild(option);
  });

  document.body.appendChild(datalist);
}

function captureModelSelections() {
  if (!modelGrid) return;

  modelGrid.querySelectorAll('input[data-seat]').forEach((input) => {
    const seat = toInt(input.dataset.seat, 0);
    if (seat > 0) {
      modelSelectionBySeat.set(seat, String(input.value || '').trim());
    }
  });
}

function readPlayerModels(playerCount) {
  captureModelSelections();

  const models = [];
  for (let seat = 1; seat <= playerCount; seat++) {
    const selected = modelSelectionBySeat.has(seat) ? modelSelectionBySeat.get(seat) : '';
    const trimmed = String(selected || '').trim();
    models.push(trimmed === '' ? null : trimmed);
  }

  return models;
}

/* ── State ── */
async function refreshState() {
  const res = await fetch('/api/state', { headers: { Accept: 'application/json' } });
  applySnapshot(await res.json());
}

function connectWebSocket() {
  const scheme = location.protocol === 'https:' ? 'wss' : 'ws';
  const ws = new WebSocket(`${scheme}://${location.host}/ws`);

  ws.addEventListener('open', () => { state.wsConnected = true; render(); });
  ws.addEventListener('close', () => {
    state.wsConnected = false; render();
    setTimeout(connectWebSocket, 1500);
  });

  ws.addEventListener('message', (e) => {
    let frame;
    try { frame = JSON.parse(e.data); } catch { return; }
    if (frame.type === 'snapshot') return applySnapshot(frame.payload);
    if (frame.type === 'event') return applyEvent(frame.payload);
  });
}

function applySnapshot(snap) {
  state.status = snap.status || 'idle';
  state.config = snap.config || null;
  state.table = snap.table || null;
  state.seats = snap.seats || [];
  state.hand_index = snap.hand_index || 0;
  state.events = Array.isArray(snap.events) ? snap.events : [];
  state.started_at = snap.started_at || null;
  state.finished_at = snap.finished_at || null;
  // Force full feed rebuild on snapshot
  feedSnapshotGeneration++;
  feedActionRendered = 0;
  feedTalkRendered = 0;
  render();
}

function applyEvent(ev) {
  state.events.push(ev);
  if (state.events.length > 400) {
    state.events = state.events.slice(-400);
    feedActionRendered = 0;
    feedTalkRendered = 0;
  }
  if (ev.table) state.table = ev.table;
  if (ev.seats) state.seats = ev.seats;
  if (ev.hand_index !== undefined) state.hand_index = ev.hand_index;
  if (ev.status) state.status = String(ev.status);

  if (['match_completed', 'match_stopped', 'match_error'].includes(ev.type)) {
    state.finished_at = ev.ts || state.finished_at;
  }

  if (ev.type === 'hand_finished') showWinnerToast(ev);

  render();
}

/* ── Render (differential) ── */
function render() {
  renderStatus();
  renderTable();
  renderScoreboard();
  renderFeeds();
}

/* Status — only touch DOM when values change */
function renderStatus() {
  const s = state.status;
  const newStatusText = s;
  const newStatusClass = 'pill' +
    (s === 'running' ? ' live' : '') +
    (s === 'paused' ? ' warn' : '') +
    (s === 'error' ? ' error' : '');

  if (newStatusText !== lastStatusText) {
    statusPill.textContent = newStatusText;
    lastStatusText = newStatusText;
  }
  if (newStatusClass !== lastStatusClass) {
    statusPill.className = newStatusClass;
    lastStatusClass = newStatusClass;
  }

  const wsText = state.wsConnected ? '● WS' : '○ WS';
  const wsClass = 'pill' + (state.wsConnected ? ' live' : '');
  if (wsText !== lastWsText) { wsPill.textContent = wsText; lastWsText = wsText; }
  if (wsClass !== lastWsClass) { wsPill.className = wsClass; lastWsClass = wsClass; }

  let info = '';
  if (state.table) {
    const t = state.table;
    info = `Hand ${state.hand_index} · ${t.small_blind}/${t.big_blind} blinds`;
  } else if (state.config) {
    info = `${state.config.players}p · ${state.config.hands} hands · ${state.config.stack} stack`;
  }
  if (info !== lastMatchInfo) {
    matchInfo.textContent = info;
    lastMatchInfo = info;
  }
}

/* Table — differential board, pot, seats */
function renderTable() {
  const hasTable = !!state.table;

  const shouldShowIdle = (state.status === 'idle' && !hasTable);
  if (shouldShowIdle !== lastIdleVisible) {
    idleOverlay.style.display = shouldShowIdle ? '' : 'none';
    lastIdleVisible = shouldShowIdle;
  }

  if (!hasTable) {
    if (lastBoardKey !== '') {
      boardCards.innerHTML = '';
      lastBoardKey = '';
    }
    if (lastBoardLabel !== '') {
      boardLabel.textContent = '';
      lastBoardLabel = '';
    }
    if (lastPotVisible) {
      potDisplay.style.display = 'none';
      lastPotVisible = false;
    }
    if (lastHandBadge !== '__hidden__') {
      handBadge.style.display = 'none';
      lastHandBadge = '__hidden__';
    }
    clearSeats();
    return;
  }

  const table = state.table;
  const hand = table.hand;

  // hand badge
  const badgeText = `Hand #${state.hand_index}${hand ? ' · ' + (hand.street || 'preflop') : ''}`;
  if (badgeText !== lastHandBadge) {
    handBadge.style.display = '';
    handBadge.textContent = badgeText;
    lastHandBadge = badgeText;
  }

  // pot — only update when amount changes
  const pot = hand ? hand.pot : 0;
  const potVisible = pot > 0;
  if (potVisible !== lastPotVisible) {
    potDisplay.style.display = potVisible ? '' : 'none';
    lastPotVisible = potVisible;
  }
  if (pot !== lastPotAmount && potVisible) {
    potAmount.textContent = formatChips(pot);
    if (potChips) potChips.innerHTML = renderChipStack(pot, 'pot');
    lastPotAmount = pot;
    // Feature 6: Ambient pot glow
    updatePotGlow(pot);
  }

  // Side pots from last hand result
  renderSidePots(table);

  // board cards — only rebuild when card keys change
  const board = hand?.board || [];
  const boardKey = board.join(',');
  if (boardKey !== lastBoardKey) {
    const prevBoard = lastBoardKey ? lastBoardKey.split(',') : [];
    if (board.length > 0) {
      // Feature 5: Card flip for newly added cards
      boardCards.innerHTML = board.map((c, idx) => {
        const isNewCard = idx >= prevBoard.length;
        return renderCard(c, false, isNewCard ? 'flip' : false);
      }).join('');
      boardLabel.textContent = '';
    } else {
      boardCards.innerHTML = '';
      boardLabel.textContent = hand ? 'PREFLOP' : '';
    }
    lastBoardKey = boardKey;
    lastBoardLabel = boardLabel.textContent;
  }

  // seats — differential
  renderSeats(table, hand);

  // Feature 2: Thinking timer
  updateActingTimer(hand);
}

/* ── Seats – stable DOM, differential updates ── */
const SEAT_POSITIONS = {
  2: [
    { x: 50, y: 100 },
    { x: 50, y: 0 }
  ],
  3: [
    { x: 50, y: 100 },
    { x: 95, y: 25 },
    { x: 5, y: 25 }
  ],
  4: [
    { x: 50, y: 100 },
    { x: 95, y: 50 },
    { x: 50, y: 0 },
    { x: 5, y: 50 }
  ],
  5: [
    { x: 50, y: 100 },
    { x: 90, y: 80 },
    { x: 90, y: 15 },
    { x: 10, y: 15 },
    { x: 10, y: 80 }
  ],
  6: [
    { x: 50, y: 102 },
    { x: 92, y: 78 },
    { x: 92, y: 18 },
    { x: 50, y: -2 },
    { x: 8, y: 18 },
    { x: 8, y: 78 }
  ],
  7: [
    { x: 50, y: 102 },
    { x: 85, y: 90 },
    { x: 97, y: 40 },
    { x: 72, y: -2 },
    { x: 28, y: -2 },
    { x: 3, y: 40 },
    { x: 15, y: 90 }
  ],
  8: [
    { x: 50, y: 102 },
    { x: 82, y: 92 },
    { x: 97, y: 55 },
    { x: 87, y: 5 },
    { x: 50, y: -2 },
    { x: 13, y: 5 },
    { x: 3, y: 55 },
    { x: 18, y: 92 }
  ],
  9: [
    { x: 50, y: 102 },
    { x: 80, y: 95 },
    { x: 97, y: 65 },
    { x: 95, y: 22 },
    { x: 68, y: -2 },
    { x: 32, y: -2 },
    { x: 5, y: 22 },
    { x: 3, y: 65 },
    { x: 20, y: 95 }
  ]
};

const seatPositionCache = new Map();

function getClockwiseSeatPositions(count) {
  if (seatPositionCache.has(count)) return seatPositionCache.get(count);

  const base = SEAT_POSITIONS[count] || SEAT_POSITIONS[6] || [];

  // Keep seat 1 anchored at bottom-center, then place remaining seats clockwise.
  const positions =
    base.length <= 1
      ? base
      : [base[0], ...base.slice(1).reverse()];

  seatPositionCache.set(count, positions);
  return positions;
}

function clearSeats() {
  seatEls.forEach(el => el.remove());
  seatEls = [];
  seatData = [];
}

/**
 * Build a seat DOM element with stable child references.
 * Returns { el, refs } where refs point to child nodes we'll update.
 */
function createSeatElement(index) {
  const el = document.createElement('div');
  el.className = 'seat';

  const chip = document.createElement('div');
  chip.className = 'seat-chip';

  const canvas = document.createElement('canvas');
  canvas.width = 64;
  canvas.height = 64;
  canvas.className = `seat-robot-canvas c${index % 9}`;

  const name = document.createElement('div');
  name.className = 'seat-name';

  const stackRow = document.createElement('div');
  stackRow.className = 'seat-stack-row';

  const stackIcon = document.createElement('span');
  stackIcon.className = 'stack-chip-icon';

  const stackText = document.createElement('span');
  stackText.className = 'seat-stack';

  stackRow.appendChild(stackIcon);
  stackRow.appendChild(stackText);

  const status = document.createElement('div');
  status.className = 'seat-status';

  chip.appendChild(canvas);
  chip.appendChild(name);
  chip.appendChild(stackRow);
  chip.appendChild(status);

  const cards = document.createElement('div');
  cards.className = 'seat-cards';

  const bet = document.createElement('div');
  bet.className = 'seat-bet';
  bet.style.display = 'none';

  el.appendChild(chip);
  el.appendChild(cards);
  el.appendChild(bet);

  return {
    el,
    refs: { chip, canvas, name, stackText, status, cards, bet }
  };
}

function renderSeats(table, hand) {
  const tableSeats = table.seats || [];
  const n = tableSeats.length;
  const positions = getClockwiseSeatPositions(n);

  const handPlayers = new Map();
  (hand?.players || []).forEach(p => handPlayers.set(p.seat, p));

  // Ensure we have exactly n seat elements (only create/remove when count changes)
  if (seatEls.length !== n) {
    clearSeats();
    for (let i = 0; i < n; i++) {
      const { el, refs } = createSeatElement(i);
      pokerTable.appendChild(el);
      seatEls.push({ el, refs });
      seatData.push({});
    }
  }

  tableSeats.forEach((seat, i) => {
    const { el, refs } = seatEls[i];
    const prev = seatData[i];
    const pos = positions[i] || { x: 50, y: 50 };
    const player = handPlayers.get(seat.seat);
    const cards = player?.hole_cards || [];
    const pStatus = player ? describePlayerState(player) : String(seat.status || 'active');
    const acting = hand?.acting_seat === seat.seat;
    const isFolded = player?.folded;
    const isButton = table.button_seat === seat.seat;
    const committed = player?.committed_round || 0;
    const label = shortLabel(seat.player_id, i);

    // Position — only set if changed
    if (prev.x !== pos.x) { el.style.left = pos.x + '%'; prev.x = pos.x; }
    if (prev.y !== pos.y) { el.style.top = pos.y + '%'; prev.y = pos.y; }

    // Class — only set if changed
    const cls = 'seat' + (acting ? ' acting' : '') + (isFolded ? ' folded' : '');
    if (prev.cls !== cls) { el.className = cls; prev.cls = cls; }

    // Robot avatar — draw state tracked by animation loop
    // Store acting/folded state on canvas for the animation loop
    refs.canvas._robotIndex = i;
    refs.canvas._robotActing = acting;
    refs.canvas._robotFolded = isFolded;

    // Name
    const nameText = label + (isButton ? ' 🔘' : '');
    if (prev.nameText !== nameText) {
      refs.name.textContent = nameText;
      prev.nameText = nameText;
    }

    // Stack
    const stackStr = formatChips(seat.stack);
    if (prev.stackStr !== stackStr) {
      refs.stackText.textContent = stackStr;
      prev.stackStr = stackStr;
    }

    // Status
    if (prev.pStatus !== pStatus) {
      refs.status.textContent = pStatus;
      refs.status.className = 'seat-status ' + pStatus;
      prev.pStatus = pStatus;
    }

    // Cards — only rebuild if card composition changes
    const cardKey = cards.join(',') + (hand ? ':hand' : ':nohand');
    if (prev.cardKey !== cardKey) {
      if (cards.length > 0) {
        refs.cards.innerHTML = cards.map(c => renderCard(c, true, true)).join('');
      } else if (hand) {
        refs.cards.innerHTML = '<div class="card-back card-sm"></div><div class="card-back card-sm"></div>';
      } else {
        refs.cards.innerHTML = '';
      }
      prev.cardKey = cardKey;
    }

    // Bet
    if (prev.committed !== committed) {
      if (committed > 0) {
        refs.bet.style.display = '';
        refs.bet.innerHTML = `<span class="bet-chip-icon"></span>${formatChips(committed)}`;
      } else {
        refs.bet.style.display = 'none';
      }
      prev.committed = committed;
    }
  });
}

function shortLabel(playerId, index) {
  if (!playerId) return `P${index + 1}`;
  const s = String(playerId);
  if (s.length > 12) return s.slice(0, 8) + '…';
  return s;
}

/* ── Card Rendering ── */
function renderCard(cardStr, small, animStyle) {
  if (!cardStr || cardStr.length < 2) return `<div class="card${small ? ' card-sm' : ''} black"><span class="rank">?</span><span class="suit">?</span></div>`;

  const rankChar = cardStr[0];
  const suitChar = cardStr[1].toLowerCase();
  const rank = RANK_DISPLAY[rankChar] || rankChar;
  const suit = SUIT_MAP[suitChar] || suitChar;
  const color = SUIT_COLOR[suitChar] || 'black';
  // Feature 5: 'flip' uses card-flip, true uses card-new, false = no animation
  const animCls = animStyle === 'flip' ? ' card-flip' : (animStyle ? ' card-new' : '');

  return `<div class="card${small ? ' card-sm' : ''} ${color}${animCls}"><span class="rank">${rank}</span><span class="suit">${suit}</span></div>`;
}

/* ── Chip Stack Rendering ── */
function renderChipStack(amount, context) {
  if (!amount || amount <= 0) return '';
  const chips = chipBreakdown(amount);
  const maxShow = context === 'pot' ? 6 : 4;
  const shown = chips.slice(0, maxShow);
  return `<span class="chip-stack chip-stack-${context}">${shown.map((c, i) =>
    `<span class="chip-disc chip-${c.color}" style="--i:${i}"></span>`
  ).join('')}</span>`;
}

function chipBreakdown(amount) {
  const denominations = [
    { value: 1000, color: 'gold' },
    { value: 500, color: 'black' },
    { value: 100, color: 'blue' },
    { value: 25, color: 'green' },
    { value: 5, color: 'red' },
    { value: 1, color: 'white' }
  ];
  const chips = [];
  let remaining = amount;
  for (const denom of denominations) {
    const count = Math.floor(remaining / denom.value);
    for (let j = 0; j < Math.min(count, 3); j++) {
      chips.push(denom);
    }
    remaining -= count * denom.value;
    if (chips.length >= 8) break;
  }
  if (chips.length === 0) chips.push(denominations[denominations.length - 1]);
  return chips;
}

/* ── Feeds — incremental append ── */
const ACTION_TYPES = new Set([
  'match_started', 'match_paused', 'match_resumed', 'match_stopping',
  'match_stopped', 'match_completed', 'match_error',
  'hand_started', 'street_changed', 'action_taken',
  'table_talk_blocked', 'hand_finished'
]);

let lastFeedGen = 0;

function renderFeeds() {
  const isNewSnapshot = feedSnapshotGeneration !== lastFeedGen;

  if (isNewSnapshot) {
    // Full rebuild on snapshot
    actionFeed.innerHTML = '';
    talkFeed.innerHTML = '';
    feedActionRendered = 0;
    feedTalkRendered = 0;
    lastFeedGen = feedSnapshotGeneration;
  }

  const events = state.events;
  let actionAdded = 0;
  let talkAdded = 0;

  // We scan from 0 but only render items beyond our rendered indices
  let actionIdx = 0;
  let talkIdx = 0;

  for (let i = 0; i < events.length; i++) {
    const ev = events[i];
    if (ACTION_TYPES.has(ev.type)) {
      actionIdx++;
      if (actionIdx > feedActionRendered) {
        appendFeedItem(actionFeed, renderActionItem(ev));
        actionAdded++;
      }
    }
    if (ev.type === 'table_talk') {
      talkIdx++;
      if (talkIdx > feedTalkRendered) {
        appendTalkItem(talkFeed, renderTalkItem(ev));
        talkAdded++;
      }
    }
  }

  feedActionRendered = actionIdx;
  feedTalkRendered = talkIdx;

  // Trim old DOM nodes if feeds get too long
  trimFeed(actionFeed, 150);
  trimFeed(talkFeed, 80);

  // Update counts
  const actionTotal = actionIdx;
  const talkTotal = talkIdx;
  if (actionCount.textContent !== String(actionTotal)) actionCount.textContent = actionTotal;
  if (talkCount.textContent !== String(talkTotal)) talkCount.textContent = talkTotal;

  // Auto-scroll only if new items added
  if (actionAdded > 0) actionFeed.scrollTop = actionFeed.scrollHeight;
  if (talkAdded > 0) talkFeed.scrollTop = talkFeed.scrollHeight;
}

function appendFeedItem(container, html) {
  const div = document.createElement('div');
  div.innerHTML = html;
  while (div.firstElementChild) {
    container.appendChild(div.firstElementChild);
  }
}

function appendTalkItem(container, html) {
  const div = document.createElement('div');
  div.innerHTML = html;
  const el = div.firstElementChild;
  if (el) container.appendChild(el);
}

function trimFeed(container, max) {
  while (container.children.length > max) {
    container.removeChild(container.firstChild);
  }
}

const ACTION_ICONS = {
  fold: '🔴', call: '🔵', check: '⚫', raise: '🟢', bet: '🟢',
  all_in: '🟡', 'all-in': '🟡', allin: '🟡',
  post_blind: '📥', post_sb: '📥', post_bb: '📥', ante: '📥',
};

const ACTION_PILL_CLASS = {
  fold: 'fold', call: 'call', check: 'check', raise: 'raise', bet: 'raise',
  all_in: 'allin', 'all-in': 'allin', allin: 'allin',
  post_blind: 'blind', post_sb: 'blind', post_bb: 'blind', ante: 'blind',
};

function feedTimestamp(ev) {
  if (!ev.ts) return '';
  const t = new Date(ev.ts).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
  return `<span class="feed-ts">${esc(t)}</span>`;
}

function renderActionItem(ev) {
  const ts = feedTimestamp(ev);

  /* ── Hand started → divider ── */
  if (ev.type === 'hand_started') {
    const blinds = `BTN ${ev.button_seat} · SB ${ev.small_blind_seat} · BB ${ev.big_blind_seat}`;
    return `<div class="feed-hand-start">
      <span class="feed-hand-line"></span>
      <span class="feed-hand-label">Hand #${ev.hand_index}</span>
      <span class="feed-hand-line"></span>
      ${ts}
    </div>
    <div class="feed-hand-blinds">${esc(blinds)}</div>`;
  }

  /* ── Street changed → centered badge ── */
  if (ev.type === 'street_changed') {
    const boardHtml = (ev.board || []).map(c => renderCard(c, true, false)).join('');
    const streetName = String(ev.street || 'unknown').toUpperCase();
    return `<div class="feed-street">
      <span class="feed-street-pill">${esc(streetName)}</span>
      <span class="feed-street-cards">${boardHtml}</span>
      ${ts}
    </div>`;
  }

  /* ── Action taken → structured row ── */
  if (ev.type === 'action_taken') {
    const actor = ev.actor || `Seat ${ev.seat}`;
    const actionRaw = String(ev.action || 'unknown').toLowerCase().trim();
    // Parse action: might be "raise 400" or "call" etc.
    const parts = actionRaw.split(/\s+/);
    const actionVerb = parts[0];
    const actionAmount = parts.length > 1 ? parts.slice(1).join(' ') : '';
    const icon = ACTION_ICONS[actionVerb] || '▪️';
    const pillCls = ACTION_PILL_CLASS[actionVerb] || 'default';
    const fb = ev.source === 'fallback' ? '<span class="feed-fallback">FB</span>' : '';
    const amountHtml = actionAmount ? `<span class="feed-action-amount">${esc(actionAmount)}</span>` : '';

    return `<div class="feed-action">
      <span class="feed-action-icon">${icon}</span>
      <span class="feed-action-actor">${esc(actor)}</span>
      <span class="action-pill ${pillCls}">${esc(actionVerb.toUpperCase())}</span>
      ${amountHtml}
      ${fb}
      ${ts}
    </div>`;
  }

  /* ── Hand finished → result card ── */
  if (ev.type === 'hand_finished') {
    const winners = ev.result?.winners || [];
    const winnersHtml = winners.map(w =>
      `<span class="feed-winner">🏆 Seat ${w.seat} <span class="feed-winner-amount">+${formatChips(w.amount)}</span></span>`
    ).join('');
    return `<div class="feed-result">
      <div class="feed-result-header">
        <span class="feed-result-label">Hand #${ev.hand_index} Result</span>
        ${ts}
      </div>
      <div class="feed-result-winners">${winnersHtml || '<span class="feed-no-winner">No winner</span>'}</div>
    </div>`;
  }

  /* ── Match-level banners ── */
  if (ev.type === 'match_started') {
    const personas = formatSeatPersonaSummary(ev.seats);
    const models = formatSeatModelSummary(ev.seats);
    const detail = [personas ? `personas: ${personas}` : '', models ? `models: ${models}` : ''].filter(Boolean).join(' · ');
    return `<div class="feed-banner feed-banner-start">
      <span class="feed-banner-icon">🚀</span>
      <span class="feed-banner-text">Match Started</span>
      ${detail ? `<span class="feed-banner-detail">${esc(detail)}</span>` : ''}
      ${ts}
    </div>`;
  }

  if (ev.type === 'match_completed') {
    return `<div class="feed-banner feed-banner-complete">
      <span class="feed-banner-icon">🏁</span>
      <span class="feed-banner-text">Match Complete</span>
      ${ts}
    </div>`;
  }

  if (ev.type === 'match_stopped') {
    return `<div class="feed-banner feed-banner-stop">
      <span class="feed-banner-icon">⏹️</span>
      <span class="feed-banner-text">Match Stopped</span>
      ${ev.reason ? `<span class="feed-banner-detail">${esc(ev.reason)}</span>` : ''}
      ${ts}
    </div>`;
  }

  if (ev.type === 'match_error') {
    return `<div class="feed-banner feed-banner-error">
      <span class="feed-banner-icon">⚠️</span>
      <span class="feed-banner-text">Match Error</span>
      ${ev.reason ? `<span class="feed-banner-detail">${esc(ev.reason)}</span>` : ''}
      ${ts}
    </div>`;
  }

  if (ev.type === 'match_paused') {
    return `<div class="feed-banner feed-banner-pause">
      <span class="feed-banner-icon">⏸️</span>
      <span class="feed-banner-text">Paused</span>
      ${ts}
    </div>`;
  }

  if (ev.type === 'match_resumed') {
    return `<div class="feed-banner feed-banner-resume">
      <span class="feed-banner-icon">▶️</span>
      <span class="feed-banner-text">Resumed</span>
      ${ts}
    </div>`;
  }

  if (ev.type === 'match_stopping') {
    return `<div class="feed-banner feed-banner-stop">
      <span class="feed-banner-icon">⏳</span>
      <span class="feed-banner-text">Stopping…</span>
      ${ts}
    </div>`;
  }

  if (ev.type === 'table_talk_blocked') {
    const actor = ev.actor || `Seat ${ev.seat}`;
    return `<div class="feed-muted">
      <span class="feed-action-icon">🔇</span>
      <span>${esc(actor)} talk blocked (${esc(ev.reason || 'policy')})</span>
      ${ts}
    </div>`;
  }

  /* ── Fallback ── */
  const time = ev.ts ? new Date(ev.ts).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' }) : '';
  return `<div class="feed-item event-${ev.type}"><span class="ts">${esc(time)}</span><span>${esc(ev.type)}</span></div>`;
}

function renderTalkItem(ev) {
  const time = ev.ts ? new Date(ev.ts).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' }) : '';
  const actor = ev.actor || `seat ${ev.seat}`;
  return `<div class="talk-item"><span class="ts">${esc(time)}</span><span class="actor">${esc(actor)}:</span><span class="text">${esc(ev.text || '')}</span></div>`;
}

function formatSeatPersonaSummary(seats) {
  if (!Array.isArray(seats) || seats.length === 0) return '';

  return seats
    .slice()
    .sort((a, b) => (a.seat || 0) - (b.seat || 0))
    .map((seat) => {
      const persona = String(seat?.persona || 'default').trim() || 'default';
      return `S${seat?.seat ?? '?'}=${persona}`;
    })
    .join(', ');
}

function formatSeatModelSummary(seats) {
  if (!Array.isArray(seats) || seats.length === 0) return '';

  return seats
    .slice()
    .sort((a, b) => (a.seat || 0) - (b.seat || 0))
    .map((seat) => {
      const model = String(seat?.model || '').trim() || 'default';
      return `S${seat?.seat ?? '?'}=${model}`;
    })
    .join(', ');
}

/* ── Winner Toast + Showdown Overlay ── */
function showWinnerToast(ev) {
  const winners = ev.result?.winners || [];
  if (winners.length === 0) return;

  const showdown = ev.result?.showdown || [];
  const board = ev.result?.board || [];

  // Feature 1: Full showdown overlay if we have showdown data
  if (showdown.length > 0 && board.length > 0) {
    showShowdownOverlay(ev, board, showdown, winners);
  } else {
    // Fallback to simple toast
    const msg = winners.map(w => `Seat ${w.seat} wins ${formatChips(w.amount)}`).join('  ·  ');
    winnerToast.textContent = `🏆 ${msg}`;
    winnerToast.classList.add('show');
    clearTimeout(toastTimeout);
    toastTimeout = setTimeout(() => winnerToast.classList.remove('show'), 4000);
  }
}

/* ── Showdown Overlay ── */
function showShowdownOverlay(ev, board, showdown, winners) {
  const winnerSeats = new Set(winners.map(w => w.seat));
  const winnerAmounts = new Map(winners.map(w => [w.seat, w.amount]));

  // Render board cards (large)
  showdownBoard.innerHTML = board.map(c => renderCard(c, false, false)).join('');

  // Sort showdown: winners first, then by seat
  const sorted = [...showdown].sort((a, b) => {
    const aWin = winnerSeats.has(a.seat) ? 0 : 1;
    const bWin = winnerSeats.has(b.seat) ? 0 : 1;
    if (aWin !== bWin) return aWin - bWin;
    return a.seat - b.seat;
  });

  // Find player labels from current state seats
  const seatLabels = new Map();
  (state.table?.seats || state.seats || []).forEach((s, i) => {
    seatLabels.set(s.seat, { label: shortLabel(s.player_id, i), index: i });
  });

  // Try to get hole cards from showdown entries first (new backend field),
  // then fall back to hand.players (legacy approach).
  const holecardMap = new Map();
  showdown.forEach(entry => {
    if (entry.hole_cards && entry.hole_cards.length > 0) {
      holecardMap.set(entry.seat, entry.hole_cards);
    }
  });
  // Legacy fallback: try hand players if showdown didn't have hole_cards
  if (holecardMap.size === 0) {
    const handPlayers = ev.table?.hand?.players || state.table?.hand?.players || [];
    (Array.isArray(handPlayers) ? handPlayers : []).forEach(p => {
      if (p.hole_cards && p.hole_cards.length > 0) {
        holecardMap.set(p.seat, p.hole_cards);
      }
    });
  }

  // Find the winning hand category for the title
  const winnerEntry = sorted.find(e => winnerSeats.has(e.seat));
  const winningHandName = winnerEntry ? formatCategory(winnerEntry.category) : '';

  showdownHands.innerHTML = sorted.map((entry, idx) => {
    const isWinner = winnerSeats.has(entry.seat);
    const info = seatLabels.get(entry.seat) || { label: `Seat ${entry.seat}`, index: entry.seat - 1 };
    const cards = holecardMap.get(entry.seat) || [];
    const amount = winnerAmounts.get(entry.seat);
    const category = formatCategory(entry.category);

    return `<div class="showdown-hand${isWinner ? ' winner' : ''}" style="animation-delay: ${idx * 0.1}s">
      <div class="showdown-hand-rank">${isWinner ? '🏆' : '#' + (idx + 1)}</div>
      <div class="showdown-hand-avatar c${info.index % 9}">${info.label.charAt(0).toUpperCase()}</div>
      <div class="showdown-hand-name">${esc(info.label)}</div>
      <div class="showdown-hand-cards">${cards.length > 0 ? cards.map(c => renderCard(c, false, false)).join('') : '<div class="card-back card-sm"></div><div class="card-back card-sm"></div>'}</div>
      <div class="showdown-hand-category">${esc(category)}</div>
      ${isWinner && amount ? `<div class="showdown-hand-winnings">+${formatChips(amount)}</div>` : ''}
    </div>`;
  }).join('');

  // Update the title to show the winning hand
  const titleEl = showdownOverlay.querySelector('.showdown-title');
  if (titleEl) {
    titleEl.innerHTML = winningHandName
      ? `Showdown <span class="showdown-winning-hand">${esc(winningHandName)}</span>`
      : 'Showdown';
  }

  showdownOverlay.classList.add('show');

  clearTimeout(toastTimeout);
  toastTimeout = setTimeout(() => {
    showdownOverlay.classList.remove('show');
  }, 8000);

  // Also allow click to dismiss
  showdownOverlay.onclick = () => {
    showdownOverlay.classList.remove('show');
    clearTimeout(toastTimeout);
  };
}

const HAND_CATEGORY_NAMES = {
  'high_card': 'High Card',
  'high card': 'High Card',
  'one_pair': 'Pair',
  'one pair': 'Pair',
  'pair': 'Pair',
  'two_pair': 'Two Pair',
  'two pair': 'Two Pair',
  'three_of_a_kind': 'Three of a Kind',
  'three of a kind': 'Three of a Kind',
  'trips': 'Three of a Kind',
  'straight': 'Straight',
  'flush': 'Flush',
  'full_house': 'Full House',
  'full house': 'Full House',
  'four_of_a_kind': 'Four of a Kind',
  'four of a kind': 'Four of a Kind',
  'quads': 'Four of a Kind',
  'straight_flush': 'Straight Flush',
  'straight flush': 'Straight Flush',
  'royal_flush': 'Royal Flush',
  'royal flush': 'Royal Flush',
};

const HAND_CATEGORY_ICONS = {
  'High Card': '🃏',
  'Pair': '✌️',
  'Two Pair': '✌️✌️',
  'Three of a Kind': '🎯',
  'Straight': '📏',
  'Flush': '♠️',
  'Full House': '🏠',
  'Four of a Kind': '💎',
  'Straight Flush': '🔥',
  'Royal Flush': '👑',
};

function formatCategory(cat) {
  if (!cat) return '';
  const key = String(cat).toLowerCase().trim();
  const name = HAND_CATEGORY_NAMES[key];
  if (name) {
    const icon = HAND_CATEGORY_ICONS[name] || '';
    return icon ? `${icon} ${name}` : name;
  }
  // Fallback: title-case the raw string
  return String(cat).replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
}

/* ── Thinking Timer ── */
function updateActingTimer(hand) {
  const newActingSeat = hand?.acting_seat ?? null;

  if (newActingSeat !== actingTimerSeat) {
    // Clear old timer
    clearActingTimer();

    if (newActingSeat !== null) {
      actingTimerSeat = newActingSeat;
      actingTimerStart = Date.now();

      // Find the seat element and add timer badge
      const seatIndex = findSeatIndex(newActingSeat);
      if (seatIndex !== -1 && seatEls[seatIndex]) {
        const timerEl = document.createElement('div');
        timerEl.className = 'seat-timer';
        timerEl.textContent = '0s';
        seatEls[seatIndex].refs.chip.appendChild(timerEl);
        actingTimerEl = timerEl;

        actingTimerInterval = setInterval(() => {
          const elapsed = Math.floor((Date.now() - actingTimerStart) / 1000);
          if (actingTimerEl) {
            actingTimerEl.textContent = `${elapsed}s`;
            // Change color based on time
            actingTimerEl.className = 'seat-timer' +
              (elapsed >= 30 ? ' very-slow' : elapsed >= 10 ? ' slow' : '');
          }
        }, 1000);
      }
    }
  }
}

function clearActingTimer() {
  if (actingTimerInterval) {
    clearInterval(actingTimerInterval);
    actingTimerInterval = null;
  }
  if (actingTimerEl) {
    actingTimerEl.remove();
    actingTimerEl = null;
  }
  actingTimerSeat = null;
  actingTimerStart = null;
}

function findSeatIndex(seat) {
  const tableSeats = state.table?.seats || [];
  return tableSeats.findIndex(s => s.seat === seat);
}

/* ── Scoreboard ── */
function renderScoreboard() {
  const hasTable = !!state.table;
  const shouldShow = hasTable && state.status !== 'idle';

  if (!shouldShow) {
    if (scoreboard.style.display !== 'none') {
      scoreboard.style.display = 'none';
      document.body.classList.remove('has-scoreboard');
    }
    lastScoreboardKey = '';
    return;
  }

  const seats = state.table.seats || [];
  const handIdx = state.hand_index || 0;
  const totalHands = state.config?.hands || '?';
  const key = seats.map(s => `${s.seat}:${s.stack}`).join('|') + `|h${handIdx}`;

  if (key === lastScoreboardKey) return;
  lastScoreboardKey = key;

  // Sort by stack desc
  const ranked = [...seats].sort((a, b) => b.stack - a.stack);
  const maxStack = ranked[0]?.stack || 0;

  let html = ranked.map((s, i) => {
    const label = shortLabel(s.player_id, seats.indexOf(s));
    const isLeader = i === 0 && s.stack > 0;
    const isEliminated = s.stack <= 0;
    const cls = isLeader ? 'chip-leader' : (isEliminated ? 'eliminated' : '');

    return `<div class="scoreboard-entry ${cls}">
      <span class="scoreboard-rank">${i + 1}</span>
      <span class="scoreboard-label">${esc(label)}</span>
      <span class="scoreboard-stack">${formatChips(s.stack)}</span>
    </div>`;
  }).join('');

  html += `<div class="scoreboard-progress">Hand ${handIdx}/${totalHands}</div>`;

  scoreboard.innerHTML = html;
  scoreboard.style.display = '';
  document.body.classList.add('has-scoreboard');
}

/* ── Side Pots ── */
function renderSidePots(table) {
  const pots = table?.last_hand_result?.pots || [];
  const key = pots.map(p => `${p.amount}:${(p.eligible_seats || []).join('-')}`).join('|');

  if (key === lastSidePotsKey) return;
  lastSidePotsKey = key;

  if (pots.length <= 1) {
    sidePotsEl.style.display = 'none';
    sidePotsEl.innerHTML = '';
    return;
  }

  sidePotsEl.innerHTML = pots.map((pot, i) => {
    const seats = (pot.eligible_seats || []).map(s =>
      `<span class="side-pot-seat">${s}</span>`
    ).join('');

    return `<div class="side-pot-bubble">
      <span class="side-pot-label">${i === 0 ? 'Main' : 'Side ' + i}</span>
      <span class="side-pot-amount">${formatChips(pot.amount)}</span>
      <span class="side-pot-seats">${seats}</span>
    </div>`;
  }).join('');

  sidePotsEl.style.display = '';
}

/* ── Pot Glow ── */
function updatePotGlow(pot) {
  // Map pot to a glow intensity: 0 at 0, max ~0.25 at ~5000+
  const intensity = Math.min(0.25, pot / 5000 * 0.25);
  pokerTable.style.setProperty('--pot-glow', intensity.toFixed(3));
}

/* ── Helpers ── */
function describePlayerState(p) {
  if (p.folded) return 'folded';
  if (p.all_in) return 'all-in';
  return 'active';
}

function formatChips(n) {
  if (n == null) return '0';
  return Number(n).toLocaleString();
}

function formatWinners(winners) {
  if (!Array.isArray(winners) || winners.length === 0) return 'no winners';
  return winners.map(w => `seat ${w.seat}: +${formatChips(w.amount)}`).join(', ');
}

async function postJson(path, payload) {
  const res = await fetch(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
    body: JSON.stringify(payload)
  });

  const json = await res.json();
  if (!res.ok || !json.ok) {
    const reason = json?.error || res.statusText;
    window.alert(`Request failed: ${reason}`);
    return null;
  }
  if (json.state) applySnapshot(json.state);
  return json;
}

function toInt(v, fb) { const n = parseInt(String(v ?? '').trim(), 10); return Number.isFinite(n) ? n : fb; }
function parseCsv(v) { const t = String(v || '').trim(); if (!t) return []; return t.split(',').map(s => s.trim()).filter(Boolean); }
function blankToNull(v) { const t = String(v || '').trim(); return t === '' ? null : t; }
function clamp(value, min, max) { return Math.min(max, Math.max(min, value)); }
function normalizePersonaNames(values) {
  const seen = new Set();
  return values
    .map((value) => String(value || '').trim())
    .filter((value) => value !== '' && !seen.has(value) && seen.add(value));
}
function esc(v) {
  return String(v)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

/* ══════════════════════════════════════════════════════
   ROBOT AVATAR DRAWING ENGINE
   ══════════════════════════════════════════════════════ */

const ROBOT_COLORS = [
  { body: '#6366f1', accent: '#818cf8', dark: '#4338ca', eye: '#c7d2fe' },  // indigo
  { body: '#ec4899', accent: '#f472b6', dark: '#be185d', eye: '#fce7f3' },  // pink
  { body: '#f59e0b', accent: '#fbbf24', dark: '#d97706', eye: '#fef3c7' },  // amber
  { body: '#14b8a6', accent: '#2dd4bf', dark: '#0d9488', eye: '#ccfbf1' },  // teal
  { body: '#8b5cf6', accent: '#a78bfa', dark: '#6d28d9', eye: '#ede9fe' },  // violet
  { body: '#f43f5e', accent: '#fb7185', dark: '#be123c', eye: '#ffe4e6' },  // rose
  { body: '#06b6d4', accent: '#22d3ee', dark: '#0891b2', eye: '#cffafe' },  // cyan
  { body: '#84cc16', accent: '#a3e635', dark: '#65a30d', eye: '#ecfccb' },  // lime
  { body: '#f97316', accent: '#fb923c', dark: '#ea580c', eye: '#ffedd5' },  // orange
];

// Robot design variations per index
const ROBOT_DESIGNS = [
  { head: 'round', antenna: 'ball', ears: true, mouth: 'smile', visor: false },
  { head: 'square', antenna: 'fork', ears: false, mouth: 'line', visor: true },
  { head: 'dome', antenna: 'zigzag', ears: true, mouth: 'dots', visor: false },
  { head: 'hex', antenna: 'ball', ears: false, mouth: 'smile', visor: true },
  { head: 'round', antenna: 'fork', ears: true, mouth: 'wave', visor: false },
  { head: 'square', antenna: 'zigzag', ears: true, mouth: 'line', visor: false },
  { head: 'dome', antenna: 'ball', ears: false, mouth: 'dots', visor: true },
  { head: 'hex', antenna: 'fork', ears: true, mouth: 'wave', visor: false },
  { head: 'round', antenna: 'zigzag', ears: false, mouth: 'smile', visor: true },
];

// Per-seat animation state
const robotAnimState = [];
for (let i = 0; i < 9; i++) {
  robotAnimState.push({
    blinkTimer: Math.random() * 3,
    isBlinking: false,
    blinkDuration: 0,
    antennaPhase: Math.random() * Math.PI * 2,
    floatPhase: Math.random() * Math.PI * 2,
  });
}

let robotAnimRunning = false;
let robotLastFrame = 0;
const ROBOT_FPS = 12;
const ROBOT_FRAME_MS = 1000 / ROBOT_FPS;

function startRobotAnimations() {
  if (robotAnimRunning) return;
  robotAnimRunning = true;
  robotLastFrame = performance.now();
  requestAnimationFrame(robotAnimLoop);
}

function robotAnimLoop(now) {
  if (!robotAnimRunning) return;
  requestAnimationFrame(robotAnimLoop);

  const dt = now - robotLastFrame;
  if (dt < ROBOT_FRAME_MS) return;
  robotLastFrame = now - (dt % ROBOT_FRAME_MS);

  const elapsed = dt / 1000;
  const time = now / 1000;

  // Update animation state
  for (let i = 0; i < robotAnimState.length; i++) {
    const s = robotAnimState[i];
    s.antennaPhase += elapsed * 2.5;
    s.floatPhase += elapsed * 1.8;

    if (s.isBlinking) {
      s.blinkDuration -= elapsed;
      if (s.blinkDuration <= 0) s.isBlinking = false;
    } else {
      s.blinkTimer -= elapsed;
      if (s.blinkTimer <= 0) {
        s.isBlinking = true;
        s.blinkDuration = 0.12 + Math.random() * 0.08;
        s.blinkTimer = 2 + Math.random() * 3;
      }
    }
  }

  // Draw all visible robot canvases
  for (const seat of seatEls) {
    const cvs = seat.refs.canvas;
    if (!cvs || !cvs.isConnected) continue;
    const idx = cvs._robotIndex ?? 0;
    drawRobot(cvs, idx, cvs._robotActing, cvs._robotFolded, time);
  }
}

function drawRobot(canvas, colorIndex, isActing, isFolded, time) {
  const ctx = canvas.getContext('2d');
  const W = 64, H = 64;
  ctx.clearRect(0, 0, W, H);

  if (isFolded) ctx.globalAlpha = 0.4;

  const ci = colorIndex % ROBOT_COLORS.length;
  const col = ROBOT_COLORS[ci];
  const design = ROBOT_DESIGNS[ci];
  const anim = robotAnimState[ci];

  const floatY = Math.sin(anim.floatPhase) * 1.5;
  const antennaOff = Math.sin(anim.antennaPhase) * 2;

  ctx.save();
  ctx.translate(0, floatY);

  // ── Antenna ──
  const ax = 32, ay = 10;
  ctx.strokeStyle = col.accent;
  ctx.lineWidth = 2;
  ctx.lineCap = 'round';

  if (design.antenna === 'ball') {
    ctx.beginPath();
    ctx.moveTo(ax, ay + 8);
    ctx.lineTo(ax + antennaOff, ay);
    ctx.stroke();
    ctx.fillStyle = col.accent;
    ctx.beginPath();
    ctx.arc(ax + antennaOff, ay - 2, 3, 0, Math.PI * 2);
    ctx.fill();
  } else if (design.antenna === 'fork') {
    ctx.beginPath();
    ctx.moveTo(ax, ay + 8);
    ctx.lineTo(ax, ay + 2);
    ctx.moveTo(ax - 3 + antennaOff * 0.5, ay - 1);
    ctx.lineTo(ax, ay + 2);
    ctx.lineTo(ax + 3 + antennaOff * 0.5, ay - 1);
    ctx.stroke();
  } else { // zigzag
    ctx.beginPath();
    ctx.moveTo(ax, ay + 8);
    ctx.lineTo(ax + 2 + antennaOff * 0.3, ay + 5);
    ctx.lineTo(ax - 2 + antennaOff * 0.6, ay + 2);
    ctx.lineTo(ax + antennaOff, ay - 1);
    ctx.stroke();
    // Spark at top
    if (isActing && Math.sin(time * 8) > 0.3) {
      ctx.fillStyle = '#fbbf24';
      ctx.beginPath();
      ctx.arc(ax + antennaOff, ay - 3, 2, 0, Math.PI * 2);
      ctx.fill();
    }
  }

  // ── Head ──
  const hx = 14, hy = 16, hw = 36, hh = 26;
  ctx.fillStyle = col.body;
  ctx.strokeStyle = col.dark;
  ctx.lineWidth = 1.5;

  if (design.head === 'round') {
    roundRect(ctx, hx, hy, hw, hh, 10);
  } else if (design.head === 'square') {
    roundRect(ctx, hx, hy, hw, hh, 4);
  } else if (design.head === 'dome') {
    ctx.beginPath();
    ctx.moveTo(hx, hy + hh);
    ctx.lineTo(hx, hy + 10);
    ctx.quadraticCurveTo(hx, hy, hx + hw / 2, hy);
    ctx.quadraticCurveTo(hx + hw, hy, hx + hw, hy + 10);
    ctx.lineTo(hx + hw, hy + hh);
    ctx.closePath();
    ctx.fill();
    ctx.stroke();
  } else { // hex
    const cx = hx + hw / 2, cy = hy + hh / 2;
    ctx.beginPath();
    for (let j = 0; j < 6; j++) {
      const a = Math.PI / 6 + j * Math.PI / 3;
      const rx = hw / 2, ry = hh / 2;
      const px = cx + Math.cos(a) * rx;
      const py = cy + Math.sin(a) * ry;
      j === 0 ? ctx.moveTo(px, py) : ctx.lineTo(px, py);
    }
    ctx.closePath();
    ctx.fill();
    ctx.stroke();
  }

  // ── Ears ──
  if (design.ears) {
    ctx.fillStyle = col.dark;
    // Left ear
    roundRect(ctx, hx - 5, hy + 8, 6, 10, 2);
    // Right ear
    roundRect(ctx, hx + hw - 1, hy + 8, 6, 10, 2);
  }

  // ── Visor ──
  if (design.visor) {
    ctx.fillStyle = 'rgba(0,0,0,0.25)';
    roundRect(ctx, hx + 5, hy + 6, hw - 10, 12, 5);
  }

  // ── Eyes ──
  const eyeY = hy + 13;
  const eyeL = 25, eyeR = 39;
  if (anim.isBlinking) {
    // Blink — just horizontal lines
    ctx.strokeStyle = col.eye;
    ctx.lineWidth = 2;
    ctx.beginPath();
    ctx.moveTo(eyeL - 3, eyeY);
    ctx.lineTo(eyeL + 3, eyeY);
    ctx.moveTo(eyeR - 3, eyeY);
    ctx.lineTo(eyeR + 3, eyeY);
    ctx.stroke();
  } else {
    ctx.fillStyle = col.eye;
    // Slightly different eye shapes per design
    if (ci % 3 === 0) {
      // Round eyes
      ctx.beginPath();
      ctx.arc(eyeL, eyeY, 3.5, 0, Math.PI * 2);
      ctx.fill();
      ctx.beginPath();
      ctx.arc(eyeR, eyeY, 3.5, 0, Math.PI * 2);
      ctx.fill();
    } else if (ci % 3 === 1) {
      // Square eyes
      ctx.fillRect(eyeL - 3, eyeY - 3, 6, 6);
      ctx.fillRect(eyeR - 3, eyeY - 3, 6, 6);
    } else {
      // Oval eyes
      ctx.beginPath();
      ctx.ellipse(eyeL, eyeY, 4, 3, 0, 0, Math.PI * 2);
      ctx.fill();
      ctx.beginPath();
      ctx.ellipse(eyeR, eyeY, 4, 3, 0, 0, Math.PI * 2);
      ctx.fill();
    }
    // Pupils
    ctx.fillStyle = col.dark;
    ctx.beginPath();
    ctx.arc(eyeL + 0.5, eyeY + 0.5, 1.5, 0, Math.PI * 2);
    ctx.fill();
    ctx.beginPath();
    ctx.arc(eyeR + 0.5, eyeY + 0.5, 1.5, 0, Math.PI * 2);
    ctx.fill();
  }

  // ── Mouth ──
  const my = hy + 21;
  ctx.strokeStyle = col.eye;
  ctx.lineWidth = 1.5;
  ctx.lineCap = 'round';

  if (design.mouth === 'smile') {
    ctx.beginPath();
    ctx.arc(32, my - 2, 6, 0.2, Math.PI - 0.2);
    ctx.stroke();
  } else if (design.mouth === 'line') {
    ctx.beginPath();
    ctx.moveTo(27, my);
    ctx.lineTo(37, my);
    ctx.stroke();
  } else if (design.mouth === 'dots') {
    ctx.fillStyle = col.eye;
    for (let d = 0; d < 3; d++) {
      ctx.beginPath();
      ctx.arc(27 + d * 5, my, 1.2, 0, Math.PI * 2);
      ctx.fill();
    }
  } else { // wave
    ctx.beginPath();
    ctx.moveTo(26, my);
    ctx.quadraticCurveTo(29, my + 3, 32, my);
    ctx.quadraticCurveTo(35, my - 3, 38, my);
    ctx.stroke();
  }

  // ── Body ──
  const bx = 20, by = 44, bw = 24, bh = 14;
  ctx.fillStyle = col.body;
  ctx.strokeStyle = col.dark;
  ctx.lineWidth = 1.5;
  roundRect(ctx, bx, by, bw, bh, 4);

  // Body detail — center line + bolts
  ctx.fillStyle = col.accent;
  ctx.fillRect(30, by + 2, 4, bh - 4);
  ctx.fillStyle = col.dark;
  ctx.beginPath();
  ctx.arc(26, by + bh / 2, 1.5, 0, Math.PI * 2);
  ctx.fill();
  ctx.beginPath();
  ctx.arc(38, by + bh / 2, 1.5, 0, Math.PI * 2);
  ctx.fill();

  // ── Arms ──
  ctx.strokeStyle = col.accent;
  ctx.lineWidth = 2.5;
  ctx.lineCap = 'round';
  // Left arm
  const armWave = Math.sin(anim.floatPhase * 1.3) * 2;
  ctx.beginPath();
  ctx.moveTo(bx, by + 4);
  ctx.lineTo(bx - 6, by + 8 + armWave);
  ctx.stroke();
  // Right arm
  ctx.beginPath();
  ctx.moveTo(bx + bw, by + 4);
  ctx.lineTo(bx + bw + 6, by + 8 - armWave);
  ctx.stroke();

  // Arm hands (small circles)
  ctx.fillStyle = col.accent;
  ctx.beginPath();
  ctx.arc(bx - 6, by + 8 + armWave, 2, 0, Math.PI * 2);
  ctx.fill();
  ctx.beginPath();
  ctx.arc(bx + bw + 6, by + 8 - armWave, 2, 0, Math.PI * 2);
  ctx.fill();

  // ── Acting glow ring ──
  if (isActing) {
    const glowPulse = 0.3 + Math.sin(time * 4) * 0.15;
    ctx.shadowColor = col.accent;
    ctx.shadowBlur = 8;
    ctx.strokeStyle = col.accent;
    ctx.globalAlpha = (isFolded ? 0.4 : 1) * glowPulse;
    ctx.lineWidth = 2;
    roundRect(ctx, 2, 4, 60, 56, 8, true);
    ctx.shadowBlur = 0;
    ctx.globalAlpha = isFolded ? 0.4 : 1;
  }

  ctx.restore();
  ctx.globalAlpha = 1;
}

function roundRect(ctx, x, y, w, h, r, strokeOnly) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.lineTo(x + w - r, y);
  ctx.quadraticCurveTo(x + w, y, x + w, y + r);
  ctx.lineTo(x + w, y + h - r);
  ctx.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
  ctx.lineTo(x + r, y + h);
  ctx.quadraticCurveTo(x, y + h, x, y + h - r);
  ctx.lineTo(x, y + r);
  ctx.quadraticCurveTo(x, y, x + r, y);
  ctx.closePath();
  if (!strokeOnly) ctx.fill();
  ctx.stroke();
}

// Start the robot animation loop immediately
startRobotAnimations();

/* ══════════════════════════════════════════════════════
   THREE.JS 3D ATMOSPHERIC POKER ROOM
   ══════════════════════════════════════════════════════ */

(function initScene3D() {
  if (typeof THREE === 'undefined') {
    // Three.js not yet loaded, retry
    setTimeout(initScene3D, 100);
    return;
  }

  const canvas = document.getElementById('bg-3d');
  if (!canvas) return;

  // ── Renderer ──
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: false });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
  renderer.setSize(window.innerWidth, window.innerHeight);
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = THREE.PCFSoftShadowMap;
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 0.7;

  // ── Scene ──
  const scene = new THREE.Scene();
  scene.background = new THREE.Color(0x050505);
  scene.fog = new THREE.FogExp2(0x080808, 0.045);

  // ── Camera ── (angled slightly down, looking at table)
  const camera = new THREE.PerspectiveCamera(50, window.innerWidth / window.innerHeight, 0.1, 100);
  camera.position.set(0, 6.5, 9);
  camera.lookAt(0, 0, 0);

  // ── Floor ──
  const floorGeo = new THREE.PlaneGeometry(40, 40);
  const floorMat = new THREE.MeshStandardMaterial({
    color: 0x0a0a08,
    roughness: 0.95,
    metalness: 0.0
  });
  const floor = new THREE.Mesh(floorGeo, floorMat);
  floor.rotation.x = -Math.PI / 2;
  floor.position.y = -1.6;
  floor.receiveShadow = true;
  scene.add(floor);

  // ── Poker Table (3D) ──
  // Table top (ellipse disc)
  const tableShape = new THREE.Shape();
  const tableRx = 4.5, tableRy = 2.8;
  for (let i = 0; i <= 64; i++) {
    const a = (i / 64) * Math.PI * 2;
    const px = Math.cos(a) * tableRx;
    const pz = Math.sin(a) * tableRy;
    i === 0 ? tableShape.moveTo(px, pz) : tableShape.lineTo(px, pz);
  }
  const tableExtrudeSettings = { depth: 0.25, bevelEnabled: true, bevelThickness: 0.08, bevelSize: 0.08, bevelSegments: 4 };
  const tableGeo = new THREE.ExtrudeGeometry(tableShape, tableExtrudeSettings);
  const feltMat = new THREE.MeshStandardMaterial({
    color: 0x1a6b47,
    roughness: 0.85,
    metalness: 0.0,
    emissive: 0x0a2e1e,
    emissiveIntensity: 0.15
  });
  const tableMesh = new THREE.Mesh(tableGeo, feltMat);
  tableMesh.rotation.x = -Math.PI / 2;
  tableMesh.position.y = -0.3;
  tableMesh.castShadow = true;
  tableMesh.receiveShadow = true;
  scene.add(tableMesh);

  // Table rim
  const rimShape = new THREE.Shape();
  const rimRx = tableRx + 0.3, rimRy = tableRy + 0.2;
  for (let i = 0; i <= 64; i++) {
    const a = (i / 64) * Math.PI * 2;
    rimShape.lineTo(Math.cos(a) * rimRx, Math.sin(a) * rimRy);
  }
  const rimHole = new THREE.Path();
  for (let i = 0; i <= 64; i++) {
    const a = (i / 64) * Math.PI * 2;
    rimHole.lineTo(Math.cos(a) * (tableRx - 0.05), Math.sin(a) * (tableRy - 0.05));
  }
  rimShape.holes.push(rimHole);
  const rimGeo = new THREE.ExtrudeGeometry(rimShape, { depth: 0.35, bevelEnabled: true, bevelThickness: 0.04, bevelSize: 0.04, bevelSegments: 3 });
  const woodMat = new THREE.MeshStandardMaterial({
    color: 0x2a1508,
    roughness: 0.7,
    metalness: 0.15,
    emissive: 0x0d0803,
    emissiveIntensity: 0.1
  });
  const rimMesh = new THREE.Mesh(rimGeo, woodMat);
  rimMesh.rotation.x = -Math.PI / 2;
  rimMesh.position.y = -0.35;
  rimMesh.castShadow = true;
  scene.add(rimMesh);

  // Table legs (4 simple cylinders)
  const legGeo = new THREE.CylinderGeometry(0.12, 0.14, 1.3, 8);
  const legMat = new THREE.MeshStandardMaterial({ color: 0x1a0c04, roughness: 0.8, metalness: 0.2 });
  const legPositions = [
    [-2.8, -1.0, -1.6], [2.8, -1.0, -1.6],
    [-2.8, -1.0, 1.6], [2.8, -1.0, 1.6]
  ];
  legPositions.forEach(([x, y, z]) => {
    const leg = new THREE.Mesh(legGeo, legMat);
    leg.position.set(x, y, z);
    leg.castShadow = true;
    scene.add(leg);
  });

  // ── Hanging Lamp ──
  const lampY = 7;
  // Fixture
  const fixtureGeo = new THREE.ConeGeometry(0.6, 0.4, 16, 1, true);
  const fixtureMat = new THREE.MeshStandardMaterial({
    color: 0x1a1a1a,
    roughness: 0.5,
    metalness: 0.7,
    side: THREE.DoubleSide
  });
  const fixture = new THREE.Mesh(fixtureGeo, fixtureMat);
  fixture.position.set(0, lampY, 0);
  scene.add(fixture);

  // Cord
  const cordGeo = new THREE.CylinderGeometry(0.015, 0.015, 3, 4);
  const cordMat = new THREE.MeshBasicMaterial({ color: 0x222222 });
  const cord = new THREE.Mesh(cordGeo, cordMat);
  cord.position.set(0, lampY + 1.7, 0);
  scene.add(cord);

  // Lamp bulb glow
  const bulbGeo = new THREE.SphereGeometry(0.12, 8, 8);
  const bulbMat = new THREE.MeshBasicMaterial({ color: 0xfff0c0 });
  const bulb = new THREE.Mesh(bulbGeo, bulbMat);
  bulb.position.set(0, lampY - 0.15, 0);
  scene.add(bulb);

  // ── Lights ──
  // Main spotlight from lamp
  const spotLight = new THREE.SpotLight(0xffd890, 2.5, 18, Math.PI / 4.5, 0.6, 1.5);
  spotLight.position.set(0, lampY - 0.1, 0);
  spotLight.target.position.set(0, -1.5, 0);
  spotLight.castShadow = true;
  spotLight.shadow.mapSize.width = 1024;
  spotLight.shadow.mapSize.height = 1024;
  spotLight.shadow.camera.near = 1;
  spotLight.shadow.camera.far = 15;
  scene.add(spotLight);
  scene.add(spotLight.target);

  // Soft ambient
  const ambient = new THREE.AmbientLight(0x1a1520, 0.4);
  scene.add(ambient);

  // Warm fill from below-camera
  const fillLight = new THREE.PointLight(0x553320, 0.3, 20);
  fillLight.position.set(0, 2, 8);
  scene.add(fillLight);

  // ── Light Cone (volumetric fake) ──
  const coneH = lampY + 0.2;
  const coneR = Math.tan(Math.PI / 4.5) * coneH * 0.7;
  const coneGeo = new THREE.ConeGeometry(coneR, coneH, 32, 1, true);
  const coneMat = new THREE.MeshBasicMaterial({
    color: 0xfff5d0,
    transparent: true,
    opacity: 0.018,
    side: THREE.DoubleSide,
    depthWrite: false,
    blending: THREE.AdditiveBlending
  });
  const coneMesh = new THREE.Mesh(coneGeo, coneMat);
  coneMesh.position.set(0, lampY / 2 - 0.5, 0);
  coneMesh.rotation.x = Math.PI; // point downward
  scene.add(coneMesh);

  // ── Smoke Particles ──
  const smokeTexture = createSmokeTexture();
  const smokeMaterial = new THREE.SpriteMaterial({
    map: smokeTexture,
    transparent: true,
    opacity: 0.12,
    depthWrite: false,
    blending: THREE.AdditiveBlending,
    color: 0xccbbaa
  });

  const SMOKE_COUNT = 35;
  const smokeParticles = [];

  for (let i = 0; i < SMOKE_COUNT; i++) {
    const sprite = new THREE.Sprite(smokeMaterial.clone());
    resetSmoke(sprite, true);
    scene.add(sprite);
    smokeParticles.push(sprite);
  }

  function resetSmoke(sprite, randomY) {
    sprite.position.set(
      (Math.random() - 0.5) * 14,
      randomY ? Math.random() * 8 : -1 + Math.random() * 2,
      (Math.random() - 0.5) * 10
    );
    const s = 1.5 + Math.random() * 3;
    sprite.scale.set(s, s, 1);
    sprite.material.opacity = 0;
    sprite.material.rotation = Math.random() * Math.PI * 2;
    sprite.userData.speed = 0.15 + Math.random() * 0.25;
    sprite.userData.drift = (Math.random() - 0.5) * 0.3;
    sprite.userData.rotSpeed = (Math.random() - 0.5) * 0.3;
    sprite.userData.maxOpacity = 0.04 + Math.random() * 0.08;
    sprite.userData.life = 0;
    sprite.userData.maxLife = 8 + Math.random() * 12;
  }

  // ── Dust Motes ──
  const MOTE_COUNT = 120;
  const motePositions = new Float32Array(MOTE_COUNT * 3);
  const moteSizes = new Float32Array(MOTE_COUNT);
  const motePhases = [];

  for (let i = 0; i < MOTE_COUNT; i++) {
    // Concentrate motes in the light cone area
    const angle = Math.random() * Math.PI * 2;
    const r = Math.random() * 3.5;
    motePositions[i * 3] = Math.cos(angle) * r;
    motePositions[i * 3 + 1] = Math.random() * 6;
    motePositions[i * 3 + 2] = Math.sin(angle) * r * 0.7;
    moteSizes[i] = 1 + Math.random() * 2;
    motePhases.push({
      speed: 0.1 + Math.random() * 0.3,
      phase: Math.random() * Math.PI * 2,
      drift: (Math.random() - 0.5) * 0.5
    });
  }

  const moteGeo = new THREE.BufferGeometry();
  moteGeo.setAttribute('position', new THREE.BufferAttribute(motePositions, 3));
  moteGeo.setAttribute('size', new THREE.BufferAttribute(moteSizes, 1));

  const motesMat = new THREE.PointsMaterial({
    color: 0xffe8c0,
    size: 0.04,
    transparent: true,
    opacity: 0.4,
    depthWrite: false,
    blending: THREE.AdditiveBlending,
    sizeAttenuation: true
  });

  const motes = new THREE.Points(moteGeo, motesMat);
  scene.add(motes);

  // ── Room walls (dark panels for depth) ──
  const wallMat = new THREE.MeshStandardMaterial({
    color: 0x080604,
    roughness: 0.95,
    metalness: 0.0
  });

  // Back wall
  const backWall = new THREE.Mesh(new THREE.PlaneGeometry(40, 12), wallMat);
  backWall.position.set(0, 4, -12);
  scene.add(backWall);

  // Side walls
  const sideWallL = new THREE.Mesh(new THREE.PlaneGeometry(30, 12), wallMat);
  sideWallL.position.set(-14, 4, 0);
  sideWallL.rotation.y = Math.PI / 2;
  scene.add(sideWallL);

  const sideWallR = new THREE.Mesh(new THREE.PlaneGeometry(30, 12), wallMat);
  sideWallR.position.set(14, 4, 0);
  sideWallR.rotation.y = -Math.PI / 2;
  scene.add(sideWallR);

  // Ceiling
  const ceiling = new THREE.Mesh(new THREE.PlaneGeometry(40, 30), new THREE.MeshStandardMaterial({ color: 0x060604, roughness: 0.95 }));
  ceiling.rotation.x = Math.PI / 2;
  ceiling.position.y = 10;
  scene.add(ceiling);

  // ── LOUNGE FURNITURE ──

  // Materials
  const leatherMat = new THREE.MeshStandardMaterial({
    color: 0x1c0f08, roughness: 0.75, metalness: 0.05,
    emissive: 0x080402, emissiveIntensity: 0.05
  });
  const cushionMat = new THREE.MeshStandardMaterial({
    color: 0x2a1610, roughness: 0.85, metalness: 0.0,
    emissive: 0x0a0504, emissiveIntensity: 0.08
  });
  const darkWoodMat = new THREE.MeshStandardMaterial({
    color: 0x1a0c06, roughness: 0.65, metalness: 0.12,
    emissive: 0x060301, emissiveIntensity: 0.05
  });
  const glossyBarMat = new THREE.MeshStandardMaterial({
    color: 0x0d0604, roughness: 0.35, metalness: 0.3
  });
  const frameMat = new THREE.MeshStandardMaterial({
    color: 0x3a2a1a, roughness: 0.5, metalness: 0.3
  });
  const canvasMat = new THREE.MeshStandardMaterial({
    color: 0x0c0a08, roughness: 0.9, metalness: 0.0,
    emissive: 0x060504, emissiveIntensity: 0.15
  });

  // ── Armchairs (4 around the table) ──
  function createChair(x, z, rotY) {
    const group = new THREE.Group();
    // Seat
    const seat = new THREE.Mesh(new THREE.BoxGeometry(1.2, 0.35, 1.1), cushionMat);
    seat.position.set(0, 0.15, 0);
    seat.castShadow = true;
    group.add(seat);
    // Back rest
    const back = new THREE.Mesh(new THREE.BoxGeometry(1.2, 1.0, 0.25), leatherMat);
    back.position.set(0, 0.7, -0.42);
    back.castShadow = true;
    group.add(back);
    // Armrests
    [-0.55, 0.55].forEach(side => {
      const arm = new THREE.Mesh(new THREE.BoxGeometry(0.12, 0.45, 0.9), leatherMat);
      arm.position.set(side, 0.45, 0.05);
      arm.castShadow = true;
      group.add(arm);
    });
    // Legs (4)
    const legGeo = new THREE.CylinderGeometry(0.04, 0.04, 0.3, 6);
    [[-0.45, -0.35], [0.45, -0.35], [-0.45, 0.35], [0.45, 0.35]].forEach(([lx, lz]) => {
      const leg = new THREE.Mesh(legGeo, darkWoodMat);
      leg.position.set(lx, -0.12, lz);
      group.add(leg);
    });

    group.position.set(x, -1.3, z);
    group.rotation.y = rotY;
    scene.add(group);
  }

  // Place chairs around table (not directly in front of camera)
  createChair(-6.5, -2, Math.PI * 0.3);   // back-left
  createChair(6.5, -2, -Math.PI * 0.3);   // back-right
  createChair(-7, 3, Math.PI * 0.6);      // front-left
  createChair(7, 3, -Math.PI * 0.6);      // front-right

  // ── Bar Counter (back wall) ──
  const barGroup = new THREE.Group();
  // Counter body
  const barBody = new THREE.Mesh(new THREE.BoxGeometry(7, 1.8, 1.0), darkWoodMat);
  barBody.position.set(0, 0, 0);
  barBody.castShadow = true;
  barGroup.add(barBody);
  // Countertop
  const barTop = new THREE.Mesh(new THREE.BoxGeometry(7.2, 0.1, 1.15), glossyBarMat);
  barTop.position.set(0, 0.95, 0);
  barTop.castShadow = true;
  barGroup.add(barTop);
  // Front panel trim
  const barTrim = new THREE.Mesh(new THREE.BoxGeometry(7, 0.08, 0.04), frameMat);
  barTrim.position.set(0, 0.4, 0.52);
  barGroup.add(barTrim);
  // Foot rail
  const railGeo = new THREE.CylinderGeometry(0.03, 0.03, 6.8, 8);
  railGeo.rotateZ(Math.PI / 2);
  const rail = new THREE.Mesh(railGeo, new THREE.MeshStandardMaterial({ color: 0xc0a060, roughness: 0.3, metalness: 0.7 }));
  rail.position.set(0, -0.5, 0.52);
  barGroup.add(rail);

  barGroup.position.set(0, -0.5, -10.5);
  scene.add(barGroup);

  // ── Bottles on bar ──
  const bottleColors = [0x1a6030, 0x4a2010, 0x103050, 0x602020, 0x2a1808, 0x105040];
  const glassMat = (color) => new THREE.MeshStandardMaterial({
    color, roughness: 0.15, metalness: 0.1, transparent: true, opacity: 0.7
  });
  for (let i = 0; i < 6; i++) {
    const bGroup = new THREE.Group();
    const body = new THREE.Mesh(
      new THREE.CylinderGeometry(0.08, 0.1, 0.5, 8),
      glassMat(bottleColors[i])
    );
    body.position.y = 0.25;
    bGroup.add(body);
    const neck = new THREE.Mesh(
      new THREE.CylinderGeometry(0.03, 0.06, 0.2, 8),
      glassMat(bottleColors[i])
    );
    neck.position.y = 0.6;
    bGroup.add(neck);
    bGroup.position.set(-2.5 + i * 1.0, 0.5, -10.2);
    scene.add(bGroup);
  }

  // ── Shelf on left wall ──
  const shelfGroup = new THREE.Group();
  // Cabinet body
  const cabinetBody = new THREE.Mesh(new THREE.BoxGeometry(0.5, 2.5, 2.5), darkWoodMat);
  cabinetBody.castShadow = true;
  shelfGroup.add(cabinetBody);
  // Shelves (3 horizontal)
  for (let s = 0; s < 3; s++) {
    const shelf = new THREE.Mesh(new THREE.BoxGeometry(0.52, 0.06, 2.5), frameMat);
    shelf.position.set(0, -0.8 + s * 0.8, 0);
    shelfGroup.add(shelf);
  }
  // Small bottles/objects on shelves
  for (let s = 0; s < 3; s++) {
    for (let b = 0; b < 3; b++) {
      const obj = new THREE.Mesh(
        new THREE.CylinderGeometry(0.06, 0.07, 0.3, 6),
        glassMat(bottleColors[(s * 3 + b) % bottleColors.length])
      );
      obj.position.set(0.02, -0.55 + s * 0.8, -0.7 + b * 0.7);
      shelfGroup.add(obj);
    }
  }
  shelfGroup.position.set(-13.5, 1.5, -4);
  scene.add(shelfGroup);

  // ── Picture Frames (back wall) ──
  function createFrame(x, y, z, w, h) {
    const fGroup = new THREE.Group();
    // Frame border (4 thin boxes)
    const t = 0.08;
    const fGeo = [
      [w + t * 2, t, t, 0, h / 2 + t / 2, 0],       // top
      [w + t * 2, t, t, 0, -h / 2 - t / 2, 0],      // bottom
      [t, h, t, -w / 2 - t / 2, 0, 0],                // left
      [t, h, t, w / 2 + t / 2, 0, 0],                 // right
    ];
    fGeo.forEach(([fw, fh, fd, fx, fy, fz]) => {
      const bar = new THREE.Mesh(new THREE.BoxGeometry(fw, fh, fd), frameMat);
      bar.position.set(fx, fy, fz);
      fGroup.add(bar);
    });
    // Canvas
    const canvas = new THREE.Mesh(new THREE.PlaneGeometry(w, h), canvasMat);
    canvas.position.z = -0.02;
    fGroup.add(canvas);
    fGroup.position.set(x, y, z);
    scene.add(fGroup);
  }

  createFrame(-3.5, 4.5, -11.9, 2.0, 1.4);
  createFrame(3.5, 4.2, -11.9, 1.6, 1.8);

  // ── Wall Sconces (warm lighting on side walls) ──
  function createSconce(x, y, z, rotY) {
    // Sconce fixture
    const bracket = new THREE.Mesh(
      new THREE.BoxGeometry(0.12, 0.2, 0.15),
      new THREE.MeshStandardMaterial({ color: 0x3a3020, roughness: 0.4, metalness: 0.6 })
    );
    bracket.position.set(x, y, z);
    bracket.rotation.y = rotY;
    scene.add(bracket);

    // Warm point light
    const sconceLight = new THREE.PointLight(0xffa040, 0.25, 8, 2);
    sconceLight.position.set(
      x + Math.sin(rotY) * 0.2,
      y + 0.1,
      z + Math.cos(rotY) * 0.2
    );
    scene.add(sconceLight);

    // Small glowing sphere
    const glowSphere = new THREE.Mesh(
      new THREE.SphereGeometry(0.05, 6, 6),
      new THREE.MeshBasicMaterial({ color: 0xffe0a0 })
    );
    glowSphere.position.copy(sconceLight.position);
    scene.add(glowSphere);
  }

  createSconce(-13.8, 3.5, -3, Math.PI / 2);
  createSconce(-13.8, 3.5, 3, Math.PI / 2);
  createSconce(13.8, 3.5, -3, -Math.PI / 2);
  createSconce(13.8, 3.5, 3, -Math.PI / 2);

  // ── Resize ──
  function onResize() {
    camera.aspect = window.innerWidth / window.innerHeight;
    camera.updateProjectionMatrix();
    renderer.setSize(window.innerWidth, window.innerHeight);
  }
  window.addEventListener('resize', onResize);

  // ── Animation Loop ──
  const clock = new THREE.Clock();

  function animate3D() {
    requestAnimationFrame(animate3D);
    const dt = clock.getDelta();
    const time = clock.getElapsedTime();

    // Lamp subtle sway
    const swayX = Math.sin(time * 0.4) * 0.08;
    const swayZ = Math.cos(time * 0.3) * 0.05;
    fixture.position.x = swayX;
    fixture.position.z = swayZ;
    bulb.position.x = swayX;
    bulb.position.z = swayZ;
    cord.position.x = swayX * 0.5;
    cord.position.z = swayZ * 0.5;
    spotLight.position.x = swayX;
    spotLight.position.z = swayZ;
    coneMesh.position.x = swayX * 0.5;
    coneMesh.position.z = swayZ * 0.5;

    // Spotlight subtle intensity pulse
    spotLight.intensity = 2.5 + Math.sin(time * 0.8) * 0.15;

    // Smoke particles
    for (const smoke of smokeParticles) {
      smoke.userData.life += dt;
      const life = smoke.userData.life;
      const maxLife = smoke.userData.maxLife;

      if (life > maxLife) {
        resetSmoke(smoke, false);
        continue;
      }

      // Fade in/out
      const fadeIn = Math.min(life / 2, 1);
      const fadeOut = Math.max(0, 1 - (life - (maxLife - 3)) / 3);
      smoke.material.opacity = smoke.userData.maxOpacity * fadeIn * fadeOut;

      // Drift upward and sideways
      smoke.position.y += smoke.userData.speed * dt;
      smoke.position.x += smoke.userData.drift * dt;
      smoke.material.rotation += smoke.userData.rotSpeed * dt;
    }

    // Dust motes
    const posAttr = moteGeo.getAttribute('position');
    for (let i = 0; i < MOTE_COUNT; i++) {
      const p = motePhases[i];
      posAttr.array[i * 3 + 1] += p.speed * dt * 0.3;
      posAttr.array[i * 3] += Math.sin(time * 0.5 + p.phase) * p.drift * dt * 0.3;
      posAttr.array[i * 3 + 2] += Math.cos(time * 0.3 + p.phase) * p.drift * dt * 0.2;

      // Loop motes that go too high
      if (posAttr.array[i * 3 + 1] > 7) {
        posAttr.array[i * 3 + 1] = -0.5;
        posAttr.array[i * 3] = (Math.random() - 0.5) * 7;
        posAttr.array[i * 3 + 2] = (Math.random() - 0.5) * 5;
      }
    }
    posAttr.needsUpdate = true;

    // Light cone subtle breath
    coneMesh.material.opacity = 0.015 + Math.sin(time * 0.6) * 0.004;

    renderer.render(scene, camera);
  }

  animate3D();

  // ── Procedural smoke texture ──
  function createSmokeTexture() {
    const size = 128;
    const c = document.createElement('canvas');
    c.width = size;
    c.height = size;
    const ctx = c.getContext('2d');

    // Soft radial gradient with noise
    const cx = size / 2, cy = size / 2;
    const grad = ctx.createRadialGradient(cx, cy, 0, cx, cy, size / 2);
    grad.addColorStop(0, 'rgba(255,255,255,0.6)');
    grad.addColorStop(0.3, 'rgba(255,255,255,0.3)');
    grad.addColorStop(0.6, 'rgba(255,255,255,0.1)');
    grad.addColorStop(1, 'rgba(255,255,255,0)');

    ctx.fillStyle = grad;
    ctx.fillRect(0, 0, size, size);

    // Add soft noise for realism
    const imgData = ctx.getImageData(0, 0, size, size);
    for (let i = 0; i < imgData.data.length; i += 4) {
      const noise = (Math.random() - 0.5) * 20;
      imgData.data[i] = Math.max(0, Math.min(255, imgData.data[i] + noise));
      imgData.data[i + 1] = Math.max(0, Math.min(255, imgData.data[i + 1] + noise));
      imgData.data[i + 2] = Math.max(0, Math.min(255, imgData.data[i + 2] + noise));
    }
    ctx.putImageData(imgData, 0, 0);

    const texture = new THREE.CanvasTexture(c);
    texture.needsUpdate = true;
    return texture;
  }
})();
