const API_BASE_URL = "http://100.92.146.101:8000";
const POLL_MS = 5000;
const APP_JS_VERSION = "trends-2026-06-07";

console.info(`Personal Cloud Downloader app.js ${APP_JS_VERSION}`);

const magnetLinkInput = document.querySelector("#magnetLink");
const addMagnetButton = document.querySelector("#addMagnetButton");
const refreshButton = document.querySelector("#refreshButton");
const torrentList = document.querySelector("#torrentList");
const completedFiles = document.querySelector("#completedFiles");
const statusText = document.querySelector("#status");
const lastUpdated = document.querySelector("#lastUpdated");

let cachedTorrents = [];
let completedFileSnapshot = [];
let isSubmitting = false;
let isRefreshing = false;
let pendingDeleteHash = "";
let trendsState = {
  loaded: false,
  loading: false,
  error: "",
  data: null,
};

function setStatus(message, isError = false) {
  statusText.textContent = message;
  statusText.classList.toggle("error", isError);
}

async function apiFetch(path, options = {}) {
  const method = (options.method || "GET").toUpperCase();
  const requestPath = method === "GET"
    ? `${path}${path.includes("?") ? "&" : "?"}t=${Date.now()}`
    : path;

  const response = await fetch(`${API_BASE_URL}${requestPath}`, {
    ...options,
    cache: "no-store",
    headers: {
      "content-type": "application/json",
      ...(options.headers || {}),
    },
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(body || `Request failed: ${response.status}`);
  }

  if (response.status === 204) return null;
  return response.json();
}

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>"']/g, (char) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  })[char]);
}

function normalizeProgress(torrent) {
  const raw = torrent.progress_percent ?? torrent.progress ?? 0;
  const percent = raw <= 1 ? raw * 100 : raw;
  return Math.max(0, Math.min(100, Math.round(percent)));
}

function normalizeStatus(torrent) {
  const raw = String(torrent.status ?? torrent.state ?? "").toLowerCase();
  const progress = normalizeProgress(torrent);

  if (torrent.is_complete || progress >= 100 || raw.includes("complete")) return "Completed";
  if (raw.includes("error") || raw.includes("fail") || raw.includes("missing")) return "Failed";
  if (raw.includes("downloading") || raw.includes("download") || progress > 0) return "Downloading";
  return "Waiting";
}

function statusClass(status) {
  return status.toLowerCase();
}

function formatDateTime(value) {
  if (!value) return "Time unavailable.";

  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "Time unavailable.";

  return date.toLocaleString([], {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

function torrentTimeText(torrent, status) {
  if (status === "Completed") {
    return torrent.completed_at
      ? `Completed ${formatDateTime(torrent.completed_at)}`
      : "Time unavailable.";
  }

  return torrent.added_at
    ? `Added ${formatDateTime(torrent.added_at)}`
    : "Time unavailable.";
}

function emptyCard(title, text) {
  return `
    <article class="empty-card">
      <h3>${escapeHtml(title)}</h3>
      <p class="empty">${escapeHtml(text)}</p>
    </article>
  `;
}

function installTrendsHomeEntry() {
  installTrendsStyles();

  if (document.querySelector("#trendsHomeEntry")) return;

  const entry = document.createElement("section");
  entry.id = "trendsHomeEntry";
  entry.className = "trends-home-entry";
  entry.innerHTML = `
    <div class="trends-entry-copy">
      <p class="trends-kicker">TMDB trends</p>
      <h2>Browse what is rising now</h2>
      <p>Movies and series from global and India shelves, with ratings visible before you open anything.</p>
    </div>
    <button class="trends-open-button" type="button" data-open-trends>
      Open Trends
    </button>
  `;

  const anchor = completedFiles.closest("section") || torrentList.closest("section") || document.body.firstElementChild;
  if (anchor?.parentNode) {
    anchor.parentNode.insertBefore(entry, anchor);
  } else {
    document.body.appendChild(entry);
  }

  entry.addEventListener("click", (event) => {
    const button = event.target.closest("[data-open-trends]");
    if (!button) return;
    openTrendsView();
  });
}

function installTrendsStyles() {
  if (document.querySelector("#trendsStyles")) return;

  const styles = document.createElement("style");
  styles.id = "trendsStyles";
  styles.textContent = `
    .trends-home-entry {
      display: grid;
      grid-template-columns: 1fr auto;
      gap: 18px;
      align-items: center;
      margin: 22px 0;
      padding: 20px;
      border: 1px solid rgba(245, 245, 239, .12);
      border-radius: 18px;
      background: color-mix(in srgb, #111827 88%, #2dd4bf 12%);
      box-shadow: 0 18px 55px rgba(0, 0, 0, .22);
    }
    .trends-entry-copy h2 {
      margin: 4px 0 8px;
      color: #f5f5ef;
      font-size: clamp(1.25rem, 2.4vw, 1.9rem);
      letter-spacing: 0;
    }
    .trends-entry-copy p {
      margin: 0;
      color: rgba(245, 245, 239, .72);
      line-height: 1.45;
      max-width: 58ch;
    }
    .trends-kicker {
      color: #5eead4 !important;
      font-size: .78rem;
      font-weight: 700;
      letter-spacing: .08em;
      text-transform: uppercase;
    }
    .trends-open-button,
    .trends-back-button,
    .trailer-button {
      min-height: 42px;
      border: 1px solid rgba(245, 245, 239, .14);
      border-radius: 999px;
      background: #f5f5ef;
      color: #111827;
      font-weight: 750;
      padding: 0 16px;
      cursor: pointer;
      transition: transform 180ms ease, border-color 180ms ease, background 180ms ease;
      text-decoration: none;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      white-space: nowrap;
    }
    .trends-open-button:hover,
    .trends-back-button:hover,
    .trailer-button:hover {
      transform: translateY(-1px);
      border-color: rgba(94, 234, 212, .55);
    }
    .trends-view {
      margin: 24px 0;
      padding: 22px;
      border: 1px solid rgba(245, 245, 239, .10);
      border-radius: 22px;
      background: #0f1724;
      color: #f5f5ef;
    }
    .trends-view[hidden] {
      display: none;
    }
    .trends-header {
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      gap: 16px;
      margin-bottom: 22px;
    }
    .trends-header h2 {
      margin: 0 0 8px;
      font-size: clamp(1.6rem, 4vw, 2.6rem);
      letter-spacing: 0;
    }
    .trends-header p,
    .trends-updated,
    .trend-meta,
    .trend-empty,
    .trend-message {
      color: rgba(245, 245, 239, .68);
    }
    .trends-back-button {
      background: transparent;
      color: #f5f5ef;
    }
    .trends-sections {
      display: grid;
      gap: 30px;
    }
    .trend-section-header {
      display: flex;
      align-items: baseline;
      justify-content: space-between;
      gap: 12px;
      margin-bottom: 14px;
    }
    .trend-section-header h3 {
      margin: 0;
      font-size: 1.12rem;
      letter-spacing: 0;
    }
    .trend-count {
      color: rgba(245, 245, 239, .48);
      font-size: .85rem;
    }
    .trend-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(142px, 1fr));
      gap: 16px;
    }
    .trend-card {
      min-width: 0;
      border: 1px solid rgba(245, 245, 239, .10);
      border-radius: 14px;
      background: #141e2d;
      overflow: hidden;
      transition: transform 180ms ease, border-color 180ms ease, background 180ms ease;
    }
    .trend-card:hover {
      transform: translateY(-3px);
      border-color: rgba(94, 234, 212, .34);
      background: #172235;
    }
    .trend-poster,
    .trend-placeholder {
      width: 100%;
      aspect-ratio: 2 / 3;
      display: block;
      object-fit: cover;
      background: #1d293b;
    }
    .trend-placeholder {
      display: grid;
      place-items: center;
      color: rgba(245, 245, 239, .46);
      font-weight: 750;
      text-align: center;
      padding: 12px;
    }
    .trend-card-body {
      display: grid;
      gap: 8px;
      padding: 12px;
    }
    .trend-card h4 {
      margin: 0;
      font-size: .95rem;
      line-height: 1.25;
      letter-spacing: 0;
      overflow-wrap: anywhere;
    }
    .trend-meta-row {
      display: flex;
      flex-wrap: wrap;
      gap: 8px;
      align-items: center;
      justify-content: space-between;
    }
    .trend-rating {
      color: #f8d66d;
      font-weight: 800;
    }
    .trailer-button {
      min-height: 34px;
      width: 100%;
      background: transparent;
      color: #f5f5ef;
      border-radius: 10px;
    }
    .trend-message {
      padding: 20px;
      border: 1px solid rgba(245, 245, 239, .10);
      border-radius: 14px;
      background: #141e2d;
    }
    @media (max-width: 720px) {
      .trends-home-entry,
      .trends-header,
      .trend-section-header {
        grid-template-columns: 1fr;
        display: grid;
      }
      .trends-open-button,
      .trends-back-button {
        width: 100%;
      }
      .trends-view {
        padding: 16px;
      }
      .trend-grid {
        grid-template-columns: repeat(2, minmax(0, 1fr));
        gap: 12px;
      }
    }
  `;
  document.head.appendChild(styles);
}

function openTrendsView() {
  let view = document.querySelector("#trendsView");
  if (!view) {
    view = document.createElement("section");
    view.id = "trendsView";
    view.className = "trends-view";
    view.hidden = true;
    view.innerHTML = `
      <div class="trends-header">
        <div>
          <p class="trends-kicker">TMDB metadata only</p>
          <h2>Trends</h2>
          <p>Global and India shelves from TMDB, updated by the server script.</p>
          <p class="trends-updated" data-trends-updated></p>
        </div>
        <button class="trends-back-button" type="button" data-close-trends>Back home</button>
      </div>
      <div class="trends-content" data-trends-content></div>
    `;
    const entry = document.querySelector("#trendsHomeEntry");
    if (entry?.parentNode) {
      entry.parentNode.insertBefore(view, entry.nextSibling);
    } else {
      document.body.appendChild(view);
    }
    view.addEventListener("click", (event) => {
      if (event.target.closest("[data-close-trends]")) {
        closeTrendsView();
      }
    });
  }

  view.hidden = false;
  view.scrollIntoView({ behavior: "smooth", block: "start" });
  loadTrends();
}

function closeTrendsView() {
  const view = document.querySelector("#trendsView");
  if (view) view.hidden = true;
  document.querySelector("#trendsHomeEntry")?.scrollIntoView({ behavior: "smooth", block: "center" });
}

async function loadTrends() {
  if (trendsState.loading) return;
  if (trendsState.loaded) {
    renderTrendsView();
    return;
  }

  trendsState.loading = true;
  trendsState.error = "";
  renderTrendsView();

  try {
    const data = await apiFetch("/api/trends");
    if (data?.error) throw new Error(data.error);
    trendsState.data = data;
    trendsState.loaded = true;
  } catch (error) {
    trendsState.error = error.message || "data not available";
  } finally {
    trendsState.loading = false;
    renderTrendsView();
  }
}

function renderTrendsView() {
  const content = document.querySelector("[data-trends-content]");
  const updated = document.querySelector("[data-trends-updated]");
  if (!content) return;

  if (trendsState.loading) {
    updated.textContent = "";
    content.innerHTML = `<div class="trend-message">Loading TMDB trends...</div>`;
    return;
  }

  if (trendsState.error) {
    updated.textContent = "";
    content.innerHTML = `<div class="trend-message">Trends unavailable. ${escapeHtml(trendsState.error)}</div>`;
    return;
  }

  const data = trendsState.data || {};
  updated.textContent = data.updated_at ? `Updated ${formatDateTime(data.updated_at)}` : "";
  content.innerHTML = `
    <div class="trends-sections">
      ${renderTrendSection("Global Movies", data.global_movies)}
      ${renderTrendSection("Global Series", data.global_series)}
      ${renderTrendSection("India Movies", data.india_movies)}
      ${renderTrendSection("India Series", data.india_series)}
    </div>
  `;
}

function renderTrendSection(title, items) {
  const safeItems = Array.isArray(items) ? items : [];
  return `
    <section class="trend-section">
      <div class="trend-section-header">
        <h3>${escapeHtml(title)}</h3>
        <span class="trend-count">${safeItems.length} titles</span>
      </div>
      ${safeItems.length
        ? `<div class="trend-grid">${safeItems.map(renderTrendCard).join("")}</div>`
        : `<p class="trend-empty">No titles available.</p>`}
    </section>
  `;
}

function renderTrendCard(item) {
  const title = item?.title || "Untitled";
  const poster = item?.poster_url
    ? `<img class="trend-poster" src="${escapeHtml(item.poster_url)}" alt="${escapeHtml(title)} poster" loading="lazy">`
    : `<div class="trend-placeholder" aria-label="No poster available">No poster</div>`;
  const rating = formatTrendRating(item?.rating);
  const releaseYear = item?.release_year || "Year N/A";
  const trailer = item?.trailer_url
    ? `<a class="trailer-button" href="${escapeHtml(item.trailer_url)}" target="_blank" rel="noreferrer">Trailer</a>`
    : "";

  return `
    <article class="trend-card">
      ${poster}
      <div class="trend-card-body">
        <h4>${escapeHtml(title)}</h4>
        <div class="trend-meta-row">
          <span class="trend-rating">${escapeHtml(rating)}</span>
          <span class="trend-meta">${escapeHtml(releaseYear)}</span>
        </div>
        ${trailer}
      </div>
    </article>
  `;
}

function formatTrendRating(value) {
  const rating = Number(value);
  if (!Number.isFinite(rating)) return "N/A";
  return `TMDB ${rating.toFixed(1)}`;
}

function renderTorrents(torrents) {
  if (!torrents.length) {
    torrentList.innerHTML = emptyCard("Queue is clear", "Paste a magnet link when you want the server to do the waiting.");
    cachedTorrents = torrents;
    return;
  }

  const sortedTorrents = sortTorrentsForDisplay(torrents);

  torrentList.style.flexDirection = "column";
  torrentList.innerHTML = sortedTorrents.map((torrent, index) => {
    const status = normalizeStatus(torrent);
    const progress = normalizeProgress(torrent);
    const name = torrent.name || torrent.hash || "Preparing download";
    const timeText = torrentTimeText(torrent, status);

    return `
      <article class="download-card" style="order: ${index}">
        <div class="card-top">
          <div class="download-title">
            <h3>${escapeHtml(name)}</h3>
            <p class="meta">${progress}% downloaded</p>
            <p class="meta">${escapeHtml(timeText)}</p>
          </div>
          <span class="pill ${statusClass(status)}">${status}</span>
        </div>
        <div class="progress-row" aria-label="${progress}% complete">
          <div class="progress-track">
            <div class="progress-fill" style="--progress: ${progress}%"></div>
          </div>
          <span class="progress-value">${progress}%</span>
        </div>
        <div class="actions">
          <button class="action-button danger" type="button" data-delete-hash="${escapeHtml(torrent.hash)}">
            Delete torrent/files
          </button>
        </div>
      </article>
    `;
  }).join("");

  cachedTorrents = sortedTorrents;
}

function sortTorrentsForDisplay(torrents) {
  return torrents
    .map((torrent, index) => ({ torrent, index }))
    .sort(compareTorrentOrder)
    .map((entry) => entry.torrent);
}

function compareTorrentOrder(leftEntry, rightEntry) {
  const left = leftEntry.torrent;
  const right = rightEntry.torrent;
  const leftActive = isCurrentTorrent(left);
  const rightActive = isCurrentTorrent(right);

  if (leftActive !== rightActive) {
    return leftActive ? -1 : 1;
  }

  const timeOrder = torrentTimestamp(right) - torrentTimestamp(left);
  if (timeOrder !== 0) return timeOrder;

  return rightEntry.index - leftEntry.index;
}

function isCurrentTorrent(torrent) {
  const status = normalizeStatus(torrent);
  return status !== "Completed" && status !== "Failed";
}

function torrentTimestamp(torrent) {
  const timestamp = Date.parse(torrent.added_at || torrent.completed_at || torrent.created_at || torrent.updated_at || "");
  return Number.isNaN(timestamp) ? 0 : timestamp;
}

function fileUrl(file) {
  return file.url || file.stream_url || file.download_url || "";
}

function fileName(file) {
  return file.name || file.path || file.filename || "Completed file";
}

function renderCompletedFiles(files) {
  completedFileSnapshot = Array.isArray(files) ? files : [];

  if (!completedFileSnapshot.length) {
    completedFiles.innerHTML = emptyCard("Nothing ready yet", "Completed files will collect here with stream, download, and VLC links.");
    return;
  }

  completedFiles.innerHTML = completedFileSnapshot.map((file, index) => {
    const url = fileUrl(file);
    const name = fileName(file);
    const safeUrl = escapeHtml(url);
    const timeText = file.modified_at
      ? `Modified ${formatDateTime(file.modified_at)}`
      : "Time unavailable.";

    return `
      <article class="file-card">
        <div class="file-title">
          <h3 class="file-name">${escapeHtml(name)}</h3>
          <p class="meta">${escapeHtml(timeText)}</p>
        </div>
        <div class="actions">
          <a class="action-button" href="${safeUrl}" target="_blank" rel="noreferrer">Stream</a>
          <a class="action-button" href="${safeUrl}" download>Download</a>
          <button class="action-button" type="button" data-copy-index="${index}">Copy VLC link</button>
        </div>
      </article>
    `;
  }).join("");
}

async function addMagnet() {
  const magnet = magnetLinkInput.value.trim();
  if (!magnet) {
    setStatus("Paste a magnet link first.", true);
    magnetLinkInput.focus();
    return;
  }

  isSubmitting = true;
  addMagnetButton.disabled = true;
  addMagnetButton.textContent = "Starting...";
  setStatus("Sending magnet to private backend...");

  try {
    await apiFetch("/api/add-magnet", {
      method: "POST",
      body: JSON.stringify({ magnet }),
    });
    magnetLinkInput.value = "";
    setStatus("Download started. Status updates automatically.");
    await refreshAll({ quiet: true });
  } finally {
    isSubmitting = false;
    addMagnetButton.disabled = false;
    addMagnetButton.textContent = "Start download";
  }
}

async function deleteTorrent(hash) {
  if (!hash) return;
  setStatus("Deleting torrent and files...");
  await apiFetch(`/api/torrents/${encodeURIComponent(hash)}`, { method: "DELETE" });
  cachedTorrents = cachedTorrents.filter((torrent) => torrent.hash !== hash);
  renderCompletedFiles([]);
  setStatus("Torrent and files deleted.");
  await refreshAll({ quiet: true });
}

function showDeleteConfirmation(hash) {
  const torrent = cachedTorrents.find((item) => item.hash === hash);
  const name = torrent?.name || hash || "this download";
  pendingDeleteHash = hash;

  let modal = document.querySelector("#deleteConfirmModal");
  if (!modal) {
    modal = document.createElement("div");
    modal.id = "deleteConfirmModal";
    modal.innerHTML = `
      <div style="position:fixed;inset:0;background:rgba(0,0,0,.45);z-index:9998;"></div>
      <section role="dialog" aria-modal="true" aria-labelledby="deleteConfirmTitle" style="position:fixed;left:50%;top:50%;transform:translate(-50%,-50%);z-index:9999;width:min(92vw,420px);background:#111827;color:white;border:1px solid rgba(255,255,255,.16);border-radius:14px;padding:18px;box-shadow:0 18px 60px rgba(0,0,0,.45);">
        <h3 id="deleteConfirmTitle" style="margin:0 0 8px;font-size:18px;">Delete download?</h3>
        <p id="deleteConfirmName" style="margin:0 0 16px;color:#d1d5db;line-height:1.35;word-break:break-word;"></p>
        <div style="display:flex;gap:10px;justify-content:flex-end;">
          <button type="button" data-delete-cancel style="border:1px solid rgba(255,255,255,.18);background:transparent;color:white;border-radius:10px;padding:10px 14px;">Cancel</button>
          <button type="button" data-delete-confirm style="border:0;background:#dc2626;color:white;border-radius:10px;padding:10px 14px;">Delete</button>
        </div>
      </section>
    `;
    document.body.appendChild(modal);
    modal.addEventListener("click", handleDeleteConfirmationClick);
  }

  modal.querySelector("#deleteConfirmName").textContent = `${name} and its files will be deleted.`;
  modal.hidden = false;
}

function hideDeleteConfirmation() {
  const modal = document.querySelector("#deleteConfirmModal");
  if (modal) modal.hidden = true;
  pendingDeleteHash = "";
}

function handleDeleteConfirmationClick(event) {
  if (event.target.closest("[data-delete-cancel]")) {
    hideDeleteConfirmation();
    return;
  }

  if (event.target.closest("[data-delete-confirm]")) {
    const hash = pendingDeleteHash;
    hideDeleteConfirmation();
    deleteTorrent(hash).catch((error) => setStatus(error.message, true));
  }
}

async function copyVlcLink(index) {
  const fileCards = [...completedFiles.querySelectorAll("[data-copy-index]")];
  const button = fileCards.find((item) => Number(item.dataset.copyIndex) === index);
  const file = completedFileSnapshot[index];
  const url = fileUrl(file);

  if (!url) {
    setStatus("No link available for this file.", true);
    return;
  }

  const copied = await copyText(url);
  if (!copied) {
    setStatus("Copy failed. Long press the link to copy.", true);
    return;
  }

  if (button) button.textContent = "Copied";
  setStatus("VLC link copied.");
  window.setTimeout(() => {
    if (button) button.textContent = "Copy VLC link";
  }, 1400);
}

async function copyText(text) {
  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(text);
      return true;
    } catch {
      // Fall through to legacy copy for HTTP/private-network browsers.
    }
  }

  const textArea = document.createElement("textarea");
  textArea.value = text;
  textArea.setAttribute("readonly", "");
  textArea.style.position = "fixed";
  textArea.style.top = "-1000px";
  textArea.style.left = "-1000px";
  document.body.appendChild(textArea);
  textArea.focus();
  textArea.select();

  try {
    return document.execCommand("copy");
  } catch {
    return false;
  } finally {
    document.body.removeChild(textArea);
  }
}

async function refreshCompletedFiles() {
  const files = await apiFetch("/api/completed-files");
  renderCompletedFiles(Array.isArray(files) ? files : []);
}

async function refreshAll({ quiet = false } = {}) {
  if (isRefreshing || isSubmitting) return;

  isRefreshing = true;
  refreshButton.disabled = true;
  if (!quiet) setStatus("Refreshing private backend...");

  try {
    const [torrents, files] = await Promise.all([
      apiFetch("/api/torrents"),
      apiFetch("/api/completed-files"),
    ]);
    renderTorrents(Array.isArray(torrents) ? torrents : []);
    renderCompletedFiles(Array.isArray(files) ? files : []);
    lastUpdated.textContent = new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
    if (!quiet) setStatus("Ready.");
  } catch (error) {
    setStatus(error.message, true);
  } finally {
    isRefreshing = false;
    refreshButton.disabled = false;
  }
}

addMagnetButton.addEventListener("click", () => addMagnet().catch((error) => setStatus(error.message, true)));
refreshButton.addEventListener("click", () => refreshAll());

magnetLinkInput.addEventListener("keydown", (event) => {
  if ((event.ctrlKey || event.metaKey) && event.key === "Enter") {
    addMagnet().catch((error) => setStatus(error.message, true));
  }
});

torrentList.addEventListener("click", (event) => {
  const button = event.target.closest("[data-delete-hash]");
  if (!button) return;
  showDeleteConfirmation(button.dataset.deleteHash);
});

completedFiles.addEventListener("click", (event) => {
  const button = event.target.closest("[data-copy-index]");
  if (!button) return;
  copyVlcLink(Number(button.dataset.copyIndex)).catch((error) => setStatus(error.message, true));
});

installTrendsHomeEntry();
refreshAll();
window.setInterval(() => refreshAll({ quiet: true }), POLL_MS);
