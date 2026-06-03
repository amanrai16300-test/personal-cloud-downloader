const API_BASE_URL = "http://100.92.146.101:8000";
const POLL_MS = 5000;
const APP_JS_VERSION = "queue-order-2026-06-03";

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

function confirmDeleteTorrent(hash) {
  const torrent = cachedTorrents.find((item) => item.hash === hash);
  const name = torrent?.name || hash || "this download";
  return window.confirm(`Delete "${name}" and its files?`);
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
  const hash = button.dataset.deleteHash;
  if (!confirmDeleteTorrent(hash)) return;
  deleteTorrent(hash).catch((error) => setStatus(error.message, true));
});

completedFiles.addEventListener("click", (event) => {
  const button = event.target.closest("[data-copy-index]");
  if (!button) return;
  copyVlcLink(Number(button.dataset.copyIndex)).catch((error) => setStatus(error.message, true));
});

refreshAll();
window.setInterval(() => refreshAll({ quiet: true }), POLL_MS);
