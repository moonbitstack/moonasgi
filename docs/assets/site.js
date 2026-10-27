// moonasgi docs — theme, search, code tinting, table of contents, and the
// event-timeline player. No dependencies.

(() => {
  "use strict";

  const root = document.documentElement;
  const $ = (sel, scope = document) => scope.querySelector(sel);
  const $$ = (sel, scope = document) => [...scope.querySelectorAll(sel)];

  const ICON = {
    sun: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"><circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M19.1 4.9l-1.4 1.4M6.3 17.7l-1.4 1.4"/></svg>',
    moon: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"><path d="M20 14.5A8.5 8.5 0 0 1 9.5 4a8.5 8.5 0 1 0 10.5 10.5Z"/></svg>',
  };

  /* ---------- theme ---------- */

  const stored = localStorage.getItem("moonasgi-theme");
  if (stored === "light" || stored === "dark") root.setAttribute("data-theme", stored);

  const themeBtn = $("#theme-toggle");
  const paintThemeButton = () => {
    if (!themeBtn) return;
    const dark = root.getAttribute("data-theme") === "dark" ||
      (!root.hasAttribute("data-theme") && matchMedia("(prefers-color-scheme: dark)").matches);
    themeBtn.innerHTML = dark ? ICON.sun : ICON.moon;
    themeBtn.setAttribute("aria-label", dark ? "Switch to the light theme" : "Switch to the dark theme");
  };

  if (themeBtn) {
    paintThemeButton();
    themeBtn.addEventListener("click", () => {
      const dark = root.getAttribute("data-theme") === "dark" ||
        (!root.hasAttribute("data-theme") && matchMedia("(prefers-color-scheme: dark)").matches);
      const next = dark ? "light" : "dark";
      root.setAttribute("data-theme", next);
      localStorage.setItem("moonasgi-theme", next);
      paintThemeButton();
    });
  }

  /* ---------- mobile sidebar ---------- */

  const sidebar = $(".sidebar");
  const menuBtn = $("#menu-toggle");
  if (menuBtn && sidebar) {
    menuBtn.addEventListener("click", () => {
      const open = sidebar.classList.toggle("open");
      menuBtn.setAttribute("aria-expanded", String(open));
    });
    sidebar.addEventListener("click", e => {
      if (e.target.closest("a")) sidebar.classList.remove("open");
    });
  }

  /* ---------- copy buttons ---------- */

  document.addEventListener("click", async e => {
    const btn = e.target.closest(".copy, [data-copy]");
    if (!btn) return;
    let text = btn.getAttribute("data-copy");
    if (!text) {
      const host = btn.closest(".code, .install");
      const pre = host && host.querySelector("pre, code");
      text = pre ? pre.textContent : "";
    }
    try {
      await navigator.clipboard.writeText(text.trim());
      const was = btn.textContent;
      btn.textContent = "copied";
      btn.classList.add("ok");
      setTimeout(() => { btn.textContent = was; btn.classList.remove("ok"); }, 1200);
    } catch {
      btn.textContent = "press ⌘C";
    }
  });

  /* ---------- code tinting ---------- */

  const KEYWORDS = new Set([
    "pub", "fn", "let", "type", "struct", "enum", "trait", "impl", "match", "if", "else",
    "guard", "for", "in", "while", "return", "async", "raise", "try", "catch", "using",
    "const", "mut", "priv", "test", "break", "continue", "derive", "and", "or", "not",
    "extern", "with", "is", "as", "True", "False", "None", "Some", "Ok", "Err",
  ]);

  const esc = s => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

  function tint(src) {
    let out = "";
    let i = 0;
    const emit = (cls, text) => {
      out += cls ? `<span class="t-${cls}">${esc(text)}</span>` : esc(text);
    };
    while (i < src.length) {
      const rest = src.slice(i);
      let m;
      if ((m = /^\/\/[^\n]*/.exec(rest))) { emit("c", m[0]); i += m[0].length; continue; }
      if ((m = /^"(?:[^"\\\n]|\\.)*"/.exec(rest))) { emit("s", m[0]); i += m[0].length; continue; }
      if ((m = /^\b\d[\d_]*(?:\.\d+)?\b/.exec(rest))) { emit("n", m[0]); i += m[0].length; continue; }
      if ((m = /^[A-Za-z_][A-Za-z0-9_]*/.exec(rest))) {
        const w = m[0];
        if (KEYWORDS.has(w)) emit("k", w);
        else if (/^[A-Z]/.test(w)) emit("t", w);
        else if (src[i + w.length] === "(") emit("f", w);
        else emit(null, w);
        i += w.length;
        continue;
      }
      if ((m = /^[^\w"/]+/.exec(rest))) { emit("p", m[0]); i += m[0].length; continue; }
      emit(null, src[i]);
      i += 1;
    }
    return out;
  }

  $$("pre[data-lang='moonbit']").forEach(pre => {
    pre.innerHTML = tint(pre.textContent);
  });

  /* ---------- table of contents ---------- */

  const toc = $("#toc");
  const page = $(".page");
  if (toc && page) {
    const heads = $$("h2[id], h3[id]", page).filter(h => !h.closest(".stage"));
    if (heads.length) {
      toc.innerHTML = '<div class="toc-title">On this page</div>' + heads.map(h => {
        const clean = h.cloneNode(true);
        clean.querySelectorAll(".kind").forEach(n => n.remove());
        let label = clean.textContent.replace("#", "").trim();
        const pkg = h.closest(".pkg");
        if (pkg && h.tagName === "H3") {
          const name = pkg.querySelector("h2").textContent.trim().split("/").pop();
          label = name + " · " + label;
        }
        return `<a class="lvl${h.tagName[1]}" href="#${h.id}">${esc(label)}</a>`;
      }).join("");
      const links = $$("a", toc);
      const byId = new Map(links.map(a => [a.getAttribute("href").slice(1), a]));
      const spy = new IntersectionObserver(entries => {
        entries.forEach(entry => {
          if (!entry.isIntersecting) return;
          links.forEach(a => a.classList.remove("active"));
          const a = byId.get(entry.target.id);
          if (a) a.classList.add("active");
        });
      }, { rootMargin: "-8% 0px -76% 0px" });
      heads.forEach(h => spy.observe(h));
    }
  }

  /* ---------- search ---------- */

  const dialog = $("#search");
  const input = $("#search-input");
  const list = $("#search-results");
  let index = null;

  async function loadIndex() {
    if (index) return index;
    try {
      const res = await fetch("assets/search.json", { cache: "no-cache" });
      index = await res.json();
    } catch {
      index = [];
    }
    return index;
  }

  function renderResults(items, query) {
    if (!items.length) {
      list.innerHTML = `<li class="empty">Nothing matches “${esc(query)}”.</li>`;
      return;
    }
    list.innerHTML = items.map((item, i) => `
      <li><a href="${item.href}" data-i="${i}" ${i === 0 ? 'aria-selected="true"' : ""}>
        <span class="what">${esc(item.name)}</span>
        ${item.kind ? `<span class="kind k-${item.kind}">${item.kind}</span>` : ""}
        <span class="where">${esc(item.where || "")}</span>
      </a></li>`).join("");
  }

  async function search(query) {
    const items = await loadIndex();
    const q = query.trim().toLowerCase();
    if (!q) {
      renderResults(items.slice(0, 8), "");
      return;
    }
    const scored = items
      .map(item => {
        const name = item.name.toLowerCase();
        let score = 0;
        if (name === q) score = 100;
        else if (name.startsWith(q)) score = 70;
        else if (name.includes(q)) score = 45;
        else if ((item.where || "").toLowerCase().includes(q)) score = 20;
        else if ((item.words || "").toLowerCase().includes(q)) score = 10;
        return { item, score };
      })
      .filter(s => s.score > 0)
      .sort((a, b) => b.score - a.score)
      .slice(0, 14)
      .map(s => s.item);
    renderResults(scored, query);
  }

  function openSearch() {
    if (!dialog) return;
    dialog.hidden = false;
    input.value = "";
    input.focus();
    search("");
  }

  function closeSearch() {
    if (!dialog) return;
    dialog.hidden = true;
  }

  if (dialog) {
    $$("[data-open-search]").forEach(b => b.addEventListener("click", openSearch));
    dialog.addEventListener("click", e => { if (e.target === dialog) closeSearch(); });
    input.addEventListener("input", () => search(input.value));
    dialog.addEventListener("keydown", e => {
      if (e.key === "Escape") { closeSearch(); return; }
      const links = $$("a", list);
      const at = links.findIndex(a => a.getAttribute("aria-selected") === "true");
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault();
        if (!links.length) return;
        const next = e.key === "ArrowDown" ? Math.min(at + 1, links.length - 1) : Math.max(at - 1, 0);
        links.forEach(a => a.removeAttribute("aria-selected"));
        links[next].setAttribute("aria-selected", "true");
        links[next].scrollIntoView({ block: "nearest" });
      }
      if (e.key === "Enter") {
        e.preventDefault();
        const active = links.find(a => a.getAttribute("aria-selected") === "true") || links[0];
        if (active) location.href = active.getAttribute("href");
      }
    });
    document.addEventListener("keydown", e => {
      const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName);
      if ((e.key === "/" && !typing) || ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k")) {
        e.preventDefault();
        openSearch();
      }
      if (e.key === "Escape" && !dialog.hidden) closeSearch();
    });
  }

  /* ---------- event timeline ---------- */

  const stage = $("#stage");
  if (stage) initTimeline(stage);

  async function initTimeline(stage) {
    const picker = $("#picker");
    const player = $("#player");
    let data;
    try {
      const res = await fetch("assets/traces.json", { cache: "no-cache" });
      data = await res.json();
    } catch {
      player.innerHTML = '<p class="player-blurb">The recorded traces could not be loaded. Run <code>moon run src/examples/18-trace</code> to make them.</p>';
      return;
    }

    const scenarios = data.scenarios || [];
    let at = -1;
    let timer = null;

    picker.innerHTML = scenarios.map((s, i) =>
      `<button type="button" data-scenario="${i}">
        ${esc(s.title)}<span class="req">${esc(s.request)}</span>
      </button>`).join("");

    const title = $("#player-title");
    const req = $("#player-req");
    const blurb = $("#player-blurb");
    const timeline = $("#timeline");
    const counter = $("#counter");
    const result = $("#result");
    const prev = $("#prev");
    const next = $("#next");
    const play = $("#play-btn");

    function paint() {
      const s = scenarios[at];
      $$("button", picker).forEach((b, i) => b.setAttribute("aria-pressed", String(i === at)));
      if (!s) return;
      title.textContent = s.title;
      req.textContent = s.request;
      blurb.textContent = s.blurb;
      timeline.innerHTML = "";
      counter.textContent = `0 / ${s.steps.length}`;
      result.hidden = true;
      prev.disabled = true;
      next.disabled = false;
      play.disabled = false;
      play.dataset.state = "idle";
      play.textContent = "Play";
      timeline.dataset.shown = "0";
    }

    function reveal(count) {
      const s = scenarios[at];
      timeline.innerHTML = "";
      s.steps.slice(0, count).forEach((step, i) => {
        const el = document.createElement("div");
        el.className = "ev";
        el.dataset.lane = step.lane;
        el.style.animationDelay = "0ms";
        el.innerHTML = `
          <span class="when">${String(i + 1).padStart(2, "0")}</span>
          <div class="what">
            <span class="name"><span class="lane-badge">${esc(step.lane)}</span>${esc(step.title)}</span>
            ${step.body ? `<span class="detail">${esc(step.body)}</span>` : ""}
            ${step.note ? `<span class="why">${esc(step.note)}</span>` : ""}
          </div>`;
        timeline.appendChild(el);
      });
      counter.textContent = `${count} / ${s.steps.length}`;
      const done = count >= s.steps.length;
      result.hidden = !done;
      if (done) result.innerHTML = `<span class="ok">✓</span><span>${esc(s.result)}</span>`;
      prev.disabled = count === 0;
      next.disabled = done;
      if (done) stop();
    }

    const shown = () => Number(timeline.dataset.shown || 0);

    function step(delta) {
      const s = scenarios[at];
      if (!s) return;
      const count = Math.min(s.steps.length, Math.max(0, shown() + delta));
      timeline.dataset.shown = String(count);
      reveal(count);
    }

    function stop() {
      if (timer) clearInterval(timer);
      timer = null;
      play.dataset.state = "idle";
      play.textContent = "Play";
    }

    function start() {
      const s = scenarios[at];
      if (!s) return;
      if (shown() >= s.steps.length) step(-s.steps.length);
      play.dataset.state = "playing";
      play.textContent = "Pause";
      timer = setInterval(() => {
        const total = scenarios[at].steps.length;
        if (shown() >= total) { stop(); return; }
        step(1);
      }, 780);
    }

    function pick(i) {
      stop();
      at = i;
      paint();
      const s = scenarios[at];
      timeline.dataset.shown = String(s.steps.length);
      reveal(s.steps.length);
    }

    picker.addEventListener("click", e => {
      const b = e.target.closest("button[data-scenario]");
      if (b) pick(Number(b.dataset.scenario));
    });

    next.addEventListener("click", () => step(1));
    prev.addEventListener("click", () => step(-1));
    play.addEventListener("click", () => (timer ? stop() : start()));

    document.addEventListener("keydown", e => {
      if (/^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName)) return;
      if (e.key === "ArrowRight") { e.preventDefault(); step(1); }
      if (e.key === "ArrowLeft") { e.preventDefault(); step(-1); }
    });

    paint();
    pick(0);
  }

})();
