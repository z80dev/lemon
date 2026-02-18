/* ── Lemon Poker – Elite Spectator App ── */

const SUIT_MAP = { c: '♣', d: '♦', h: '♥', s: '♠' };
const SUIT_COLOR = { c: 'black', d: 'red', h: 'red', s: 'black' };
const RANK_DISPLAY = { T: '10' };

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
let feedActionRendered = 0;   // index into state.events for actions
let feedTalkRendered = 0;     // index into state.events for talk
let feedSnapshotGeneration = 0; // bumped on snapshot to force full rebuild

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
const winnerToast = $('#winner-toast');

const startForm = $('#start-form');
const talkForm = $('#talk-form');
const pauseBtn = $('#pause-btn');
const resumeBtn = $('#resume-btn');
const stopBtn = $('#stop-btn');
const adminToggle = $('#admin-toggle');

let seatEls = [];        // seat wrapper elements
let seatData = [];       // cached per‐seat data for diffing
let toastTimeout = null;

/* ── Init ── */
init();

async function init() {
  await refreshState();
  bindControls();
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
  return {
    players: toInt(fd.get('players'), 6),
    hands: toInt(fd.get('hands'), 20),
    stack: toInt(fd.get('stack'), 1000),
    smallBlind: toInt(fd.get('smallBlind'), 50),
    bigBlind: toInt(fd.get('bigBlind'), 100),
    seed: blankToNull(fd.get('seed')),
    timeoutMs: toInt(fd.get('timeoutMs'), 90000),
    maxDecisions: toInt(fd.get('maxDecisions'), 200),
    tableId: blankToNull(fd.get('tableId')),
    agentId: blankToNull(fd.get('agentId')),
    playerAgentIds: parseCsv(fd.get('playerAgentIds')),
    playerLabels: parseCsv(fd.get('playerLabels')),
    systemPrompt: blankToNull(fd.get('systemPrompt')),
    tableTalkEnabled: !!fd.get('tableTalkEnabled')
  };
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
  }

  // board cards — only rebuild when card keys change
  const board = hand?.board || [];
  const boardKey = board.join(',');
  if (boardKey !== lastBoardKey) {
    if (board.length > 0) {
      boardCards.innerHTML = board.map(c => renderCard(c, false, true)).join('');
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

  const avatar = document.createElement('div');
  avatar.className = `seat-avatar c${index % 9}`;

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

  chip.appendChild(avatar);
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
    refs: { chip, avatar, name, stackText, status, cards, bet }
  };
}

function renderSeats(table, hand) {
  const tableSeats = table.seats || [];
  const n = tableSeats.length;
  const positions = SEAT_POSITIONS[n] || SEAT_POSITIONS[6];

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

    // Avatar letter
    const avatarChar = label.charAt(0).toUpperCase();
    if (prev.avatarChar !== avatarChar) {
      refs.avatar.textContent = avatarChar;
      prev.avatarChar = avatarChar;
    }

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
function renderCard(cardStr, small, isNew) {
  if (!cardStr || cardStr.length < 2) return `<div class="card${small ? ' card-sm' : ''} black"><span class="rank">?</span><span class="suit">?</span></div>`;

  const rankChar = cardStr[0];
  const suitChar = cardStr[1].toLowerCase();
  const rank = RANK_DISPLAY[rankChar] || rankChar;
  const suit = SUIT_MAP[suitChar] || suitChar;
  const color = SUIT_COLOR[suitChar] || 'black';
  const newCls = isNew ? ' card-new' : '';

  return `<div class="card${small ? ' card-sm' : ''} ${color}${newCls}"><span class="rank">${rank}</span><span class="suit">${suit}</span></div>`;
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
  const el = div.firstElementChild;
  if (el) container.appendChild(el);
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

function renderActionItem(ev) {
  const time = ev.ts ? new Date(ev.ts).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' }) : '';
  let line = ev.type;

  if (ev.type === 'action_taken') {
    const actor = ev.actor || `seat ${ev.seat}`;
    const fb = ev.source === 'fallback' ? ' <span style="color:var(--amber);opacity:.7">[fb]</span>' : '';
    line = `<strong>${esc(actor)}</strong> → ${esc(ev.action)}${fb}`;
  } else if (ev.type === 'hand_started') {
    line = `Hand ${ev.hand_index} started (btn ${ev.button_seat}, sb ${ev.small_blind_seat}, bb ${ev.big_blind_seat})`;
  } else if (ev.type === 'street_changed') {
    const boardHtml = (ev.board || []).map(c => renderCard(c, true, false)).join(' ');
    line = `Street → <strong>${esc(ev.street)}</strong>  ${boardHtml}`;
  } else if (ev.type === 'hand_finished') {
    line = `Hand ${ev.hand_index} finished · ${formatWinners(ev.result?.winners || [])}`;
  } else if (ev.type === 'table_talk_blocked') {
    line = `${esc(ev.actor || `seat ${ev.seat}`)} talk blocked (${esc(ev.reason || 'policy')})`;
  } else if (ev.type.startsWith('match_')) {
    line = `${ev.type}${ev.reason ? ` (${esc(ev.reason)})` : ''}`;
  }

  return `<div class="feed-item event-${ev.type}"><span class="ts">${esc(time)}</span><span>${line}</span></div>`;
}

function renderTalkItem(ev) {
  const time = ev.ts ? new Date(ev.ts).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' }) : '';
  const actor = ev.actor || `seat ${ev.seat}`;
  return `<div class="talk-item"><span class="ts">${esc(time)}</span><span class="actor">${esc(actor)}:</span><span class="text">${esc(ev.text || '')}</span></div>`;
}

/* ── Winner Toast ── */
function showWinnerToast(ev) {
  const winners = ev.result?.winners || [];
  if (winners.length === 0) return;

  const msg = winners.map(w => `Seat ${w.seat} wins ${formatChips(w.amount)}`).join('  ·  ');
  winnerToast.textContent = `🏆 ${msg}`;
  winnerToast.classList.add('show');

  clearTimeout(toastTimeout);
  toastTimeout = setTimeout(() => winnerToast.classList.remove('show'), 4000);
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
function esc(v) {
  return String(v)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}
