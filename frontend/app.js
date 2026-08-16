const API_BASE_URL = `http://${window.location.hostname}:8000`;
const POLL_MS = 5000;
const COMPLETED_FILES_POLL_MS = 30000;
const DIRECT_ACTIVE_POLL_MS = 3000;
const DIRECT_IDLE_POLL_MS = 15000;
const TORRENT_STALE_MS = 60 * 1000;
const STATUS_SUCCESS_MS = 4000;
const STATUS_WARNING_MS = 8000;
const TRENDS_REFRESH_MS = 5 * 60 * 1000;
const TRENDS_STALE_MS = 24 * 60 * 60 * 1000;
const APP_JS_VERSION = "cloudbox-theme-2026-06-12";

console.info(`Personal Cloud Downloader app.js ${APP_JS_VERSION}`);

const magnetLinkInput = document.querySelector("#magnetLink");
const addMagnetButton = document.querySelector("#addMagnetButton");
const refreshButton = document.querySelector("#refreshButton");
const torrentList = document.querySelector("#torrentList");
const queueSummary = document.querySelector("#queueSummary");
const completedFiles = document.querySelector("#completedFiles");
const statusText = document.querySelector("#status");
const lastUpdated = document.querySelector("#lastUpdated");

let cachedTorrents = [];
let cachedDirectDownloads = [];
let completedFileSnapshot = [];
let isSubmitting = false;
let isRefreshing = false;
let downloaderDataGeneration = 0;
let lastCompletedFilesRefreshAt = 0;
let lastSuccessfulTorrentRefreshAt = 0;
let statusDismissTimer = 0;
let statusRevision = 0;
let offlineStatusMessage = "";
let isInitialTorrentLoad = true;
let incompleteTorrentHashes = new Set();
let pendingRefreshMode = "";
let pendingDeleteHash = "";
let pendingCompletedDelete = null;
let pendingDirectDeleteId = "";
let isCompletedDeleteActive = false;
let completedDeleteModalOpener = null;
let completedDeleteModalKeydownHandler = null;
let directLinkInput = null;
let composerMode = "magnet";
let originalComposerLabelHtml = "";
let isDirectSubmitting = false;
let isDirectRefreshing = false;
let directRefreshPending = false;
let directDownloadsLoaded = false;
let directPollingError = "";
let directDataGeneration = 0;
let directPollTimer = 0;
let incompleteDirectDownloadIds = new Set();
const activeDirectActionIds = new Set();
let trendsState = {
  loaded: false,
  loading: false,
  error: "",
  data: null,
  lastRefreshAt: 0,
  requestGeneration: 0,
  pendingRefresh: false,
};

function setStatus(message, isError = false) {
  const text = String(message ?? "");
  const isOffline = isError && isConnectivityErrorMessage(text);
  if (
    isOffline
    && !statusText.hidden
    && statusText.textContent === text
    && statusText.classList.contains("offline")
  ) {
    return;
  }

  const revision = ++statusRevision;
  const isWarning = isError
    && !/list refresh failed/i.test(text)
    && /warnings?:|partial|may remain|no completed files were removed|was not removed/i.test(text);

  window.clearTimeout(statusDismissTimer);
  statusDismissTimer = 0;
  statusText.textContent = text;
  statusText.hidden = !text;
  statusText.classList.toggle("warning", isWarning);
  statusText.classList.toggle("error", isError && !isWarning);
  statusText.classList.toggle("offline", isOffline);

  if (!text) return;
  if (isOffline) {
    offlineStatusMessage = text;
    return;
  }

  const dismissAfter = isError || isWarning ? STATUS_WARNING_MS : STATUS_SUCCESS_MS;
  statusDismissTimer = window.setTimeout(() => {
    if (revision !== statusRevision) return;
    if (offlineStatusMessage) {
      setStatus(offlineStatusMessage, true);
    } else {
      setStatus("");
    }
  }, dismissAfter);
}

function isConnectivityErrorMessage(message) {
  return message === "CloudBox server is unreachable" || message === "Server request timed out";
}

function renderInitialTorrentSkeletons() {
  torrentList.innerHTML = Array.from({ length: 2 }, () => `
    <article class="dl-card dl-card--waiting dl-skeleton" aria-hidden="true">
      <div class="dl-skeleton__line dl-skeleton__title"></div>
      <div class="dl-skeleton__line dl-skeleton__bar"></div>
      <div class="dl-skeleton__line dl-skeleton__meta"></div>
    </article>
  `).join("");
}

function finishInitialTorrentLoad() {
  if (!isInitialTorrentLoad) return;
  isInitialTorrentLoad = false;
  torrentList.querySelectorAll(".dl-skeleton").forEach((element) => element.remove());
}

function setTorrentPollingOnline() {
  torrentList.classList.remove("offline");
  if (offlineStatusMessage && statusText.textContent === offlineStatusMessage) {
    setStatus("");
  }
  offlineStatusMessage = "";
}

function normalizeApiError(status, body) {
  const statusFallbacks = {
    400: "Invalid request",
    401: "Request not authorized",
    403: "Request not authorized",
    404: "Requested item was not found",
    409: "Request conflicts with the current state",
    413: "File or request is too large",
    422: "Some request information is invalid",
  };
  const fallback = statusFallbacks[status]
    || (status >= 500 && status <= 599 ? "CloudBox server error" : "Request failed");

  const safeText = (value) => {
    if (typeof value !== "string") return "";
    const text = value.trim();
    if (!text || text.length > 160 || /[\r\n]/.test(text)) return "";
    if (/[<>]/.test(text) || /^[\[{]/.test(text) || /[\]}]$/.test(text)) return "";
    if (/\b(?:traceback|stack trace|stacktrace)\b|(?:^|\s)at\s+\S+\s*\(|\.(?:js|py|swift|java):\d+/i.test(text)) return "";
    if (/(?:^|[\s"'(])(?:[A-Za-z]:\\|\\\\|\/(?:[^/\s"'()]+\/)+[^/\s"'()]+)/.test(text)) return "";
    if (/\b(?:api[_ -]?key|secret|token|password|private[_ -]?key|database[_ -]?url|config(?:uration)?)\b\s*[:=]/i.test(text)) return "";
    if (/\b(?:AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9_-]{16,}|Bearer\s+\S+)/.test(text)) return "";
    if (/-----BEGIN [A-Z ]+-----/.test(text)) return "";
    return text;
  };

  const candidates = [];
  try {
    const parsed = JSON.parse(body);
    if (typeof parsed === "string") {
      candidates.push(parsed);
    } else if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      for (const key of ["detail", "message", "error"]) {
        const value = parsed[key];
        if (typeof value === "string") candidates.push(value);
        if (value && typeof value === "object" && typeof value.message === "string") {
          candidates.push(value.message);
        }
      }
    }

    const validationItems = Array.isArray(parsed)
      ? parsed
      : Array.isArray(parsed?.detail)
        ? parsed.detail
        : [];
    for (const item of validationItems) {
      if (item && typeof item.msg === "string") candidates.push(item.msg);
    }
  } catch {
    candidates.push(body);
  }

  const message = candidates.map(safeText).find(Boolean) || fallback;
  const error = new Error(message);
  error.isApiResponseError = true;
  return error;
}

async function apiFetch(path, options = {}) {
  const method = (options.method || "GET").toUpperCase();
  const requestPath = method === "GET"
    ? `${path}${path.includes("?") ? "&" : "?"}t=${Date.now()}`
    : path;
  const controller = new AbortController();
  const timeoutId = window.setTimeout(() => controller.abort(), 15000);

  try {
    const response = await fetch(`${API_BASE_URL}${requestPath}`, {
      ...options,
      cache: "no-store",
      headers: {
        "content-type": "application/json",
        ...(options.headers || {}),
      },
      signal: controller.signal,
    });

    if (!response.ok) {
      const body = await response.text();
      throw normalizeApiError(response.status, body);
    }

    if (response.status === 204) return null;
    return response.json();
  } catch (error) {
    if (controller.signal.aborted && error?.name === "AbortError") {
      throw new Error("Server request timed out");
    }
    if (error?.isApiResponseError) throw error;
    throw new Error("CloudBox server is unreachable");
  } finally {
    window.clearTimeout(timeoutId);
  }
}

async function fetchTorrents() {
  try {
    return await apiFetch("/api/torrents");
  } catch (error) {
    error.isTorrentPollingFailure = true;
    throw error;
  }
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

function torrentHash(torrent) {
  return String(torrent.hash ?? "").trim().toLowerCase();
}

function torrentDisplayName(torrent, emptyFallback = "Preparing download") {
  const rawHash = String(torrent?.hash ?? "").trim();
  const providedName = String(torrent?.name ?? "").trim();
  const hasUsableName = providedName
    && (!rawHash || providedName.toLowerCase() !== rawHash.toLowerCase());
  if (hasUsableName) return providedName;
  return rawHash ? `Preparing download · ${rawHash.slice(0, 8)}…` : emptyFallback;
}

function hasTorrentCompletionTransition(torrents) {
  return torrents.some((torrent) => {
    const hash = torrentHash(torrent);
    return hash
      && incompleteTorrentHashes.has(hash)
      && normalizeStatus(torrent) === "Completed";
  });
}

function rememberIncompleteTorrents(torrents) {
  incompleteTorrentHashes = new Set(
    torrents
      .filter((torrent) => normalizeStatus(torrent) !== "Completed")
      .map(torrentHash)
      .filter(Boolean),
  );
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

function renderLastUpdated() {
  if (!lastSuccessfulTorrentRefreshAt) return;

  const isStale = Date.now() - lastSuccessfulTorrentRefreshAt > TORRENT_STALE_MS;
  const time = new Date(lastSuccessfulTorrentRefreshAt).toLocaleTimeString([], {
    hour: "2-digit",
    minute: "2-digit",
  });
  lastUpdated.textContent = `Updated ${time}${isStale ? " · stale" : ""}`;
  lastUpdated.classList.toggle("stale", isStale);
}

function emptyCard(title, text) {
  return `
    <article class="empty-card">
      <h3>${escapeHtml(title)}</h3>
      <p class="empty">${escapeHtml(text)}</p>
    </article>
  `;
}

// CloudBox theme, self-contained in app.js (only this file deploys to Oracle).
// Injected AFTER style.css loads, so equal-specificity rules here win the
// cascade and the var-driven base sheet re-skins through :root overrides.
// Visual only — no markup, logic, or API behavior changes.
function installCloudBoxTheme() {
  if (document.querySelector("#cloudboxTheme")) return;

  const styles = document.createElement("style");
  styles.id = "cloudboxTheme";
  styles.textContent = `
    /* ---- CloudBox tokens (mirrors the iOS app palette) ---- */
    :root {
      color-scheme: dark;
      --page: #02060E;
      --ink: #F2F6FF;
      --surface: #091120;
      --surface-strong: rgba(255, 255, 255, .10);
      --panel: #091120;
      --panel-soft: #0E182D;
      --panel-ink: #F2F6FF;
      --line: rgba(255, 255, 255, .08);
      --muted: #8FA3C7;
      --accent: #4D96FF;
      --accent-strong: #6FAAFF;
      --accent-soft: rgba(77, 150, 255, .14);
      --danger: #F87171;
      --danger-soft: rgba(248, 113, 113, .12);
      --ok-soft: rgba(74, 222, 128, .15);
      --wait-soft: rgba(143, 163, 199, .14);
      --radius: 20px;
      --shadow: none;
      background: var(--page);
      color: var(--ink);
    }

    /* Deep navy + ONE corner bloom — same background recipe as the app. */
    body {
      background:
        radial-gradient(circle at 90% -5%, rgba(77, 150, 255, .13), transparent 24rem),
        var(--page);
      color: var(--ink);
      padding-bottom: env(safe-area-inset-bottom);
    }

    /* ---- Top bar ---- */
    .brand-mark {
      background: linear-gradient(135deg, #4D96FF, #123A8C);
      color: #fff;
      border: 1px solid rgba(255, 255, 255, .22);
      box-shadow: 0 10px 26px rgba(77, 150, 255, .30);
    }
    .eyebrow {
      color: var(--accent);
      letter-spacing: .14em;
    }
    h1, h2, h3 {
      color: var(--ink);
    }

    /* ---- Panels: flat raised surfaces, hairline strokes, no glow ---- */
    .command-panel,
    .content-section {
      background: var(--surface);
      border: 1px solid var(--line);
      box-shadow: none;
    }
    .command-panel {
      background: #0E182D;
      border-color: rgba(77, 150, 255, .26);
    }
    .command-panel .section-heading p,
    .command-panel .panel-kicker,
    .command-panel .status-line {
      color: var(--muted);
    }
    .command-panel .panel-kicker {
      color: var(--accent);
    }
    .panel-kicker {
      color: var(--accent);
      letter-spacing: .14em;
    }

    /* ---- Magnet input: technical, monospaced ---- */
    textarea {
      background: #060D1C;
      border: 1px solid var(--line);
      color: var(--ink);
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      font-size: .88rem;
    }
    textarea::placeholder {
      color: rgba(143, 163, 199, .55);
    }
    textarea:focus {
      border-color: var(--accent);
      box-shadow: 0 0 0 3px rgba(77, 150, 255, .22);
    }
    .download-mode-tabs {
      display: inline-flex;
      gap: .25rem;
      align-self: flex-start;
      padding: .25rem;
      margin-bottom: .75rem;
      border: 1px solid var(--line);
      border-radius: 12px;
      background: #060D1C;
    }
    .download-mode-tab {
      min-height: 2.75rem;
      padding: .5rem .85rem;
      border: 0;
      border-radius: 9px;
      background: transparent;
      color: var(--muted);
      font: inherit;
      font-weight: 750;
      cursor: pointer;
    }
    .download-mode-tab[aria-pressed="true"] {
      background: var(--accent-soft);
      color: var(--accent);
    }
    .download-mode-tab:focus-visible {
      outline: 3px solid rgba(77, 150, 255, .45);
      outline-offset: 2px;
    }
    .dl-card--direct {
      border-left: 3px solid rgba(77, 150, 255, .65);
    }
    .dl-card__title-row {
      display: flex;
      align-items: center;
      gap: .55rem;
      min-width: 0;
    }
    .dl-source-badge {
      flex: none;
      padding: .16rem .42rem;
      border: 1px solid rgba(77, 150, 255, .30);
      border-radius: 999px;
      background: var(--accent-soft);
      color: var(--accent);
      font-size: .68rem;
      font-weight: 800;
      letter-spacing: .06em;
      text-transform: uppercase;
    }
    .dl-card__stats {
      margin: .55rem 0 0;
      color: var(--muted);
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      font-size: .82rem;
    }

    /* ---- Buttons ---- */
    .primary-button {
      background: var(--accent);
      color: #051023;
      border-radius: 14px;
      box-shadow: none;
    }
    .primary-button:hover {
      background: var(--accent-strong);
    }
    .ghost-button {
      background: var(--surface);
      color: var(--ink);
      border: 1px solid var(--line);
    }
    .ghost-button:hover {
      border-color: rgba(77, 150, 255, .40);
    }
    .action-button {
      background: var(--accent-soft);
      color: var(--accent);
      border: 1px solid rgba(77, 150, 255, .30);
      border-radius: 12px;
      font-weight: 750;
    }
    .action-button.danger {
      background: transparent;
      color: var(--danger);
      border: 1px solid rgba(248, 113, 113, .34);
    }

    /* Press feedback: a slight settle, motion-safe only. */
    @media (prefers-reduced-motion: no-preference) {
      .primary-button,
      .ghost-button,
      .action-button,
      .trends-open-button,
      .trends-back-button,
      .trailer-button {
        transition: transform 120ms ease, opacity 120ms ease,
          background 150ms ease, border-color 150ms ease;
      }
      .primary-button:active,
      .ghost-button:active,
      .action-button:active,
      .trends-open-button:active,
      .trends-back-button:active,
      .trailer-button:active {
        transform: scale(.985);
        opacity: .9;
      }
    }

    /* ---- Cards ---- */
    .download-card,
    .file-card,
    .empty-card {
      background: #0E182D;
      border: 1px solid var(--line);
      border-radius: 16px;
    }
    .empty-card {
      background: var(--surface);
    }
    .meta,
    .last-updated,
    .status-line,
    .section-heading p,
    .empty,
    .empty-card p {
      color: var(--muted);
    }
    .last-updated,
    .progress-value {
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    }
    .status-line.error {
      color: #FCA5A5;
    }

    /* ---- Status pills ---- */
    .pill {
      background: var(--wait-soft);
      color: var(--muted);
      border: 1px solid var(--line);
    }
    .pill.downloading {
      background: var(--accent-soft);
      color: var(--accent);
      border-color: rgba(77, 150, 255, .30);
    }
    .pill.completed {
      background: var(--ok-soft);
      color: #4ADE80;
      border-color: rgba(74, 222, 128, .30);
    }
    .pill.failed {
      background: var(--danger-soft);
      color: var(--danger);
      border-color: rgba(248, 113, 113, .30);
    }

    /* ---- Progress: flat blue fill, no gradient ---- */
    .progress-track {
      height: 8px;
      background: rgba(255, 255, 255, .10);
    }
    .progress-fill {
      background: var(--accent);
    }
    .progress-value {
      color: var(--ink);
    }
  `;
  document.head.appendChild(styles);
}

function installDirectDownloadComposer() {
  if (document.querySelector("#downloadModeTabs")) return;

  const label = document.querySelector('label[for="magnetLink"]');
  originalComposerLabelHtml = label?.innerHTML || "";

  const tabs = document.createElement("div");
  tabs.id = "downloadModeTabs";
  tabs.className = "download-mode-tabs";
  tabs.setAttribute("role", "group");
  tabs.setAttribute("aria-label", "Download type");
  tabs.innerHTML = `
    <button class="download-mode-tab" type="button" data-download-mode="magnet" aria-pressed="true">Magnet</button>
    <button class="download-mode-tab" type="button" data-download-mode="direct" aria-pressed="false">Direct Link</button>
  `;

  const anchor = label || magnetLinkInput;
  anchor.parentNode.insertBefore(tabs, anchor);

  directLinkInput = magnetLinkInput.cloneNode(false);
  directLinkInput.id = "directLink";
  directLinkInput.name = "directLink";
  directLinkInput.value = "";
  directLinkInput.placeholder = "https://example.com/file";
  directLinkInput.setAttribute("aria-label", "Direct download URL");
  directLinkInput.setAttribute("autocomplete", "url");
  directLinkInput.setAttribute("inputmode", "url");
  directLinkInput.hidden = true;
  magnetLinkInput.insertAdjacentElement("afterend", directLinkInput);

  tabs.addEventListener("click", (event) => {
    const tab = event.target.closest("[data-download-mode]");
    if (tab) setComposerMode(tab.dataset.downloadMode);
  });

  directLinkInput.addEventListener("keydown", (event) => {
    if ((event.ctrlKey || event.metaKey) && event.key === "Enter") {
      addDirectDownload().catch((error) => setStatus(error.message, true));
    }
  });
}

function setComposerMode(mode) {
  if (mode !== "magnet" && mode !== "direct") return;
  composerMode = mode;
  const isDirect = mode === "direct";
  magnetLinkInput.hidden = isDirect;
  directLinkInput.hidden = !isDirect;

  document.querySelectorAll("#downloadModeTabs [data-download-mode]").forEach((tab) => {
    const selected = tab.dataset.downloadMode === mode;
    tab.setAttribute("aria-pressed", String(selected));
  });

  const label = document.querySelector('label[for="magnetLink"], label[for="directLink"]');
  if (label) {
    label.setAttribute("for", isDirect ? "directLink" : "magnetLink");
    label.innerHTML = isDirect ? "Direct download URL" : originalComposerLabelHtml;
  }
  if (!isSubmitting && !isDirectSubmitting) {
    addMagnetButton.textContent = isDirect ? "Start direct download" : "Start download";
  }
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
      border: 1px solid rgba(77, 150, 255, .26);
      border-radius: 18px;
      background: #0E182D;
      box-shadow: none;
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
      color: #4D96FF !important;
      font-size: .78rem;
      font-weight: 700;
      letter-spacing: .14em;
      text-transform: uppercase;
    }
    .trends-open-button,
    .trends-back-button,
    .trailer-button {
      min-height: 42px;
      border: 1px solid rgba(77, 150, 255, .30);
      border-radius: 14px;
      background: rgba(77, 150, 255, .14);
      color: #4D96FF;
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
      border-color: rgba(77, 150, 255, .55);
    }
    .trends-view {
      margin: 24px 0;
      padding: 22px;
      border: 1px solid rgba(255, 255, 255, .08);
      border-radius: 20px;
      background: #091120;
      color: #F2F6FF;
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
      color: #F2F6FF;
      border-color: rgba(255, 255, 255, .14);
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
      border: 1px solid rgba(255, 255, 255, .08);
      border-radius: 14px;
      background: #0E182D;
      overflow: hidden;
      transition: transform 180ms ease, border-color 180ms ease, background 180ms ease;
    }
    .trend-card:hover {
      transform: translateY(-3px);
      border-color: rgba(77, 150, 255, .34);
      background: #122036;
    }
    .trend-poster,
    .trend-placeholder {
      width: 100%;
      aspect-ratio: 2 / 3;
      display: block;
      object-fit: cover;
      background: #060D1C;
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
      background: rgba(77, 150, 255, .13);
      color: #4D96FF;
      border-radius: 10px;
    }
    .trend-message {
      padding: 20px;
      border: 1px solid rgba(255, 255, 255, .08);
      border-radius: 14px;
      background: #0E182D;
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

function isTrendsRefreshDue() {
  return !trendsState.loaded
    || Date.now() - trendsState.lastRefreshAt >= TRENDS_REFRESH_MS;
}

function isTrendsDataStale(data) {
  if (data?.stale === true) return true;
  const updatedAt = Date.parse(data?.updated_at || "");
  return Number.isFinite(updatedAt) && Date.now() - updatedAt >= TRENDS_STALE_MS;
}

function hasTrendsContent(data) {
  return ["global_movies", "global_series", "india_movies", "india_series"]
    .some((key) => Array.isArray(data?.[key]));
}

async function loadTrends({ force = false } = {}) {
  if (trendsState.loading) {
    if (force) {
      trendsState.pendingRefresh = true;
      trendsState.requestGeneration += 1;
    }
    return;
  }
  if (!force && !isTrendsRefreshDue()) {
    renderTrendsView();
    return;
  }

  const requestGeneration = ++trendsState.requestGeneration;
  trendsState.loading = true;
  trendsState.error = "";
  renderTrendsView();

  try {
    const data = await apiFetch("/api/trends");
    if (requestGeneration !== trendsState.requestGeneration) return;
    if (data?.error && !hasTrendsContent(data)) throw new Error(data.error);
    trendsState.data = data;
    trendsState.loaded = true;
    trendsState.lastRefreshAt = Date.now();
    trendsState.error = data?.error || "";
  } catch (error) {
    if (requestGeneration === trendsState.requestGeneration) {
      trendsState.error = error.message || "data not available";
    }
  } finally {
    trendsState.loading = false;
    renderTrendsView();
    if (trendsState.pendingRefresh) {
      trendsState.pendingRefresh = false;
      loadTrends({ force: true });
    }
  }
}

function renderTrendsView() {
  const content = document.querySelector("[data-trends-content]");
  const updated = document.querySelector("[data-trends-updated]");
  if (!content) return;

  if (trendsState.loading && !trendsState.data) {
    updated.textContent = "";
    content.innerHTML = `<div class="trend-message">Loading TMDB trends...</div>`;
    return;
  }

  if (trendsState.error && !trendsState.data) {
    updated.textContent = "";
    content.innerHTML = `<div class="trend-message">Trends unavailable. ${escapeHtml(trendsState.error)}</div>`;
    return;
  }

  const data = trendsState.data || {};
  const staleLabel = isTrendsDataStale(data) ? " · Stale data" : "";
  const updatedText = data.updated_at ? `Updated ${formatDateTime(data.updated_at)}${staleLabel}` : "";
  if (updated.textContent !== updatedText) updated.textContent = updatedText;

  const dataSignature = JSON.stringify([
    data.updated_at,
    data.global_movies,
    data.global_series,
    data.india_movies,
    data.india_series,
  ]);
  if (content._cloudboxTrendsSignature !== dataSignature) {
    content.innerHTML = `
      <div class="trend-message" data-trends-error hidden></div>
      <div class="trends-sections">
        ${renderTrendSection("Global Movies", data.global_movies)}
        ${renderTrendSection("Global Series", data.global_series)}
        ${renderTrendSection("India Movies", data.india_movies)}
        ${renderTrendSection("India Series", data.india_series)}
      </div>
    `;
    content._cloudboxTrendsSignature = dataSignature;
  }

  const errorMessage = content.querySelector("[data-trends-error]");
  const errorText = trendsState.error
    ? `Trends unavailable. ${trendsState.error}`
    : "";
  if (errorMessage.textContent !== errorText) errorMessage.textContent = errorText;
  errorMessage.hidden = !trendsState.error;
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

function renderedControlLocation(container, element) {
  if (!(element instanceof Element) || !container.contains(element)) return null;

  const row = element.closest("article");
  const controls = row
    ? [...row.querySelectorAll("a[href], button, input, select, textarea, [tabindex]")]
    : [];
  const controlIndex = controls.indexOf(element);
  if (!row?._cloudboxRenderKey || controlIndex < 0) return null;
  return { key: row._cloudboxRenderKey, controlIndex };
}

function findRenderedControl(container, location) {
  if (!location) return null;

  const row = [...container.children].find(
    (element) => element._cloudboxRenderKey === location.key,
  );
  if (!row) return null;
  return [...row.querySelectorAll("a[href], button, input, select, textarea, [tabindex]")]
    [location.controlIndex] || null;
}

function reconcileRenderedRows(container, rows, emptyHtml) {
  const focusLocation = renderedControlLocation(container, document.activeElement);
  const openerLocation = renderedControlLocation(container, completedDeleteModalOpener);

  if (!rows.length) {
    if (container._cloudboxEmptyHtml !== emptyHtml) {
      container.innerHTML = emptyHtml;
      container._cloudboxEmptyHtml = emptyHtml;
    }
    return;
  }

  container._cloudboxEmptyHtml = null;
  const existingRows = new Map(
    [...container.children]
      .filter((element) => element._cloudboxRenderKey)
      .map((element) => [element._cloudboxRenderKey, element]),
  );
  const staleRows = new Set(container.children);
  const template = document.createElement("template");

  rows.forEach((row, index) => {
    let element = existingRows.get(row.key);
    if (!element || element._cloudboxRenderSignature !== row.signature) {
      template.innerHTML = row.html.trim();
      element = template.content.firstElementChild;
      element._cloudboxRenderKey = row.key;
      element._cloudboxRenderSignature = row.signature;
    } else {
      staleRows.delete(element);
    }

    row.update?.(element, index);
    const currentElement = container.children[index];
    if (currentElement !== element) {
      container.insertBefore(element, currentElement || null);
    }
  });

  staleRows.forEach((element) => element.remove());

  if (focusLocation && !container.contains(document.activeElement)) {
    findRenderedControl(container, focusLocation)?.focus();
  }
  if (openerLocation) {
    completedDeleteModalOpener = findRenderedControl(container, openerLocation);
  }
}

function directDownloadId(job) {
  return String(job?.id ?? job?.job_id ?? "").trim();
}

function directDownloadState(job) {
  const raw = String(job?.state ?? job?.status ?? "queued").trim().toLowerCase();
  if (["complete", "completed", "finished", "success"].includes(raw)) return "completed";
  if (["error", "failed", "failure"].includes(raw)) return "error";
  if (["cancelled", "canceled"].includes(raw)) return "cancelled";
  if (["downloading", "running", "active", "in_progress"].includes(raw)) return "downloading";
  return "queued";
}

function directDownloadProgress(job) {
  const downloaded = finiteNonNegative(job?.downloaded_bytes ?? job?.bytes_downloaded ?? job?.downloaded);
  const total = finiteNonNegative(job?.total_bytes ?? job?.bytes_total ?? job?.total_size);
  if (total > 0) return Math.max(0, Math.min(100, Math.round((downloaded / total) * 100)));

  const percentValue = Number(job?.progress_percent);
  if (Number.isFinite(percentValue)) return Math.max(0, Math.min(100, Math.round(percentValue)));

  const progressValue = Number(job?.progress);
  if (!Number.isFinite(progressValue)) return 0;
  const percent = progressValue >= 0 && progressValue <= 1 ? progressValue * 100 : progressValue;
  return Math.max(0, Math.min(100, Math.round(percent)));
}

function finiteNonNegative(value) {
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? number : 0;
}

function formatByteCount(value) {
  const bytes = finiteNonNegative(value);
  if (bytes < 1024) return `${Math.round(bytes)} B`;
  const units = ["KB", "MB", "GB", "TB"];
  let amount = bytes / 1024;
  let unit = units[0];
  for (let index = 1; index < units.length && amount >= 1024; index += 1) {
    amount /= 1024;
    unit = units[index];
  }
  return `${amount >= 10 ? amount.toFixed(1) : amount.toFixed(2)} ${unit}`;
}

function directDownloadName(job) {
  const provided = String(job?.filename ?? job?.name ?? "").trim();
  if (provided) return provided;
  return "Preparing direct download";
}

function directDownloadError(job) {
  const raw = String(job?.error_message ?? job?.error ?? job?.message ?? "").trim();
  if (!raw) return "Download failed";
  const normalized = normalizeApiError(500, JSON.stringify({ message: raw })).message;
  return normalized === "CloudBox server error" ? "Download failed" : normalized;
}

function directDownloadTimeText(job, state) {
  const value = state === "completed"
    ? job?.completed_at ?? job?.updated_at
    : job?.created_at ?? job?.added_at ?? job?.updated_at;
  if (!value) return "Time unavailable.";
  return `${state === "completed" ? "Completed" : "Added"} ${formatDateTime(value)}`;
}

function directDownloadStats(job, state) {
  const downloaded = finiteNonNegative(job?.downloaded_bytes ?? job?.bytes_downloaded ?? job?.downloaded);
  const total = finiteNonNegative(job?.total_bytes ?? job?.bytes_total ?? job?.total_size);
  const speed = finiteNonNegative(job?.speed_bytes_per_second ?? job?.speed_bps ?? job?.download_speed);
  const sizeText = total > 0
    ? `${formatByteCount(downloaded)} / ${formatByteCount(total)}`
    : downloaded > 0
      ? `${formatByteCount(downloaded)} downloaded`
      : "Size unknown";
  return state === "downloading"
    ? `${sizeText} · ${formatByteCount(speed)}/s`
    : sizeText;
}

function directDownloadStateLabel(state) {
  return {
    queued: "Queued",
    downloading: "Downloading",
    completed: "Completed",
    error: "Error",
    cancelled: "Cancelled",
  }[state];
}

function buildDirectDownloadRows() {
  const jobs = cachedDirectDownloads
    .map((job, index) => ({ job, index }))
    .filter(({ job }) => directDownloadId(job))
    .sort((left, right) => {
      const leftActive = ["queued", "downloading"].includes(directDownloadState(left.job));
      const rightActive = ["queued", "downloading"].includes(directDownloadState(right.job));
      if (leftActive !== rightActive) return leftActive ? -1 : 1;
      const leftTime = Date.parse(left.job?.created_at ?? left.job?.updated_at ?? "") || 0;
      const rightTime = Date.parse(right.job?.created_at ?? right.job?.updated_at ?? "") || 0;
      return rightTime - leftTime || right.index - left.index;
    });

  const rows = jobs.map(({ job }) => {
    const id = directDownloadId(job);
    const state = directDownloadState(job);
    const name = directDownloadName(job);
    const progress = directDownloadProgress(job);
    const titleId = `direct-title-${id.replace(/[^a-z0-9_-]/gi, "-")}`;
    const active = state === "queued" || state === "downloading";
    const action = active ? "cancel" : "remove";
    const actionLabel = active ? "Cancel" : "Remove";
    const stateClass = state === "queued" ? "waiting" : state === "error" || state === "cancelled" ? "failed" : state;
    const errorText = state === "error" ? directDownloadError(job) : "";
    const signature = JSON.stringify([id, name, state, action, errorText]);

    let stateContent;
    if (active) {
      stateContent = `
        <p class="dl-card__state" data-direct-state>${escapeHtml(directDownloadStateLabel(state))}</p>
        <div class="dl-progress" role="progressbar" aria-labelledby="${escapeHtml(titleId)}" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${progress}" data-direct-progress>
          <div class="dl-bar${state === "queued" ? " dl-bar--waiting" : ""}">
            ${state === "downloading" ? `<div class="dl-bar__fill" style="--progress: ${progress}%" data-direct-progress-fill></div>` : ""}
          </div>
        </div>
        <p class="dl-card__stats" data-direct-stats>${escapeHtml(directDownloadStats(job, state))}</p>
      `;
    } else if (state === "completed") {
      stateContent = `
        <p class="dl-card__state dl-card__state--completed">✓ Completed — see Completed files</p>
        <p class="dl-card__stats" data-direct-stats>${escapeHtml(directDownloadStats(job, state))}</p>
      `;
    } else if (state === "cancelled") {
      stateContent = `<p class="dl-card__state dl-card__state--failed">Cancelled</p>`;
    } else {
      stateContent = `<p class="dl-card__state dl-card__state--failed">✗ Error — ${escapeHtml(errorText)}</p>`;
    }

    const content = `
      <header class="dl-card__header">
        <div class="dl-card__title-row">
          <span class="dl-source-badge">Direct</span>
          <h3 id="${escapeHtml(titleId)}" class="dl-card__title">${escapeHtml(name)}</h3>
        </div>
        ${active ? `<span class="dl-card__percent" data-direct-percent>${progress}%</span>` : ""}
      </header>
      ${stateContent}
      <footer class="dl-card__footer">
        <p class="dl-card__time">${escapeHtml(directDownloadTimeText(job, state))}</p>
        <button class="dl-delete" type="button" data-direct-action="${action}" data-direct-id="${escapeHtml(id)}" aria-label="${actionLabel} ${escapeHtml(name)}">
          ${actionLabel}
        </button>
      </footer>
    `;

    return {
      key: `direct:${id}`,
      signature,
      html: `<article class="dl-card dl-card--${stateClass} dl-card--direct">${content}</article>`,
      update: (element) => {
        const percent = element.querySelector("[data-direct-percent]");
        const progressElement = element.querySelector("[data-direct-progress]");
        const progressFill = element.querySelector("[data-direct-progress-fill]");
        const stats = element.querySelector("[data-direct-stats]");
        const actionButton = element.querySelector("[data-direct-action]");
        if (percent) percent.textContent = `${progress}%`;
        if (progressElement) progressElement.setAttribute("aria-valuenow", String(progress));
        if (progressFill) progressFill.style.setProperty("--progress", `${progress}%`);
        if (stats) stats.textContent = directDownloadStats(job, state);
        if (actionButton) actionButton.disabled = activeDirectActionIds.has(id);
      },
    };
  });

  if (!directDownloadsLoaded) {
    rows.push({
      key: "direct:loading",
      signature: "direct-loading",
      html: emptyCard("Checking direct downloads", "Direct Link jobs will appear here."),
    });
  } else if (directPollingError) {
    rows.push({
      key: "direct:offline",
      signature: directPollingError,
      html: emptyCard("Direct downloads offline", `${directPollingError}. Existing downloads remain visible.`),
    });
  }

  return rows;
}

function renderTorrents(torrents) {
  const summaryCounts = {
    active: 0,
    ready: 0,
    failed: 0,
    waiting: 0,
  };
  torrents.forEach((torrent) => {
    const status = normalizeStatus(torrent);
    if (status === "Downloading") summaryCounts.active += 1;
    else if (status === "Completed") summaryCounts.ready += 1;
    else if (status === "Failed") summaryCounts.failed += 1;
    else summaryCounts.waiting += 1;
  });
  cachedDirectDownloads.forEach((job) => {
    const state = directDownloadState(job);
    if (state === "downloading") summaryCounts.active += 1;
    else if (state === "completed") summaryCounts.ready += 1;
    else if (state === "error" || state === "cancelled") summaryCounts.failed += 1;
    else summaryCounts.waiting += 1;
  });
  const summaryItems = Object.entries(summaryCounts).filter(([, count]) => count > 0);
  const summarySignature = summaryItems.map(([state, count]) => `${state}:${count}`).join("|");
  if (queueSummary._cloudboxSummarySignature !== summarySignature) {
    const fragment = document.createDocumentFragment();
    summaryItems.forEach(([state, count]) => {
      const chip = document.createElement("span");
      chip.className = `dl-summary__chip dl-summary__chip--${state}`;
      chip.textContent = `${count} ${state}`;
      fragment.appendChild(chip);
    });
    queueSummary.replaceChildren(fragment);
    queueSummary.hidden = summaryItems.length === 0;
    queueSummary._cloudboxSummarySignature = summarySignature;
  }

  const directRows = buildDirectDownloadRows();
  if (!torrents.length && !directRows.length) {
    reconcileRenderedRows(
      torrentList,
      [],
      emptyCard("Queue is clear", "Start a Magnet or Direct Link download when you want the server to do the waiting."),
    );
    cachedTorrents = torrents;
    return;
  }

  const sortedTorrents = sortTorrentsForDisplay(torrents);

  torrentList.style.flexDirection = "column";
  const torrentRows = sortedTorrents.map((torrent, index) => {
    const status = normalizeStatus(torrent);
    const progress = normalizeProgress(torrent);
    const name = torrentDisplayName(torrent);
    const rowKey = torrent.hash || `${name}:${index}`;
    const titleId = `torrent-title-${String(torrent.hash || index).replace(/[^a-z0-9_-]/gi, "-")}`;
    const timeText = torrentTimeText(torrent, status);
    const stateClass = statusClass(status);
    let statusContent;

    if (status === "Downloading") {
      statusContent = `
        <div class="dl-progress" role="progressbar" aria-labelledby="${escapeHtml(titleId)}" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${progress}">
          <div class="dl-bar">
            <div class="dl-bar__fill" style="--progress: ${progress}%"></div>
          </div>
        </div>
      `;
    } else if (status === "Waiting") {
      statusContent = `
        <div class="dl-card__state-row">
          <p class="dl-card__state">Waiting for peers</p>
          <div class="dl-progress" role="progressbar" aria-labelledby="${escapeHtml(titleId)}" aria-valuemin="0" aria-valuemax="100" aria-valuenow="0">
            <div class="dl-bar dl-bar--waiting"></div>
          </div>
        </div>
      `;
    } else if (status === "Completed") {
      statusContent = `<p class="dl-card__state dl-card__state--completed">✓ Ready — see Completed files</p>`;
    } else {
      statusContent = `<p class="dl-card__state dl-card__state--failed">✗ Download failed</p>`;
    }

    const content = `
      <header class="dl-card__header">
        <h3 id="${escapeHtml(titleId)}" class="dl-card__title">${escapeHtml(name)}</h3>
        ${status === "Downloading" ? `<span class="dl-card__percent">${progress}%</span>` : ""}
      </header>
      ${statusContent}
      <footer class="dl-card__footer">
        <p class="dl-card__time">${escapeHtml(timeText)}</p>
        <button class="dl-delete" type="button" data-delete-hash="${escapeHtml(torrent.hash)}" aria-label="Delete ${escapeHtml(name)}">
          Delete
        </button>
      </footer>
    `;

    return {
      key: `torrent:${rowKey}`,
      signature: content,
      html: `<article class="dl-card dl-card--${stateClass}">${content}</article>`,
      update: (element) => {
        const order = String(index);
        if (element.style.order !== order) element.style.order = order;
      },
    };
  });
  reconcileRenderedRows(torrentList, [...torrentRows, ...directRows], "");

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

function completedItemRelativePath(file) {
  const relativePath = file?.relative_path ?? file?.path;
  return typeof relativePath === "string" && relativePath.trim()
    ? relativePath
    : "";
}

function isCompletedFolder(file) {
  const itemType = String(file?.type ?? file?.kind ?? file?.entry_type ?? "").toLowerCase();
  return file?.is_folder === true
    || file?.is_directory === true
    || itemType === "folder"
    || itemType === "directory";
}

function renderCompletedFiles(files) {
  completedFileSnapshot = Array.isArray(files) ? files : [];

  if (!completedFileSnapshot.length) {
    reconcileRenderedRows(
      completedFiles,
      [],
      emptyCard("Nothing ready yet", "Completed files will collect here with stream, download, and VLC links."),
    );
    return;
  }

  const rows = completedFileSnapshot.map((file, index) => {
    const url = fileUrl(file);
    const name = fileName(file);
    const safeUrl = escapeHtml(url);
    const relativePath = completedItemRelativePath(file);
    const folder = isCompletedFolder(file);
    const timeText = file.modified_at
      ? `Modified ${formatDateTime(file.modified_at)}`
      : "Time unavailable.";

    return {
      key: `completed:${relativePath || url || `${name}:${index}`}`,
      signature: JSON.stringify([url, name, relativePath, folder, timeText]),
      html: `
        <article class="file-card">
        <div class="file-title">
          <h3 class="file-name">${escapeHtml(name)}</h3>
          <p class="meta">${escapeHtml(timeText)}</p>
        </div>
        <div class="actions">
          <a class="action-button" href="${safeUrl}" target="_blank" rel="noreferrer">Stream</a>
          <a class="action-button" href="${safeUrl}" download>Download</a>
          <button class="action-button" type="button" data-copy-index="${index}">Copy VLC link</button>
          ${relativePath ? `
            <button class="action-button danger" type="button" data-delete-completed-index="${index}">
              Delete ${folder ? "folder" : "file"}
            </button>
          ` : ""}
        </div>
        </article>
      `,
      update: (element) => {
        const copyButton = element.querySelector("[data-copy-index]");
        const deleteButton = element.querySelector("[data-delete-completed-index]");
        const nextIndex = String(index);
        if (copyButton && copyButton.dataset.copyIndex !== nextIndex) {
          copyButton.dataset.copyIndex = nextIndex;
        }
        if (deleteButton && deleteButton.dataset.deleteCompletedIndex !== nextIndex) {
          deleteButton.dataset.deleteCompletedIndex = nextIndex;
        }
      },
    };
  });
  reconcileRenderedRows(completedFiles, rows, "");
}

async function addMagnet() {
  if (isSubmitting || isDirectSubmitting) return;

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
    downloaderDataGeneration += 1;
    magnetLinkInput.value = "";
    setStatus("Download started. Status updates automatically.");
  } finally {
    isSubmitting = false;
    addMagnetButton.disabled = false;
    addMagnetButton.textContent = composerMode === "direct" ? "Start direct download" : "Start download";
  }

  await refreshAll({ quiet: true, fullReconciliation: false });
}

async function addDirectDownload() {
  if (isSubmitting || isDirectSubmitting) return;

  const url = directLinkInput.value.trim();
  let parsedUrl;
  try {
    parsedUrl = new URL(url);
  } catch {
    parsedUrl = null;
  }
  if (!parsedUrl || !["http:", "https:"].includes(parsedUrl.protocol)) {
    setStatus("Paste one valid HTTP or HTTPS link first.", true);
    directLinkInput.focus();
    return;
  }

  isDirectSubmitting = true;
  addMagnetButton.disabled = true;
  addMagnetButton.textContent = "Starting...";
  setStatus("Sending direct link to private backend...");

  try {
    await apiFetch("/api/direct-downloads", {
      method: "POST",
      body: JSON.stringify({ url }),
    });
    directDataGeneration += 1;
    directLinkInput.value = "";
    setStatus("Direct download started. Status updates automatically.");
  } finally {
    isDirectSubmitting = false;
    addMagnetButton.disabled = false;
    addMagnetButton.textContent = composerMode === "direct" ? "Start direct download" : "Start download";
  }

  await refreshDirectDownloads();
}

async function handleDirectDownloadAction(id, action) {
  if (!id || activeDirectActionIds.has(id)) return;
  activeDirectActionIds.add(id);
  renderTorrents(cachedTorrents);
  setStatus(action === "cancel" ? "Cancelling direct download..." : "Removing direct download...");

  try {
    await apiFetch(
      action === "cancel"
        ? `/api/direct-downloads/${encodeURIComponent(id)}/cancel`
        : `/api/direct-downloads/${encodeURIComponent(id)}`,
      { method: action === "cancel" ? "POST" : "DELETE" },
    );
    directDataGeneration += 1;
    if (action === "remove") {
      cachedDirectDownloads = cachedDirectDownloads.filter((job) => directDownloadId(job) !== id);
      renderTorrents(cachedTorrents);
    }
    setStatus(action === "cancel" ? "Direct download cancelled." : "Direct download removed.");
    await refreshDirectDownloads();
  } finally {
    activeDirectActionIds.delete(id);
    renderTorrents(cachedTorrents);
  }
}

function hasDirectCompletionTransition(jobs) {
  return jobs.some((job) => {
    const id = directDownloadId(job);
    return id && incompleteDirectDownloadIds.has(id) && directDownloadState(job) === "completed";
  });
}

function rememberIncompleteDirectDownloads(jobs) {
  incompleteDirectDownloadIds = new Set(
    jobs
      .filter((job) => ["queued", "downloading"].includes(directDownloadState(job)))
      .map(directDownloadId)
      .filter(Boolean),
  );
}

async function refreshDirectDownloads() {
  if (isDirectRefreshing) {
    directRefreshPending = true;
    return;
  }

  const refreshGeneration = directDataGeneration;
  isDirectRefreshing = true;
  try {
    const jobs = await apiFetch("/api/direct-downloads");
    if (refreshGeneration !== directDataGeneration) return;

    const directData = Array.isArray(jobs) ? jobs : [];
    const completed = hasDirectCompletionTransition(directData);
    cachedDirectDownloads = directData;
    directDownloadsLoaded = true;
    directPollingError = "";
    rememberIncompleteDirectDownloads(directData);
    renderTorrents(cachedTorrents);

    if (completed) {
      refreshCompletedFiles().catch((error) => setStatus(error.message, true));
    }
  } catch (error) {
    if (refreshGeneration === directDataGeneration) {
      directDownloadsLoaded = true;
      directPollingError = error.message;
      renderTorrents(cachedTorrents);
    }
  } finally {
    isDirectRefreshing = false;
  }

  if (directRefreshPending) {
    directRefreshPending = false;
    await refreshDirectDownloads();
  }
}

async function pollDirectDownloads() {
  window.clearTimeout(directPollTimer);
  await refreshDirectDownloads();
  const hasActiveJobs = cachedDirectDownloads.some(
    (job) => ["queued", "downloading"].includes(directDownloadState(job)),
  );
  directPollTimer = window.setTimeout(
    pollDirectDownloads,
    hasActiveJobs ? DIRECT_ACTIVE_POLL_MS : DIRECT_IDLE_POLL_MS,
  );
}

async function deleteTorrent(hash) {
  if (!hash) return;
  setStatus("Deleting torrent and files...");
  const result = await apiFetch(
    `/api/torrents/${encodeURIComponent(hash)}`,
    { method: "DELETE" },
  );
  downloaderDataGeneration += 1;
  cachedTorrents = cachedTorrents.filter((torrent) => torrent.hash !== hash);

  const deletedFilePaths = Array.isArray(result?.deleted_file_paths)
    ? result.deleted_file_paths
    : [];
  const deletedFolderPaths = Array.isArray(result?.deleted_folder_paths)
    ? result.deleted_folder_paths
    : [];
  const warnings = Array.isArray(result?.warnings)
    ? result.warnings.filter((warning) => typeof warning === "string" && warning.trim())
    : [];
  const warningLabels = [...new Set(warnings.map((warning) => {
    const normalized = warning.toLowerCase();
    if (normalized.includes("qbittorrent delete failed")) {
      return "qBittorrent could not remove the torrent";
    }
    if (normalized.includes("could not verify qbittorrent file paths")) {
      return "completed-file paths could not be verified";
    }
    if (normalized.includes("no content-verified completed files")) {
      return "no content-verified completed files were found";
    }
    if (normalized.includes("torrent was not found")) {
      return "the torrent was not found in qBittorrent";
    }
    if (normalized.includes("failed to delete") || normalized.includes("failed to remove")) {
      return "one or more files or folders could not be removed";
    }
    if (normalized.includes("refused to delete unsafe")) {
      return "an unsafe cleanup path was skipped";
    }
    return "an additional cleanup warning was reported";
  }))];
  const shownWarnings = warningLabels.slice(0, 2);
  const remainingWarningCount = warningLabels.length - shownWarnings.length;
  const warningSummary = shownWarnings.length
    ? ` Warnings: ${shownWarnings.join("; ")}${remainingWarningCount > 0 ? `; ${remainingWarningCount} more` : ""}.`
    : "";
  const removedCompletedItems = deletedFilePaths.length > 0 || deletedFolderPaths.length > 0;
  const partialResult = result?.status === "partial"
    || result?.status === "failed"
    || result?.partial_success === true
    || warnings.length > 0;

  if (!removedCompletedItems) {
    setStatus(
      `Torrent delete request completed, but no completed files were removed.${warningSummary}`,
      true,
    );
  } else if (partialResult) {
    setStatus(
      `Torrent delete request completed, but some files or cleanup steps may remain.${warningSummary}`,
      true,
    );
  } else {
    setStatus("Torrent and files deleted.");
  }

  await refreshAll({ quiet: true });
}

function getDeleteConfirmationModal() {
  let modal = document.querySelector("#deleteConfirmModal");
  if (!modal) {
    modal = document.createElement("div");
    modal.id = "deleteConfirmModal";
    modal.innerHTML = `
      <div style="position:fixed;inset:0;background:rgba(0,0,0,.55);z-index:9998;"></div>
      <section role="dialog" aria-modal="true" aria-labelledby="deleteConfirmTitle" aria-describedby="deleteConfirmName" style="position:fixed;left:50%;top:50%;transform:translate(-50%,-50%);z-index:9999;width:min(92vw,420px);background:#0E182D;color:#F2F6FF;border:1px solid rgba(255,255,255,.10);border-radius:16px;padding:18px;box-shadow:0 18px 60px rgba(0,0,0,.55);">
        <h3 id="deleteConfirmTitle" style="margin:0 0 8px;font-size:18px;">Delete download?</h3>
        <p id="deleteConfirmName" style="margin:0 0 16px;color:#8FA3C7;line-height:1.35;word-break:break-word;"></p>
        <div style="display:flex;gap:10px;justify-content:flex-end;">
          <button type="button" data-delete-cancel style="min-height:44px;border:1px solid rgba(255,255,255,.14);background:transparent;color:#F2F6FF;border-radius:10px;padding:10px 14px;">Cancel</button>
          <button type="button" data-delete-confirm style="min-height:44px;border:0;background:#dc2626;color:white;border-radius:10px;padding:10px 14px;">Delete</button>
        </div>
      </section>
    `;
    document.body.appendChild(modal);
    modal.addEventListener("click", handleDeleteConfirmationClick);
  }
  return modal;
}

function setDeleteConfirmationBusy(isBusy) {
  const modal = document.querySelector("#deleteConfirmModal");
  if (!modal) return;

  const cancelButton = modal.querySelector("[data-delete-cancel]");
  const confirmButton = modal.querySelector("[data-delete-confirm]");
  if (cancelButton) cancelButton.disabled = isBusy;
  if (confirmButton) {
    confirmButton.disabled = isBusy;
    confirmButton.textContent = isBusy ? "Deleting..." : "Delete";
  }
}

function showDeleteConfirmation(hash) {
  if (isCompletedDeleteActive) return;

  const torrent = cachedTorrents.find((item) => item.hash === hash);
  const name = torrentDisplayName(torrent || { hash }, "this download");
  pendingDeleteHash = hash;
  pendingCompletedDelete = null;
  pendingDirectDeleteId = "";

  const modal = getDeleteConfirmationModal();
  modal.querySelector("#deleteConfirmTitle").textContent = "Delete download?";
  modal.querySelector("#deleteConfirmName").textContent = `${name} and its files will be deleted.`;
  setDeleteConfirmationBusy(false);
  modal.hidden = false;
}

function showDirectDeleteConfirmation(id, opener) {
  if (isCompletedDeleteActive) return;

  const job = cachedDirectDownloads.find((item) => directDownloadId(item) === id);
  const filename = String(job?.filename ?? job?.name ?? "").trim();
  pendingDeleteHash = "";
  pendingCompletedDelete = null;
  pendingDirectDeleteId = id;

  const modal = getDeleteConfirmationModal();
  modal.querySelector("#deleteConfirmTitle").textContent = "Remove direct download?";
  modal.querySelector("#deleteConfirmName").textContent = filename
    ? `${filename} and its downloaded file will be permanently deleted.`
    : "This Direct Download entry and its downloaded file, if present, will be permanently deleted.";
  setDeleteConfirmationBusy(false);
  modal.querySelector("[data-delete-confirm]").textContent = "Remove";
  modal.hidden = false;
  activateCompletedDeleteModal(modal, opener);
}

function showCompletedDeleteConfirmation(index, opener) {
  if (isCompletedDeleteActive) return;

  const item = completedFileSnapshot[index];
  const relativePath = completedItemRelativePath(item);
  if (!item || !relativePath) {
    setStatus("This completed item cannot be deleted.", true);
    return;
  }

  const folder = isCompletedFolder(item);
  const name = fileName(item);
  pendingDeleteHash = "";
  pendingDirectDeleteId = "";
  pendingCompletedDelete = {
    relativePath,
    folder,
  };

  const modal = getDeleteConfirmationModal();
  modal.querySelector("#deleteConfirmTitle").textContent = folder
    ? "Delete completed folder?"
    : "Delete completed file?";
  modal.querySelector("#deleteConfirmName").textContent = folder
    ? `${name} will be deleted, including all completed media inside this folder.`
    : `${name} will be deleted from Completed Files.`;
  setDeleteConfirmationBusy(false);
  modal.hidden = false;
  activateCompletedDeleteModal(modal, opener);
}

function hideDeleteConfirmation() {
  if (isCompletedDeleteActive) return;

  const modal = document.querySelector("#deleteConfirmModal");
  if (modal) modal.hidden = true;
  deactivateCompletedDeleteModal();
  pendingDeleteHash = "";
  pendingCompletedDelete = null;
  pendingDirectDeleteId = "";
}

function activateCompletedDeleteModal(modal, opener) {
  deactivateCompletedDeleteModal({ restoreFocus: false });
  completedDeleteModalOpener = opener instanceof HTMLElement ? opener : null;
  completedDeleteModalKeydownHandler = (event) => {
    if (event.key === "Escape") {
      if (isCompletedDeleteActive) return;
      event.preventDefault();
      hideDeleteConfirmation();
      return;
    }
    if (event.key !== "Tab") return;

    const focusableElements = [...modal.querySelectorAll(
      'button:not([disabled]), [href], input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])',
    )].filter((element) => !element.hidden);
    if (focusableElements.length === 0) {
      event.preventDefault();
      return;
    }

    const firstElement = focusableElements[0];
    const lastElement = focusableElements[focusableElements.length - 1];
    if (event.shiftKey && document.activeElement === firstElement) {
      event.preventDefault();
      lastElement.focus();
    } else if (!event.shiftKey && document.activeElement === lastElement) {
      event.preventDefault();
      firstElement.focus();
    } else if (!modal.contains(document.activeElement)) {
      event.preventDefault();
      firstElement.focus();
    }
  };
  document.addEventListener("keydown", completedDeleteModalKeydownHandler);
  modal.querySelector("[data-delete-cancel]")?.focus();
}

function deactivateCompletedDeleteModal({ restoreFocus = true } = {}) {
  if (completedDeleteModalKeydownHandler) {
    document.removeEventListener("keydown", completedDeleteModalKeydownHandler);
    completedDeleteModalKeydownHandler = null;
  }

  const opener = completedDeleteModalOpener;
  completedDeleteModalOpener = null;
  if (restoreFocus && opener?.isConnected) {
    opener.focus();
  }
}

function completedDeleteWarningSummary(warnings) {
  const warningLabels = [...new Set(warnings.map((warning) => {
    const normalized = warning.toLowerCase();
    if (normalized.includes("failed to delete") || normalized.includes("failed to remove")) {
      return "one or more files or folders could not be removed";
    }
    if (normalized.includes("refused to delete unsafe")) {
      return "an unsafe cleanup path was skipped";
    }
    if (normalized.includes("not found")) {
      return "the completed item was not found";
    }
    return "an additional cleanup warning was reported";
  }))];
  const shownWarnings = warningLabels.slice(0, 2);
  const remainingWarningCount = warningLabels.length - shownWarnings.length;
  return shownWarnings.length
    ? ` Warnings: ${shownWarnings.join("; ")}${remainingWarningCount > 0 ? `; ${remainingWarningCount} more` : ""}.`
    : "";
}

async function deleteCompletedItem(target) {
  if (isCompletedDeleteActive || !target?.relativePath) return;

  isCompletedDeleteActive = true;
  setDeleteConfirmationBusy(true);
  const itemLabel = target.folder ? "folder" : "file";
  setStatus(`Deleting completed ${itemLabel}...`);

  try {
    const result = await apiFetch(
      `/api/completed-files?path=${encodeURIComponent(target.relativePath)}`,
      { method: "DELETE" },
    );
    downloaderDataGeneration += 1;

    const removalArrays = [
      result?.deleted_file_paths,
      result?.deleted_folder_paths,
      result?.deleted_paths,
      result?.deleted_files,
      result?.deleted_folders,
    ].filter(Array.isArray);
    const numericRemovalValues = [
      result?.deleted_count,
      result?.removed_count,
      result?.files_deleted,
      result?.folders_deleted,
      typeof result?.deleted_files === "number" ? result.deleted_files : undefined,
      typeof result?.deleted_folders === "number" ? result.deleted_folders : undefined,
    ];
    const numericRemovedCount = numericRemovalValues.reduce(
      (total, value) => total + (Number.isFinite(value) && value > 0 ? value : 0),
      0,
    );
    const warnings = Array.isArray(result?.warnings)
      ? result.warnings.filter((warning) => typeof warning === "string" && warning.trim())
      : [];
    const warningSummary = completedDeleteWarningSummary(warnings);
    const removedItems = removalArrays.reduce((total, paths) => total + paths.length, 0)
      + numericRemovedCount;
    const explicitRemovalReport = removalArrays.length > 0
      || numericRemovalValues.some(Number.isFinite)
      || typeof result?.deleted === "boolean"
      || typeof result?.removed === "boolean"
      || typeof result?.deleted_path === "string";
    const successfulStatus = result?.status === "success"
      || result?.status === "deleted"
      || result?.status === "ok";
    const removedSomething = removedItems > 0
      || result?.deleted === true
      || result?.removed === true
      || result?.partial_success === true
      || (typeof result?.deleted_path === "string" && result.deleted_path.trim())
      || (successfulStatus && !explicitRemovalReport);
    const partialResult = result?.status === "partial"
      || result?.status === "failed"
      || result?.partial_success === true
      || warnings.length > 0;

    let outcomeMessage;
    let outcomeIsError;
    if (!removedSomething) {
      outcomeMessage = `Completed ${itemLabel} was not removed.${warningSummary}`;
      outcomeIsError = true;
    } else if (partialResult) {
      outcomeMessage = `Completed ${itemLabel} cleanup was partial.${warningSummary}`;
      outcomeIsError = true;
    } else {
      outcomeMessage = `Completed ${itemLabel} deleted.`;
      outcomeIsError = false;
    }
    setStatus(outcomeMessage, outcomeIsError);

    try {
      await refreshCompletedFiles();
    } catch (error) {
      setStatus(`${outcomeMessage} List refresh failed: ${error.message}`, true);
    }
  } finally {
    isCompletedDeleteActive = false;
    setDeleteConfirmationBusy(false);
    hideDeleteConfirmation();
  }
}

function handleDeleteConfirmationClick(event) {
  if (event.target.closest("[data-delete-cancel]")) {
    if (isCompletedDeleteActive) return;
    hideDeleteConfirmation();
    return;
  }

  if (event.target.closest("[data-delete-confirm]")) {
    if (pendingCompletedDelete) {
      const target = pendingCompletedDelete;
      deleteCompletedItem(target).catch((error) => setStatus(error.message, true));
      return;
    }

    if (pendingDirectDeleteId) {
      const id = pendingDirectDeleteId;
      hideDeleteConfirmation();
      handleDirectDownloadAction(id, "remove").catch((error) => setStatus(error.message, true));
      return;
    }

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
  const refreshGeneration = downloaderDataGeneration;
  const files = await apiFetch("/api/completed-files");
  if (refreshGeneration !== downloaderDataGeneration) return;
  renderCompletedFiles(Array.isArray(files) ? files : []);
  lastCompletedFilesRefreshAt = Date.now();
}

async function refreshAll({ quiet = false, fullReconciliation = true } = {}) {
  if (isRefreshing || isSubmitting) {
    if (fullReconciliation || !pendingRefreshMode) {
      pendingRefreshMode = fullReconciliation ? "full" : "torrent";
    }
    return;
  }

  if (fullReconciliation || pendingRefreshMode === "torrent") {
    pendingRefreshMode = "";
  }

  const refreshGeneration = downloaderDataGeneration;
  isRefreshing = true;
  refreshButton.disabled = true;
  if (!quiet) setStatus("Refreshing private backend...");

  try {
    let torrents;
    let files;
    let refreshedCompletedFiles = fullReconciliation;

    if (fullReconciliation) {
      [torrents, files] = await Promise.all([
        fetchTorrents(),
        apiFetch("/api/completed-files"),
      ]);
    } else {
      torrents = await fetchTorrents();
      if (refreshGeneration !== downloaderDataGeneration) return;

      const torrentData = Array.isArray(torrents) ? torrents : [];
      const completedFilesDue = Date.now() - lastCompletedFilesRefreshAt >= COMPLETED_FILES_POLL_MS;
      if (completedFilesDue || hasTorrentCompletionTransition(torrentData)) {
        files = await apiFetch("/api/completed-files");
        refreshedCompletedFiles = true;
      }
    }

    if (refreshGeneration !== downloaderDataGeneration) return;

    const torrentData = Array.isArray(torrents) ? torrents : [];
    rememberIncompleteTorrents(torrentData);
    renderTorrents(torrentData);
    setTorrentPollingOnline();
    lastSuccessfulTorrentRefreshAt = Date.now();
    if (refreshedCompletedFiles) {
      renderCompletedFiles(Array.isArray(files) ? files : []);
      lastCompletedFilesRefreshAt = Date.now();
    }
    if (!quiet) setStatus("Ready.");
  } catch (error) {
    if (refreshGeneration === downloaderDataGeneration) {
      if (error.isTorrentPollingFailure && isConnectivityErrorMessage(error.message)) {
        torrentList.classList.add("offline");
      }
      setStatus(error.message, true);
    }
  } finally {
    finishInitialTorrentLoad();
    renderLastUpdated();
    isRefreshing = false;
    refreshButton.disabled = false;

    if (pendingRefreshMode && !isSubmitting) {
      const fullReconciliation = pendingRefreshMode === "full";
      pendingRefreshMode = "";
      await refreshAll({ quiet: true, fullReconciliation });
    }
  }
}

addMagnetButton.addEventListener("click", () => {
  const submit = composerMode === "direct" ? addDirectDownload : addMagnet;
  submit().catch((error) => setStatus(error.message, true));
});
refreshButton.addEventListener("click", () => {
  refreshAll();
  refreshDirectDownloads();
  const trendsView = document.querySelector("#trendsView");
  if (trendsView && !trendsView.hidden) loadTrends({ force: true });
});

magnetLinkInput.addEventListener("keydown", (event) => {
  if ((event.ctrlKey || event.metaKey) && event.key === "Enter") {
    addMagnet().catch((error) => setStatus(error.message, true));
  }
});

torrentList.addEventListener("click", (event) => {
  const directButton = event.target.closest("[data-direct-action][data-direct-id]");
  if (directButton) {
    if (directButton.dataset.directAction === "remove") {
      showDirectDeleteConfirmation(directButton.dataset.directId, directButton);
    } else {
      handleDirectDownloadAction(
        directButton.dataset.directId,
        directButton.dataset.directAction,
      ).catch((error) => setStatus(error.message, true));
    }
    return;
  }

  const button = event.target.closest("[data-delete-hash]");
  if (!button) return;
  showDeleteConfirmation(button.dataset.deleteHash);
});

completedFiles.addEventListener("click", (event) => {
  const deleteButton = event.target.closest("[data-delete-completed-index]");
  if (deleteButton) {
    showCompletedDeleteConfirmation(Number(deleteButton.dataset.deleteCompletedIndex), deleteButton);
    return;
  }

  const copyButton = event.target.closest("[data-copy-index]");
  if (!copyButton) return;
  copyVlcLink(Number(copyButton.dataset.copyIndex)).catch((error) => setStatus(error.message, true));
});

installCloudBoxTheme();
installDirectDownloadComposer();
installTrendsHomeEntry();
renderInitialTorrentSkeletons();
refreshAll().finally(pollDirectDownloads);
window.setInterval(() => refreshAll({ quiet: true, fullReconciliation: false }), POLL_MS);
