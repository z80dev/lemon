/* Lemon showcase — self-contained behaviour. No dependencies, no network. */
(() => {
  "use strict";

  document.documentElement.classList.add("js");

  const motionQuery = window.matchMedia("(prefers-reduced-motion: reduce)");
  const prefersReducedMotion = () => motionQuery.matches;

  /* ── deployment tabs ─────────────────────────────────────────────────── */
  const tabs = [...document.querySelectorAll(".tabs [role='tab']")];
  const panels = [...document.querySelectorAll(".tabs [role='tabpanel']")];

  function selectTab(tab) {
    const target = tab.getAttribute("aria-controls");
    tabs.forEach((item) => {
      const selected = item === tab;
      item.classList.toggle("is-active", selected);
      item.setAttribute("aria-selected", String(selected));
      item.tabIndex = selected ? 0 : -1;
    });
    panels.forEach((panel) => {
      panel.hidden = panel.id !== target;
    });
  }

  function wireTablist(list, onSelect) {
    list.forEach((tab, index) => {
      tab.addEventListener("click", () => onSelect(tab));
      tab.addEventListener("keydown", (event) => {
        if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key))
          return;
        event.preventDefault();
        const next =
          event.key === "Home"
            ? 0
            : event.key === "End"
              ? list.length - 1
              : (index + (event.key === "ArrowRight" ? 1 : -1) + list.length) %
                list.length;
        list[next].focus();
        onSelect(list[next]);
      });
    });
  }

  wireTablist(tabs, selectTab);

  /* ── anchor scrolling ────────────────────────────────────────────────── */
  document.querySelectorAll("[data-scroll]").forEach((link) => {
    link.addEventListener("click", (event) => {
      const target = document.querySelector(link.getAttribute("href"));
      if (!target) return;
      event.preventDefault();
      target.scrollIntoView({
        behavior: prefersReducedMotion() ? "auto" : "smooth",
      });
    });
  });

  /* ── scroll reveal ───────────────────────────────────────────────────── */
  const revealables = [...document.querySelectorAll(".reveal")];
  if (revealables.length) {
    const revealObserver = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting) return;
          entry.target.classList.add("is-in");
          revealObserver.unobserve(entry.target);
        });
      },
      { threshold: 0.12, rootMargin: "0px 0px -40px" },
    );
    revealables.forEach((el) => revealObserver.observe(el));
  }

  /* ── animated counters ───────────────────────────────────────────────── */
  const counters = [...document.querySelectorAll("[data-count]")];
  if (counters.length) {
    // Reserve the final width up front so the count-up never re-wraps the
    // text around it (hero facts, evidence prose).
    counters.forEach((el) => {
      el.style.display = "inline-block";
      el.style.minWidth = `${el.dataset.count.length}ch`;
    });
    const runCounter = (el) => {
      const target = parseInt(el.dataset.count, 10);
      if (!Number.isFinite(target) || prefersReducedMotion()) {
        el.textContent = String(target);
        return;
      }
      const duration = 900;
      const start = performance.now();
      const step = (now) => {
        const t = Math.min(1, (now - start) / duration);
        const eased = 1 - Math.pow(1 - t, 3);
        el.textContent = String(Math.round(target * eased));
        if (t < 1) requestAnimationFrame(step);
      };
      requestAnimationFrame(step);
    };
    const countObserver = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting) return;
          runCounter(entry.target);
          countObserver.unobserve(entry.target);
        });
      },
      { threshold: 0.6 },
    );
    counters.forEach((el) => countObserver.observe(el));
  }

  /* ── nav: highlight current section ──────────────────────────────────── */
  const navLinks = [...document.querySelectorAll("[data-nav]")];
  if (navLinks.length) {
    const sections = navLinks
      .map((link) => document.querySelector(link.getAttribute("href")))
      .filter(Boolean);
    const byId = new Map(
      navLinks.map((link) => [link.getAttribute("href").slice(1), link]),
    );
    const navObserver = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          const link = byId.get(entry.target.id);
          if (!link) return;
          if (entry.isIntersecting) {
            navLinks.forEach((item) => item.classList.remove("is-current"));
            link.classList.add("is-current");
          }
        });
      },
      { rootMargin: "-30% 0px -60%" },
    );
    sections.forEach((section) => navObserver.observe(section));
  }

  /* ── scenario ticker ─────────────────────────────────────────────────── */
  const SCENARIOS = [
    "werewolf",
    "vending_bench",
    "diplomacy",
    "poker",
    "survivor",
    "auction",
    "courtroom",
    "supply_chain",
    "legislature",
    "dungeon_crawl",
    "intel_network",
    "murder_mystery",
    "pandemic",
    "space_station",
    "startup_incubator",
    "stock_market",
    "skirmish",
  ];
  const ticker = document.getElementById("ticker");
  if (ticker) {
    // Two copies of the list so translateX(-50%) loops seamlessly.
    const items = [...SCENARIOS, ...SCENARIOS].map((name) => {
      const span = document.createElement("span");
      span.className = "ticker__item";
      span.textContent = name;
      return span;
    });
    ticker.replaceChildren(...items);
  }

  /* ── a small player: steps a script, pauses when offscreen or hidden ─── */
  function createPlayer({ root, frames, apply, reset, onCycleEnd = 1800 }) {
    if (!root) return null;

    let index = 0;
    let timer = null;
    let visible = false;

    const stop = () => {
      clearTimeout(timer);
      timer = null;
    };

    const tick = () => {
      if (index >= frames.length) {
        index = 0;
        timer = setTimeout(() => {
          reset();
          tick();
        }, onCycleEnd);
        return;
      }
      const frame = frames[index++];
      apply(frame);
      timer = setTimeout(tick, frame.wait || 900);
    };

    const start = () => {
      if (timer || !visible || document.hidden) return;
      tick();
    };

    const observer = new IntersectionObserver(
      (entries) => {
        visible = entries.some((entry) => entry.isIntersecting);
        if (visible) start();
        else stop();
      },
      { threshold: 0.15 },
    );
    observer.observe(root);

    document.addEventListener("visibilitychange", () => {
      if (document.hidden) stop();
      else start();
    });

    return {
      stop,
      destroy() {
        stop();
        observer.disconnect();
      },
    };
  }

  /* ── hero: supervision tree + event stream ───────────────────────────────
     Illustrative choreography of one OTP failure/restart cycle: a provider
     stream dies, the supervisor restarts the child under a fresh pid, and
     the siblings keep running. Values are representative, not a recording. */

  const streamList = document.getElementById("stream");
  const procList = document.getElementById("procs");

  const PROC_STATES = {
    run: { cls: "", badge: "badge--run", label: "running" },
    wait: { cls: "", badge: "badge--wait", label: "awaiting tool" },
    stall: { cls: "", badge: "badge--wait", label: "stalled" },
    down: { cls: "is-down", badge: "badge--down", label: "exited" },
    restart: {
      cls: "is-restart",
      badge: "badge--restart",
      label: "restarting",
    },
    replay: { cls: "is-restart", badge: "badge--restart", label: "replaying" },
  };

  const HERO_FRAMES = [
    {
      t: "09:41:02",
      k: "tool ",
      cls: "k--ok",
      m: "researcher · web.fetch → 200 in 412ms",
    },
    {
      t: "09:41:03",
      k: "model",
      cls: "",
      m: "trader · streaming completion · 1.2k tok",
    },
    {
      t: "09:41:04",
      k: "warn ",
      cls: "k--warn",
      m: "trader · provider stream stalled",
      proc: 2,
      state: "stall",
    },
    {
      t: "09:41:05",
      k: "EXIT ",
      cls: "k--err",
      m: "trader · {:stream_closed, :timeout}",
      proc: 2,
      state: "down",
      wait: 1100,
    },
    {
      t: "09:41:05",
      k: "sup  ",
      cls: "k--sup",
      m: "one_for_one · restarting agent.trader",
      proc: 2,
      state: "restart",
    },
    {
      t: "09:41:06",
      k: "init ",
      cls: "k--sup",
      m: "trader · replaying 118 events from run log",
      proc: 2,
      state: "replay",
      pid: "&lt;0.512.0&gt;",
    },
    {
      t: "09:41:06",
      k: "ok   ",
      cls: "k--ok",
      m: "trader · resumed at turn 27 · siblings untouched",
      proc: 2,
      state: "run",
      wait: 1200,
    },
    {
      t: "09:41:07",
      k: "tool ",
      cls: "k--ok",
      m: "moderator · vote.tally → 4 actors reporting",
    },
    {
      t: "09:41:08",
      k: "event",
      cls: "",
      m: "scribe · appended run.jsonl seq 121",
      wait: 1400,
    },
  ];

  const STREAM_WINDOW = 5;

  function streamRow(frame) {
    const li = document.createElement("li");
    li.innerHTML =
      `<span class="t">${frame.t}</span>` +
      `<span class="k ${frame.cls}">${frame.k}</span>` +
      `<span class="m">${frame.m}</span>`;
    return li;
  }

  function applyProc(frame) {
    if (!procList || !frame.proc) return;
    const proc = procList.querySelector(`[data-proc="${frame.proc}"]`);
    if (!proc) return;
    const state = PROC_STATES[frame.state];
    if (!state) return;
    proc.classList.remove("is-down", "is-restart");
    if (state.cls) proc.classList.add(state.cls);
    const badge = proc.querySelector(".badge");
    if (badge) {
      badge.className = `badge ${state.badge}`;
      badge.textContent = state.label;
    }
    if (frame.pid) {
      const pid = proc.querySelector(".proc__pid");
      if (pid) pid.innerHTML = frame.pid;
    }
  }

  function resetProcs() {
    if (!procList) return;
    procList.querySelectorAll(".proc").forEach((proc) => {
      proc.classList.remove("is-down", "is-restart");
      const badge = proc.querySelector(".badge");
      const initial = proc.dataset.initialState || "run";
      const state = PROC_STATES[initial];
      if (badge && state) {
        badge.className = `badge ${state.badge}`;
        badge.textContent = state.label;
      }
      const pid = proc.querySelector(".proc__pid");
      if (pid && proc.dataset.initialPid)
        pid.innerHTML = proc.dataset.initialPid;
    });
  }

  function initHero() {
    if (!streamList) return null;
    if (procList) {
      procList.querySelectorAll(".proc").forEach((proc) => {
        const pid = proc.querySelector(".proc__pid");
        if (pid && !proc.dataset.initialPid)
          proc.dataset.initialPid = pid.innerHTML;
      });
    }

    if (prefersReducedMotion()) {
      streamList.classList.add("is-static");
      streamList.replaceChildren(...HERO_FRAMES.map(streamRow));
      HERO_FRAMES.forEach(applyProc);
      return null;
    }

    streamList.classList.remove("is-static");
    streamList.replaceChildren();
    return createPlayer({
      root: streamList.closest(".panel--runtime") || streamList,
      frames: HERO_FRAMES,
      apply(frame) {
        streamList.append(streamRow(frame));
        while (streamList.children.length > STREAM_WINDOW) {
          streamList.firstElementChild.remove();
        }
        applyProc(frame);
      },
      reset() {
        streamList.replaceChildren();
        resetProcs();
      },
    });
  }

  /* ── arena: switchable illustrative turn feeds ───────────────────────────
     Three domains from the always-on arenas. The rows use event-shaped
     language from each domain, but are representative showcase data rather
     than a live feed or copied run log. */

  const feedList = document.getElementById("feed");
  const arenaTitle = document.getElementById("arena-title");
  const lbBody = document.getElementById("lb-body");
  const domainPills = [...document.querySelectorAll(".arena-switch [role='tab']")];

  const DOMAINS = {
    werewolf: {
      title: "lemon_sim_ui · werewolf · seed 4271",
      leaderboard: [
        ["model-a", 1548],
        ["model-b", 1511],
        ["model-c", 1489],
        ["baseline", 1402],
      ],
      frames: [
        { who: "narrator", act: "night_started", txt: "night 2 falls on the village" },
        {
          who: "wolf_2",
          act: "night_kill",
          txt: "targets seer_1 · pack consensus 2/2",
          cls: "is-err",
        },
        { who: "narrator", act: "day_started", txt: "day 3 · 7 players alive" },
        {
          who: "villager_4",
          act: "accusation_made",
          txt: "“wolf_2 dodged every question yesterday”",
        },
        {
          who: "wolf_2",
          act: "defense_made",
          txt: "“I voted with the village both days”",
        },
        {
          who: "doctor_1",
          act: "vote_cast",
          txt: "votes wolf_2 · tally 3/7",
        },
        {
          who: "villager_6",
          act: "vote_cast",
          txt: "votes wolf_2 · tally 4/7 · majority",
          cls: "is-ok",
        },
        {
          who: "narrator",
          act: "player_eliminated",
          txt: "wolf_2 lynched · role revealed: werewolf",
          cls: "is-ok",
        },
        {
          who: "sup",
          act: "actor_restarted",
          txt: "villager_5 · {:stream_closed} · resumed turn 41",
          cls: "is-sup",
        },
        { who: "narrator", act: "night_started", txt: "night 3 falls · 6 alive" },
      ],
    },
    vending: {
      title: "lemon_sim_ui · vending_bench · seed 1187",
      leaderboard: [
        ["model-b", 1562],
        ["model-a", 1518],
        ["baseline", 1444],
        ["model-c", 1431],
      ],
      frames: [
        {
          who: "operator",
          act: "supplier_email_sent",
          txt: "ghostsupply · water ×24 · $7.20",
        },
        {
          who: "operator",
          act: "supplier_message_sent",
          txt: "freshco · “Bulk Order — Cola and Energy Drinks”",
        },
        {
          who: "freshco",
          act: "supplier_reply_received",
          txt: "confirms 12× cola for $6.60 · delivery day 2",
          cls: "is-ok",
        },
        { who: "world", act: "day_advanced", txt: "day 1 → day 2" },
        { who: "world", act: "delivery_arrived", txt: "freshco · cola ×12" },
        {
          who: "physical_worker",
          act: "physical_worker_started",
          txt: "stock the machine from storage",
        },
        {
          who: "physical_worker",
          act: "action_rejected",
          txt: "No cash is available to collect",
          cls: "is-err",
        },
        {
          who: "machine",
          act: "sale_realized",
          txt: "slot A1 · cola ×4 · $8.00",
          cls: "is-ok",
        },
        { who: "world", act: "day_advanced", txt: "day 5 → day 6" },
        {
          who: "physical_worker",
          act: "cash_collected",
          txt: "$75.00",
          cls: "is-ok",
        },
        {
          who: "machine",
          act: "machine_fault_reported",
          txt: "slot reconfiguration needed to stock water",
          cls: "is-err",
        },
        {
          who: "machine",
          act: "sale_realized",
          txt: "slot B3 · energy_drink ×2 · $7.00",
          cls: "is-ok",
        },
        { who: "world", act: "day_advanced", txt: "day 13 → day 14" },
      ],
    },
    poker: {
      title: "lemon_sim_ui · poker · table pkr_09 · hand 214",
      leaderboard: [
        ["model-c", 1571],
        ["model-a", 1533],
        ["baseline", 1460],
        ["model-b", 1418],
      ],
      frames: [
        { who: "dealer", act: "hand_started", txt: "hand 214 · blinds 50/100" },
        {
          who: "model-a",
          act: "action_taken",
          txt: "raises to 300 from the button",
        },
        {
          who: "model-c",
          act: "action_taken",
          txt: "calls 300 from the big blind",
        },
        { who: "dealer", act: "flop_dealt", txt: "K♠ 9♦ 4♣" },
        {
          who: "model-c",
          act: "banter_said",
          txt: "“that flop missed you by a mile”",
        },
        {
          who: "model-c",
          act: "action_taken",
          txt: "check-raises to 900",
        },
        {
          who: "model-a",
          act: "action_taken",
          txt: "folds · pot 1,650 to model-c",
          cls: "is-ok",
        },
        {
          who: "sup",
          act: "actor_restarted",
          txt: "model-b · {:timeout} · rejoined next hand",
          cls: "is-sup",
        },
        { who: "dealer", act: "hand_started", txt: "hand 215 · blinds 50/100" },
        {
          who: "model-b",
          act: "action_taken",
          txt: "shoves 4,200 pre-flop",
          cls: "is-err",
        },
        {
          who: "model-c",
          act: "action_taken",
          txt: "calls with Q♥Q♠ · wins 8,500 pot",
          cls: "is-ok",
        },
      ],
    },
  };

  const FEED_WINDOW = 8;

  function feedRow(frame) {
    const li = document.createElement("li");
    if (frame.cls) li.className = frame.cls;
    li.innerHTML =
      `<span class="who">${frame.who}</span>` +
      `<span class="act">${frame.act}</span>` +
      `<span class="txt">${frame.txt}</span>`;
    return li;
  }

  function renderLeaderboard(rows) {
    if (!lbBody) return;
    lbBody.replaceChildren(
      ...rows.map(([name, rating], i) => {
        const tr = document.createElement("tr");
        tr.innerHTML = `<td>${i + 1}</td><td>${name}</td><td>${rating}</td>`;
        return tr;
      }),
    );
  }

  let feedPlayer = null;

  function initFeed(domainKey) {
    if (!feedList) return null;
    const domain = DOMAINS[domainKey];
    if (!domain) return null;

    if (arenaTitle) arenaTitle.textContent = domain.title;
    renderLeaderboard(domain.leaderboard);

    if (prefersReducedMotion()) {
      feedList.classList.add("is-static");
      feedList.replaceChildren(...domain.frames.map(feedRow));
      return null;
    }

    feedList.classList.remove("is-static");
    feedList.replaceChildren();
    return createPlayer({
      root: feedList.closest(".panel--arena") || feedList,
      frames: domain.frames,
      apply(frame) {
        feedList.append(feedRow(frame));
        while (feedList.children.length > FEED_WINDOW) {
          feedList.firstElementChild.remove();
        }
      },
      reset() {
        feedList.replaceChildren();
      },
      onCycleEnd: 2400,
    });
  }

  function selectDomain(pill) {
    domainPills.forEach((item) => {
      const selected = item === pill;
      item.classList.toggle("is-active", selected);
      item.setAttribute("aria-selected", String(selected));
      item.tabIndex = selected ? 0 : -1;
    });
    if (feedPlayer) feedPlayer.destroy();
    feedPlayer = initFeed(pill.dataset.domain);
  }

  wireTablist(domainPills, selectDomain);

  let heroPlayer = initHero();
  feedPlayer = initFeed("werewolf");

  const onMotionChange = () => {
    if (heroPlayer) heroPlayer.destroy();
    if (feedPlayer) feedPlayer.destroy();
    heroPlayer = initHero();
    const active = domainPills.find((p) => p.classList.contains("is-active"));
    feedPlayer = initFeed(active ? active.dataset.domain : "werewolf");
  };

  if (typeof motionQuery.addEventListener === "function") {
    motionQuery.addEventListener("change", onMotionChange);
  } else if (typeof motionQuery.addListener === "function") {
    motionQuery.addListener(onMotionChange);
  }
})();
