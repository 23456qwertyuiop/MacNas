/* ==========================================================================
   MacNas 桌面（原生 JS，无任何依赖）
   - 桌面 + 任务栏 + 应用列表
   - 窗口管理器：可开多个窗口，拖动 / 缩放 / 最小化 / 最大化 / 关闭
   - 文件管理：可同时打开多个窗口，窗口之间拖拽移动/复制，拖入系统文件即上传
   ========================================================================== */
'use strict';

/* ---------------- 图标 ---------------- */
const svgIcon = (paths, extra) =>
  `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7"
        stroke-linecap="round" stroke-linejoin="round" ${extra || ''}>${paths}</svg>`;

const ICONS = {
  appFiles: svgIcon('<path d="M3 7.5A2 2 0 0 1 5 5.5h3.4a1 1 0 0 1 .8.4l1.2 1.7H19a2 2 0 0 1 2 2v6.9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>'),
  appInfo: svgIcon('<circle cx="12" cy="12" r="8.6"/><path d="M12 11v5.4M12 7.8h.01"/>'),
  folder: svgIcon('<path d="M3 7.5A2 2 0 0 1 5 5.5h3.4a1 1 0 0 1 .8.4l1.2 1.7H19a2 2 0 0 1 2 2v6.9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>'),
  folderPlus: svgIcon('<path d="M3 7.5A2 2 0 0 1 5 5.5h3.4a1 1 0 0 1 .8.4l1.2 1.7H19a2 2 0 0 1 2 2v6.9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><path d="M12 11v5M9.5 13.5h5"/>'),
  file: svgIcon('<path d="M14 3H7a1 1 0 0 0-1 1v16a1 1 0 0 0 1 1h10a1 1 0 0 0 1-1V7z"/><path d="M14 3v4h4"/>'),
  image: svgIcon('<rect x="3" y="4.5" width="18" height="15" rx="2.5"/><circle cx="9" cy="10" r="1.6"/><path d="M4.5 18l4.8-4.8 3.4 3.4 2.6-2.6L19.5 18"/>'),
  video: svgIcon('<rect x="3" y="5.5" width="13" height="13" rx="2.5"/><path d="M16 11l5-2.6v7.2L16 13z"/>'),
  audio: svgIcon('<path d="M9 17V6l10-2v11"/><circle cx="6.5" cy="17.5" r="2.5"/><circle cx="16.5" cy="15" r="2.5"/>'),
  archive: svgIcon('<rect x="3" y="4" width="18" height="5" rx="1.6"/><path d="M5 9v11h14V9"/><path d="M12 9.5v3"/>'),
  code: svgIcon('<path d="M9 8l-4 4 4 4"/><path d="M15 8l4 4-4 4"/>'),
  upload: svgIcon('<path d="M12 16.5V4.5"/><path d="M7.5 9L12 4.5 16.5 9"/><path d="M4 16.5v2A1.5 1.5 0 0 0 5.5 20h13a1.5 1.5 0 0 0 1.5-1.5v-2"/>'),
  download: svgIcon('<path d="M12 4.5v12"/><path d="M7.5 12L12 16.5 16.5 12"/><path d="M4 17v1.5A1.5 1.5 0 0 0 5.5 20h13a1.5 1.5 0 0 0 1.5-1.5V17"/>'),
  trash: svgIcon('<path d="M4 7h16"/><path d="M9.5 7V5.2A1.2 1.2 0 0 1 10.7 4h2.6a1.2 1.2 0 0 1 1.2 1.2V7"/><path d="M6.5 7l.9 12.1A1.5 1.5 0 0 0 8.9 20.5h6.2a1.5 1.5 0 0 0 1.5-1.4L17.5 7"/>'),
  pencil: svgIcon('<path d="M4 20h4L19 9l-4-4L4 16z"/><path d="M14.5 5.5l4 4"/>'),
  storage: svgIcon('<rect x="3" y="4" width="18" height="7" rx="2.4"/><rect x="3" y="13" width="18" height="7" rx="2.4"/><path d="M7 7.5h.01M7 16.5h.01"/>'),
  logout: svgIcon('<path d="M15 4.5h3A1.5 1.5 0 0 1 19.5 6v12a1.5 1.5 0 0 1-1.5 1.5h-3"/><path d="M10.5 8.5L7 12l3.5 3.5"/><path d="M7 12h9"/>'),
  refresh: svgIcon('<path d="M20 12a8 8 0 1 1-2.4-5.7"/><path d="M20 4v4.5h-4.5"/>'),
  close: svgIcon('<path d="M6.5 6.5l11 11M17.5 6.5l-11 11"/>'),
  minus: svgIcon('<path d="M6 12h12"/>'),
  square: svgIcon('<rect x="5.5" y="5.5" width="13" height="13" rx="2.5"/>'),
  check: svgIcon('<path d="M5 12.5l4.5 4.5L19 7.5"/>'),
  arrowUp: svgIcon('<path d="M12 19V6"/><path d="M6.5 11.5L12 6l5.5 5.5"/>'),
  link: svgIcon('<path d="M9.5 14.5l5-5"/><path d="M11 6.7l1.2-1.2a4 4 0 0 1 5.6 5.6l-1.2 1.2"/><path d="M13 17.3l-1.2 1.2a4 4 0 0 1-5.6-5.6l1.2-1.2"/>'),
  grid: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="3.5" width="7" height="7" rx="2"/><rect x="13.5" y="3.5" width="7" height="7" rx="2"/><rect x="3.5" y="13.5" width="7" height="7" rx="2"/><rect x="13.5" y="13.5" width="7" height="7" rx="2"/></svg>',
  list: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6.5h16M4 12h16M4 17.5h16"/></svg>',
  photos: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="3.5" y="5" width="17" height="14" rx="2.5"/><circle cx="9" cy="10" r="1.6"/><path d="m4.5 17 4.7-4.2 3.3 3 3-2.6 4 3.8"/></svg>',
  sort: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M7 4.5v15M7 19.5 4 16.5M7 19.5l3-3"/><path d="M13 6.5h7M13 11.5h5M13 16.5h3"/></svg>',
  more: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="12" cy="5.5" r="1.4"/><circle cx="12" cy="12" r="1.4"/><circle cx="12" cy="18.5" r="1.4"/></svg>',
  camera: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8.5h3l1.4-2h7.2l1.4 2H20a1.5 1.5 0 0 1 1.5 1.5v7A1.5 1.5 0 0 1 20 18.5H4A1.5 1.5 0 0 1 2.5 17v-7A1.5 1.5 0 0 1 4 8.5z"/><circle cx="12" cy="13" r="3.2"/></svg>',
  eye: svgIcon('<path d="M2.5 12S6 6.5 12 6.5 21.5 12 21.5 12 18 17.5 12 17.5 2.5 12 2.5 12z"/><circle cx="12" cy="12" r="2.6"/>'),
  sun: svgIcon('<circle cx="12" cy="12" r="4"/><path d="M12 3v2M12 19v2M3 12h2M19 12h2M5.6 5.6l1.4 1.4M17 17l1.4 1.4M18.4 5.6L17 7M7 17l-1.4 1.4"/>'),
  moon: svgIcon('<path d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5z"/>'),
  empty: svgIcon('<rect x="3.5" y="6.5" width="17" height="13" rx="3"/><path d="M3.5 11h17"/><path d="M8 15h8"/>'),
  apps: svgIcon('<rect x="3.5" y="3.5" width="7" height="7" rx="2"/><rect x="13.5" y="3.5" width="7" height="7" rx="2"/><rect x="3.5" y="13.5" width="7" height="7" rx="2"/><rect x="13.5" y="13.5" width="7" height="7" rx="2"/>'),
  move: svgIcon('<path d="M12 3v18M3 12h18"/><path d="M8.5 6.5L12 3l3.5 3.5M8.5 17.5L12 21l3.5-3.5M6.5 8.5L3 12l3.5 3.5M17.5 8.5L21 12l-3.5 3.5"/>'),
  share: svgIcon('<circle cx="17.5" cy="6" r="2.6"/><circle cx="6.5" cy="12" r="2.6"/><circle cx="17.5" cy="18" r="2.6"/><path d="M8.8 10.6l6.4-3.3M8.8 13.4l6.4 3.3"/>'),
  search: svgIcon('<circle cx="11" cy="11" r="6.2"/><path d="M15.6 15.6L20 20"/>'),
  locate: svgIcon('<path d="M12 21s6.5-5.6 6.5-10.4A6.5 6.5 0 0 0 5.5 10.6C5.5 15.4 12 21 12 21z"/><circle cx="12" cy="10.4" r="2.4"/>'),
  copy: svgIcon('<rect x="9" y="9" width="11" height="11" rx="2.4"/><path d="M15 5.5A1.5 1.5 0 0 0 13.5 4h-8A1.5 1.5 0 0 0 4 5.5v8A1.5 1.5 0 0 0 5.5 15"/>'),
  clock: svgIcon('<circle cx="12" cy="12" r="8.4"/><path d="M12 7.6V12l3 2"/>')
};

/* ---------------- 小工具 ---------------- */
const $ = (id) => document.getElementById(id);
const uid = () => Math.random().toString(36).slice(2) + Date.now().toString(36);

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function iconButton(icon, title, onClick, extraClass) {
  const button = el('button', 'icon-btn' + (extraClass ? ' ' + extraClass : ''));
  button.innerHTML = icon;
  button.title = title;
  button.setAttribute('aria-label', title);
  if (onClick) button.addEventListener('click', onClick);
  return button;
}

function fmtSize(bytes) {
  const n = Number(bytes) || 0;
  if (n < 1024) return n + ' B';
  const units = ['KB', 'MB', 'GB', 'TB', 'PB'];
  let value = n / 1024;
  let i = 0;
  // 用 1023.5 做进位阈值：1073740712 字节这种「差一点点到一个整数单位」的量，
  // 显示成 1.0 GB 比 1024 MB 更好读
  while (value >= 1023.5 && i < units.length - 1) { value /= 1024; i++; }
  return (value >= 10 ? value.toFixed(0) : value.toFixed(1)) + ' ' + units[i];
}

function fmtDate(iso) {
  const d = new Date(iso);
  if (isNaN(d)) return '';
  const pad = (x) => String(x).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function parentPath(path) {
  const parts = String(path || '/').split('/').filter(Boolean);
  if (!parts.length) return '/';
  parts.pop();
  return parts.length ? '/' + parts.join('/') : '/';
}

function joinPath(dir, name) {
  const base = String(dir || '/');
  return (base === '/' ? '' : base) + '/' + name;
}

function baseName(path) {
  const parts = String(path || '/').split('/').filter(Boolean);
  return parts.length ? parts[parts.length - 1] : '/';
}

function snackbar(text, kind) {
  const box = $('snackbar');
  const node = el('div', 'snack' + (kind ? ' ' + kind : ''), text);
  box.appendChild(node);
  setTimeout(() => {
    node.style.transition = 'opacity .2s ease';
    node.style.opacity = '0';
    setTimeout(() => node.remove(), 220);
  }, 3000);
}

function iconFor(file) {
  const mime = file.mime || '';
  if (file.isImage || mime.startsWith('image/')) return ICONS.image;
  if (mime.startsWith('video/')) return ICONS.video;
  if (mime.startsWith('audio/')) return ICONS.audio;
  const ext = (file.name.split('.').pop() || '').toLowerCase();
  if (['zip', 'rar', '7z', 'tar', 'gz', 'bz2'].includes(ext)) return ICONS.archive;
  if (['js', 'ts', 'json', 'html', 'css', 'swift', 'py', 'rb', 'go', 'java', 'c', 'cpp', 'sh', 'yml', 'yaml', 'xml', 'md'].includes(ext)) return ICONS.code;
  return ICONS.file;
}

/* ---------------- 请求 ---------------- */
async function api(path, options) {
  const opts = options || {};
  let url = path;
  if (opts.params) {
    const query = new URLSearchParams();
    Object.keys(opts.params).forEach((key) => {
      const value = opts.params[key];
      if (value !== undefined && value !== null) query.append(key, value);
    });
    const qs = query.toString();
    if (qs) url += '?' + qs;
  }
  const init = { method: opts.method || 'GET', credentials: 'same-origin', headers: {} };
  if (opts.body !== undefined && opts.body !== null) {
    init.headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(opts.body);
  }
  const res = await fetch(url, init);
  let data = null;
  try { data = await res.json(); } catch (e) { data = null; }
  if (res.status === 401) {
    showLockScreen();
    const err = new Error((data && data.error) || '登录状态已失效');
    err.status = 401;
    throw err;
  }
  if (!res.ok || (data && data.ok === false)) {
    const err = new Error((data && data.error) || ('请求失败（' + res.status + '）'));
    err.status = res.status;
    throw err;
  }
  return data;
}

/* 匿名访问分享时使用的请求封装：401 表示需要分享密码，而不是登录失效 */
async function apiPublic(path, options) {
  const opts = options || {};
  let url = path;
  if (opts.params) {
    const query = new URLSearchParams();
    Object.keys(opts.params).forEach((key) => {
      const value = opts.params[key];
      if (value !== undefined && value !== null) query.append(key, value);
    });
    const qs = query.toString();
    if (qs) url += '?' + qs;
  }
  const init = { method: opts.method || 'GET', credentials: 'same-origin', headers: {} };
  if (opts.body !== undefined && opts.body !== null) {
    init.headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(opts.body);
  }
  const res = await fetch(url, init);
  let data = null;
  try { data = await res.json(); } catch (e) { data = null; }
  if (!res.ok || (data && data.ok === false)) {
    const err = new Error((data && data.error) || ('请求失败（' + res.status + '）'));
    err.status = res.status;
    throw err;
  }
  return data;
}

/* ---------------- 全局状态 ---------------- */
const state = {
  username: '',
  volumes: [],
  sessions: []          // 所有打开的文件管理视图
};

/* ---------------- 锁屏（登录） ---------------- */
function showLockScreen() {
  $('desktop').classList.add('hidden');
  $('lockscreen').classList.remove('hidden');
  $('app-launcher').classList.add('hidden');
  setTimeout(() => $('login-user').focus(), 60);
}

async function showDesktop(username) {
  state.username = username || state.username;
  $('lockscreen').classList.add('hidden');
  $('desktop').classList.remove('hidden');
  const chip = $('tb-user');
  chip.textContent = state.username;
  setVisible(chip, !!state.username);
  await loadVolumes();
  loadStatus();
  // 恢复上次的窗口与布局；没有可恢复的就开一个文件管理器兜底
  refreshTrashBadge();
  const restored = Session.restore();
  if (!restored && state.sessions.length === 0) openFileManager({});
}

async function submitLogin(event) {
  event.preventDefault();
  const button = $('login-submit');
  const error = $('login-error');
  setVisible(error, false);
  button.disabled = true;
  button.textContent = '登录中…';
  try {
    const data = await api('/api/login', {
      method: 'POST',
      body: { username: $('login-user').value, password: $('login-pass').value }
    });
    $('login-pass').value = '';
    await showDesktop(data.username);
  } catch (err) {
    error.textContent = err.message;
    setVisible(error, true);
  } finally {
    button.disabled = false;
    button.textContent = '登录';
  }
}

async function logout() {
  try { await api('/api/logout', { method: 'POST' }); } catch (e) { /* 忽略 */ }
  WM.closeAll();
  state.sessions = [];
  showLockScreen();
}

async function loadVolumes() {
  const data = await api('/api/volumes');
  state.volumes = data.volumes || [];
}

async function loadStatus() {
  // 顺带把回收站数量同步到桌面角标（在 loadStatus 里统一做，避免多处轮询）
  try {
    const data = await api('/api/status');
    const chip = $('tb-stats');
    chip.textContent = `${data.volumeCount} 个目录 · ${data.fileCount} 条记录 · 已节省 ${fmtSize(data.savedBytes)}`;
    chip.title = `实际占用 ${fmtSize(data.physicalBytes)}，逻辑大小 ${fmtSize(data.logicalBytes)}`;
    setVisible(chip, true);
    state.trashCount = data.trashCount || 0;
    refreshTrashBadge();
  } catch (e) { /* 忽略 */ }
}

function volumeById(id) { return state.volumes.find((v) => v.id === id) || null; }

/* ---------------- 窗口管理器 ---------------- */
const WM = {
  items: [],
  zIndex: 20,

  open(app, options) {
    const opts = options || {};
    const measured = $('desktop-area').getBoundingClientRect();
    // 兜底：万一桌面还没显示（尺寸为 0），也要给出可用的窗口尺寸
    const area = {
      width: measured.width > 200 ? measured.width : (window.innerWidth || 1280),
      height: measured.height > 200 ? measured.height : ((window.innerHeight || 800) - 60)
    };
    const cascade = (this.items.length % 6) * 26;
    const width = Math.max(460, Math.min(opts.width || 900, area.width - 120));
    const height = Math.max(320, Math.min(opts.height || 580, area.height - 100));

    const win = {
      id: uid(),
      app,
      title: opts.title || app.name,
      minimized: false,
      maximized: false,
      rect: {
        left: Math.max(12, Math.round((area.width - width) / 2) - 60 + cascade),
        top: Math.max(8, Math.round((area.height - height) / 2) - 40 + cascade),
        width,
        height
      },
      savedRect: null
    };

    const node = el('section', 'win');
    node.dataset.winId = win.id;
    node.innerHTML =
      '<header class="win-bar">' +
        '<div class="win-title">' + app.icon + '<span class="win-title-text"></span></div>' +
        '<div class="win-buttons">' +
          '<button class="win-btn min" title="最小化">' + ICONS.minus + '</button>' +
          '<button class="win-btn max" title="最大化">' + ICONS.square + '</button>' +
          '<button class="win-btn close" title="关闭">' + ICONS.close + '</button>' +
        '</div>' +
      '</header>' +
      '<div class="win-body"></div>' +
      '<div class="win-resize"></div>';

    win.node = node;
    win.bar = node.querySelector('.win-bar');
    win.titleNode = node.querySelector('.win-title-text');
    win.body = node.querySelector('.win-body');
    win.titleNode.textContent = win.title;

    $('window-layer').appendChild(node);
    win.titleNode.textContent = win.title;
    this.applyRect(win);

    node.addEventListener('pointerdown', () => WM.focus(win), true);
    node.querySelector('.win-btn.min').addEventListener('click', (e) => { e.stopPropagation(); WM.minimize(win); });
    node.querySelector('.win-btn.max').addEventListener('click', (e) => { e.stopPropagation(); WM.toggleMaximize(win); });
    node.querySelector('.win-btn.close').addEventListener('click', (e) => { e.stopPropagation(); WM.close(win); });

    this.bindDrag(win);
    this.bindResize(win);

    this.items.push(win);
    this.focus(win);
    this.renderTaskbar();
    Session.scheduleSave();
    return win;
  },

  applyRect(win) {
    const node = win.node;
    if (win.maximized) {
      node.classList.add('maximized');
      node.style.left = '0px';
      node.style.top = '0px';
      node.style.width = '100%';
      node.style.height = '100%';
      return;
    }
    node.classList.remove('maximized');
    node.style.left = win.rect.left + 'px';
    node.style.top = win.rect.top + 'px';
    node.style.width = win.rect.width + 'px';
    node.style.height = win.rect.height + 'px';
    Session.scheduleSave();   // 拖动/缩放结束后（去抖）自动记住位置
  },

  bindDrag(win) {
    win.bar.addEventListener('pointerdown', (event) => {
      if (event.target.closest('.win-btn') || win.maximized) return;
      if (isNarrowScreen()) return;   // 手机上窗口是全屏的，不需要拖
      const area = $('desktop-area').getBoundingClientRect();
      const startX = event.clientX;
      const startY = event.clientY;
      const startLeft = win.rect.left;
      const startTop = win.rect.top;
      win.bar.setPointerCapture(event.pointerId);

      const onMove = (ev) => {
        const left = startLeft + (ev.clientX - startX);
        const top = startTop + (ev.clientY - startY);
        win.rect.left = Math.min(Math.max(left, -win.rect.width + 140), area.width - 120);
        win.rect.top = Math.min(Math.max(top, 0), area.height - 44);
        this.applyRect(win);
      };
      const onUp = () => {
        win.bar.removeEventListener('pointermove', onMove);
        win.bar.removeEventListener('pointerup', onUp);
        win.bar.removeEventListener('pointercancel', onUp);
      };
      win.bar.addEventListener('pointermove', onMove);
      win.bar.addEventListener('pointerup', onUp);
      win.bar.addEventListener('pointercancel', onUp);
    });
  },

  bindResize(win) {
    const handle = win.node.querySelector('.win-resize');
    handle.addEventListener('pointerdown', (event) => {
      event.stopPropagation();
      if (isNarrowScreen()) return;
      const startX = event.clientX;
      const startY = event.clientY;
      const startW = win.node.offsetWidth;
      const startH = win.node.offsetHeight;
      handle.setPointerCapture(event.pointerId);
      const onMove = (ev) => {
        win.rect.width = Math.max(460, startW + (ev.clientX - startX));
        win.rect.height = Math.max(320, startH + (ev.clientY - startY));
        this.applyRect(win);
      };
      const onUp = () => {
        handle.removeEventListener('pointermove', onMove);
        handle.removeEventListener('pointerup', onUp);
        handle.removeEventListener('pointercancel', onUp);
      };
      handle.addEventListener('pointermove', onMove);
      handle.addEventListener('pointerup', onUp);
      handle.addEventListener('pointercancel', onUp);
    });
  },

  focus(win) {
    if (win.minimized) win.minimized = false;
    win.node.classList.remove('minimized');
    this.items.forEach((item) => item.node.classList.toggle('focused', item === win));
    win.node.style.zIndex = String(++this.zIndex);
    this.activeId = win.id;
    this.renderTaskbar();
    Session.scheduleSave();
  },

  minimize(win) {
    win.minimized = true;
    win.node.classList.add('minimized');
    this.renderTaskbar();
    Session.scheduleSave();
  },

  toggleMaximize(win) {
    if (win.maximized) {
      win.maximized = false;
      if (win.savedRect) win.rect = win.savedRect;
    } else {
      win.savedRect = Object.assign({}, win.rect);
      win.maximized = true;
    }
    this.applyRect(win);
    Session.scheduleSave();
  },

  close(win) {
    if (win.onClose) { try { win.onClose(); } catch (e) { /* 忽略 */ } }
    win.node.remove();
    this.items = this.items.filter((item) => item !== win);
    state.sessions = state.sessions.filter((view) => view.win !== win);
    const next = this.items[this.items.length - 1];
    if (next) this.focus(next); else this.renderTaskbar();
    Session.scheduleSave();
  },

  closeAll() {
    this.items.slice().forEach((win) => this.close(win));
  },

  setTitle(win, text) {
    win.title = text;
    win.titleNode.textContent = text;
    this.renderTaskbar();
    Session.scheduleSave();   // 标题会跟着目录走，所以导航后也会被记住
  },

  renderTaskbar() {
    const box = $('tb-tasks');
    box.textContent = '';
    this.items.forEach((win) => {
      const button = el('button', 'tb-task' + (win.id === this.activeId ? ' active' : '') + (win.minimized ? ' minimized' : ''));
      button.innerHTML = win.app.icon;
      button.appendChild(el('span', null, win.title));
      button.title = win.title;
      button.addEventListener('click', () => {
        if (win.minimized || win.id !== this.activeId) this.focus(win);
        else this.minimize(win);
      });
      box.appendChild(button);
    });
  }
};

/* ---------------- 窗口布局记忆 ----------------
   把「开着哪些窗口、各自在哪、多大、在第几层、里面在看哪个目录」
   存进 localStorage，下次打开网页（或重新登录）自动还原，
   不用每次登录都重新把窗口摆一遍。 */
const Session = {
  key: 'macnas-session',
  enabled: true,
  restoring: false,
  timer: null,
  ready: false,

  init() {
    this.enabled = this.read().enabled;
    this.ready = true;
    this.updateButton();
    return this.enabled;
  },

  read() {
    try {
      const raw = JSON.parse(localStorage.getItem(this.key) || 'null');
      if (raw && typeof raw === 'object') {
        return {
          enabled: raw.enabled !== false,
          windows: Array.isArray(raw.windows) ? raw.windows : []
        };
      }
    } catch (e) { /* 数据损坏就当没有 */ }
    return { enabled: true, windows: [] };
  },

  write(data) {
    try {
      localStorage.setItem(this.key, JSON.stringify(data));
      return true;
    } catch (e) {
      return false;   // 例如隐私模式禁用了 localStorage
    }
  },

  /** 当前所有窗口的快照（含各应用自己的状态） */
  snapshot() {
    return WM.items.map((win) => {
      let extra = {};
      try { if (win.sessionState) extra = win.sessionState() || {}; } catch (e) { extra = {}; }
      return {
        app: win.app.id,
        title: win.title,
        rect: { left: win.rect.left, top: win.rect.top, width: win.rect.width, height: win.rect.height },
        maximized: !!win.maximized,
        minimized: !!win.minimized,
        z: Number(win.node.style.zIndex) || 0,
        extra
      };
    });
  },

  save() {
    if (!this.enabled || this.restoring) return false;
    const data = this.read();
    return this.write({ enabled: data.enabled, windows: this.snapshot() });
  },

  /** 拖动 / 缩放 / 导航过程中会被高频调用，所以去抖 */
  scheduleSave() {
    if (!this.enabled || this.restoring) return;
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.save(), 400);
  },

  setEnabled(on) {
    this.enabled = !!on;
    const data = this.read();
    if (this.enabled) {
      this.write({ enabled: true, windows: this.snapshot() });
    } else {
      this.write({ enabled: false, windows: [] });   // 关掉时顺手清空，免得下次又冒出来
    }
    this.updateButton();
    return this.enabled;
  },

  clear() {
    this.write({ enabled: this.enabled, windows: [] });
  },

  /** 按原来的层叠顺序把窗口一个个恢复出来，返回恢复的窗口数 */
  restore() {
    const data = this.read();
    if (!data.enabled) return 0;
    const entries = data.windows.filter((entry) => entry && APPS[entry.app]);
    if (!entries.length) return 0;

    this.restoring = true;
    let count = 0;
    let maxZ = 0;
    entries.slice().sort((a, b) => (a.z || 0) - (b.z || 0)).forEach((entry) => {
      const win = openApp(entry.app, entry);
      if (!win) return;
      count += 1;
      maxZ = Math.max(maxZ, Number(entry.z) || 0);
    });
    if (maxZ) WM.zIndex = Math.max(WM.zIndex, maxZ);
    this.restoring = false;

    // 让最上层的窗口拿到焦点
    const stacked = WM.items.slice().sort((a, b) => (Number(a.node.style.zIndex) || 0) - (Number(b.node.style.zIndex) || 0));
    if (stacked.length) WM.focus(stacked[stacked.length - 1]);
    return count;
  },

  icon() {
    return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">' +
      '<rect x="3.5" y="5" width="17" height="14" rx="2.5"/><path d="M3.5 9.5h17"/><path d="M9.5 9.5V19"/></svg>';
  },

  updateButton() {
    const button = $('session-btn');
    if (!button) return;
    button.innerHTML = this.icon();
    button.classList.toggle('on', this.enabled);
    button.title = this.enabled ? '已记住窗口布局（点击关闭）' : '未记住窗口布局（点击开启）';
    button.setAttribute('aria-label', button.title);
  }
};

/** 把存下来的位置/大小套回窗口，并做边界收敛（换屏幕尺寸后也不会跑到看不见的地方） */
function applySessionGeometry(win, saved) {
  const measured = $('desktop-area').getBoundingClientRect();
  const area = {
    width: measured.width > 200 ? measured.width : (window.innerWidth || 1280),
    height: measured.height > 200 ? measured.height : ((window.innerHeight || 800) - 60)
  };
  const rect = saved.rect || {};
  const width = Math.max(460, Math.min(Number(rect.width) || 900, area.width));
  const height = Math.max(320, Math.min(Number(rect.height) || 580, area.height));
  win.rect = {
    left: Math.max(-width + 140, Math.min(Number(rect.left) || 40, Math.max(0, area.width - 120))),
    top: Math.max(0, Math.min(Number(rect.top) || 30, Math.max(0, area.height - 44))),
    width,
    height
  };
  if (saved.maximized) {
    win.savedRect = Object.assign({}, win.rect);
    win.maximized = true;
  }
  WM.applyRect(win);
  if (saved.z) win.node.style.zIndex = String(saved.z);
  if (saved.minimized) WM.minimize(win);
}

/* ---------------- 空格快速查看（Quick Look 风格） ----------------
   按空格在浮层里看当前光标/选中的文件，再按空格或 Esc 关掉；
   开着的时候用方向键可以直接上下翻。 */
let quickLookState = null;

function openQuickLookForFocus(view, keepFocus) {
  const list = visibleEntries(view);
  if (!list.length) return;
  let entry = list.find((item) => item.key === view.focusKey);
  if (!entry && view.selection.size === 1) {
    const key = [...view.selection][0];
    entry = list.find((item) => item.key === key);
  }
  if (!entry) entry = list[0];
  if (entry.kind === 'folder') { snackbar('文件夹没有快速查看，按 Enter 打开', 'err'); return; }
  view.focusKey = entry.key;
  if (!keepFocus) {
    view.selection.clear();
    view.selection.add(entry.key);
    renderView(view);
  }
  openQuickLook(view, entry.item);
}

async function openQuickLook(view, file) {
  closeQuickLook();
  const overlay = el('div', 'ql-overlay glass');
  const shell = el('div', 'ql-inner');
  const bar = el('div', 'ql-bar');
  bar.appendChild(el('div', 'ql-name', file.name));
  const hint = el('div', 'ql-hint', '空格 / Esc 关闭 · 方向键切换');
  bar.appendChild(hint);
  shell.appendChild(bar);
  const canvas = el('div', 'ql-canvas');
  canvas.appendChild(el('div', 'pv-loading', '正在准备…'));
  shell.appendChild(canvas);
  overlay.appendChild(shell);
  overlay.addEventListener('click', (event) => { if (event.target === overlay) closeQuickLook(); });
  document.body.appendChild(overlay);
  quickLookState = { overlay, view };

  try {
    const meta = await fetchPreviewMeta({ volumeId: view.volumeId, id: file.id, path: file.logicalPath });
    canvas.textContent = '';
    canvas.appendChild(buildPreviewContent(meta, { scale: 'fit' }));
  } catch (err) {
    canvas.textContent = '';
    canvas.appendChild(el('div', 'pv-loading', '预览失败：' + err.message));
  }
}

function closeQuickLook() {
  if (!quickLookState) return;
  quickLookState.overlay.remove();
  quickLookState = null;
}

/* ---------------- 排序与多选 ----------------
   排序只在客户端做：目录内容本来就已经全在手上了，没必要多一次请求。
   多选支持勾选框、⌘/Ctrl 点选、Shift 连选，以及 ⌘A / Esc。 */

const SORT_KEYS = [
  { key: 'name', label: '名称' },
  { key: 'time', label: '修改时间' },
  { key: 'size', label: '大小' },
  { key: 'type', label: '类型' }
];

function sortLabel(view) {
  const key = (view.sort && view.sort.key) || 'name';
  const found = SORT_KEYS.find((item) => item.key === key);
  const arrow = (view.sort && view.sort.dir) === 'desc' ? '↓' : '↑';
  return (found ? found.label : '名称') + ' ' + arrow;
}

function sortItems(view, items, isFolder) {
  const key = (view.sort && view.sort.key) || 'name';
  const direction = (view.sort && view.sort.dir) === 'desc' ? -1 : 1;
  const collator = new Intl.Collator('zh-Hans-CN', { numeric: true, sensitivity: 'base' });
  const valueOf = (item) => {
    if (key === 'size') return isFolder ? (item.fileCount || 0) : Number(item.size || 0);
    if (key === 'time') {
      const time = new Date(item.createdAt || 0).getTime();
      return Number.isNaN(time) ? 0 : time;
    }
    if (key === 'type') {
      const dot = item.name.lastIndexOf('.');
      return dot > 0 ? item.name.slice(dot + 1).toLowerCase() : '';
    }
    return item.name;
  };
  return items.slice().sort((a, b) => {
    const left = valueOf(a);
    const right = valueOf(b);
    let result;
    if (typeof left === 'number' && typeof right === 'number') result = left - right;
    else result = collator.compare(String(left), String(right));
    if (result === 0) result = collator.compare(a.name, b.name);
    return result * direction;
  });
}

function showSortMenu(view, button) {
  const items = SORT_KEYS.map((entry) => ({
    label: entry.label + ((view.sort && view.sort.key) === entry.key ? ' ✓' : ''),
    icon: ICONS.sort,
    onClick: () => {
      const current = view.sort || { key: 'name', dir: 'asc' };
      view.sort = { key: entry.key, dir: current.key === entry.key && current.dir === 'asc' ? 'desc' : 'asc' };
      view.sortButton.textContent = sortLabel(view);
      renderView(view);
      Session.scheduleSave();
    }
  }));
  items.push({ separator: true });
  items.push({
    label: (view.sort && view.sort.dir) === 'desc' ? '改为升序' : '改为降序',
    icon: ICONS.sort,
    onClick: () => {
      const current = view.sort || { key: 'name', dir: 'asc' };
      view.sort = { key: current.key, dir: current.dir === 'desc' ? 'asc' : 'desc' };
      view.sortButton.textContent = sortLabel(view);
      renderView(view);
      Session.scheduleSave();
    }
  });
  showMenuFromButton(button, items);
}

/** 列表里可见的全部内容，顺序与屏幕一致（renderView 每次都会刷新它） */
function visibleEntries(view) {
  if (view.renderOrder) return view.renderOrder;
  return [
    ...view.folders.map((folder) => ({ kind: 'folder', key: 'dir:' + folder.path, item: folder })),
    ...view.files.map((file) => ({ kind: 'file', key: file.id, item: file }))
  ];
}

function selectAll(view) {
  view.selection.clear();
  visibleEntries(view).forEach((entry) => view.selection.add(entry.key));
  renderView(view);
}

/** Shift 连选：从锚点到当前项之间全选 */
function selectRange(view, key) {
  const list = visibleEntries(view);
  const anchor = view.anchorKey && list.findIndex((entry) => entry.key === view.anchorKey);
  const target = list.findIndex((entry) => entry.key === key);
  if (anchor === undefined || anchor < 0 || target < 0) { view.selection.add(key); return; }
  const from = Math.min(anchor, target);
  const to = Math.max(anchor, target);
  for (let index = from; index <= to; index++) view.selection.add(list[index].key);
}

function toggleSelectionKey(view, key) {
  if (view.selection.has(key)) view.selection.delete(key); else view.selection.add(key);
  view.anchorKey = key;
}

/** 多选时状态栏上出现批量操作 */
function renderSelectionBar(view) {
  const bar = view.statusEl;
  if (!view.selection.size) return;
  const wrap = el('span', 'sel-actions');
  const download = el('button', 'btn text', '打包下载');
  download.addEventListener('click', () => downloadSelectionZip(view));
  const move = el('button', 'btn text', '移动到…');
  move.addEventListener('click', () => openTransferDialog(view, 'move'));
  const copy = el('button', 'btn text', '复制到…');
  copy.addEventListener('click', () => openTransferDialog(view, 'copy'));
  const remove = el('button', 'btn text danger', '删除');
  remove.addEventListener('click', () => deleteSelection(view));
  const clear = el('button', 'btn text', '取消选择');
  clear.addEventListener('click', () => { view.selection.clear(); renderView(view); });
  [download, move, copy, remove, clear].forEach((button) => wrap.appendChild(button));
  bar.appendChild(wrap);
}

/** 打包下载：直接导航过去，让浏览器原生下载（不用把 zip 读进内存） */
function selectionZipURL(view) {
  const payload = selectionPayload(view);
  if (!payload.ids.length && !payload.paths.length) return null;
  const query = new URLSearchParams({
    payload: JSON.stringify({ volume: payload.volumeId, ids: payload.ids, paths: payload.paths })
  });
  return '/api/zip?' + query.toString();
}

function downloadSelectionZip(view) {
  const url = selectionZipURL(view);
  if (!url) { snackbar('请先选择要打包的内容', 'err'); return; }
  snackbar('正在打包 ' + view.selection.size + ' 项…', 'ok');
  window.location.href = url;
}

/** 批量移动/复制：复用「复制到…」的目标选择器 */
function openTransferDialog(view, mode) {
  if (!view.selection.size) { snackbar('请先选择内容', 'err'); return; }
  copyToDialog(view, null, mode);
}

/* ---------------- 手机端与 PWA ---------------- */

/** 是否窄屏（手机）——界面要按触摸与竖屏来适配 */
function isNarrowScreen() {
  return window.matchMedia && window.matchMedia('(max-width: 720px)').matches;
}

/** 手机上没有右键，用行尾的「⋯」按钮打开同一套菜单 */
function touchMenuButton(open) {
  const button = el('button', 'icon-btn row-more');
  button.innerHTML = ICONS.more;
  button.title = '更多操作';
  button.addEventListener('click', (event) => { event.stopPropagation(); open(button); });
  return button;
}

/** 从菜单按钮的位置弹出上下文菜单 */
function showMenuFromButton(button, items) {
  const rect = button.getBoundingClientRect();
  showContextMenu(items, Math.max(8, rect.right - 200), rect.bottom + 6);
}

/** 拍照/选图直接上传（手机上会直接打开相机） */
/** 上传菜单：文件 / 整个文件夹（保留目录结构）/ 拍照 */
function showUploadMenu(view, button) {
  showMenuFromButton(button, [
    { label: '上传文件', icon: ICONS.upload, onClick: () => pickFiles(view) },
    { label: '上传文件夹', icon: ICONS.folder, onClick: () => pickFolder(view) },
    { label: '拍照上传', icon: ICONS.camera, onClick: () => pickPhotos(view) }
  ]);
}

/** 打开系统文件选择器（选文件 / 选文件夹 / 拍照都走这里）。
 *
 *  注意：iOS Safari 要求 input 元素**已经挂在文档里**，click() 才会真正弹出选择器。
 *  只 createElement 不 appendChild 的话，手机上第一次点击会被静默忽略 ——
 *  表现就是「点了上传，照片根本没进列表」。这个坑必须靠 appendChild 绕开。
 */
function openFilePicker(options) {
  const input = document.createElement('input');
  input.type = 'file';
  if (options.accept) input.accept = options.accept;
  if (options.multiple) input.multiple = true;
  if (options.directory) {
    input.setAttribute('webkitdirectory', '');
    input.setAttribute('directory', '');
  }
  if (options.capture) input.setAttribute('capture', options.capture);
  input.style.display = 'none';
  input.setAttribute('aria-hidden', 'true');
  document.body.appendChild(input);
  let done = false;
  const cleanup = () => {
    if (done) return;
    done = true;
    try { input.remove(); } catch (e) { /* 忽略 */ }
  };
  input.addEventListener('change', () => {
    const files = [...input.files].filter(Boolean);
    cleanup();
    if (files.length) options.onFiles(files);
  });
  // 用户取消时不会触发 change，用一个兜底定时器收掉隐藏节点
  setTimeout(cleanup, 120000);
  input.click();
  return input;
}

/** 选整个文件夹：会按原有目录结构在目标位置建好目录 */
function pickFolder(view) {
  openFilePicker({
    multiple: true,
    directory: true,
    onFiles: (files) => {
      // webkitRelativePath 形如「我的文件夹/子目录/文件.txt」，第一段是选择的根目录本身，
      // 这里把根目录也保留下来，结构完全一致
      const entries = files.map((file) => {
        const relative = file.webkitRelativePath || file.name;
        const parts = relative.split('/');
        parts.pop();
        return { file, relPath: parts.join('/') };
      });
      enqueueUploads(entries, view.volumeId, view.path);
      snackbar('已加入 ' + entries.length + ' 个文件（保留目录结构）', 'ok');
    }
  });
}

function pickPhotos(view) {
  openFilePicker({
    accept: 'image/*,video/*',
    multiple: true,
    capture: 'environment',
    onFiles: (files) => {
      enqueueUploads(files.map((file) => ({ file, relPath: '' })), view.volumeId, view.path);
    }
  });
}

/** 当前加载的前端版本（资源地址上的内容指纹）。
    排查「服务端更新了、用户还在跑旧代码」时，这个值一眼就能看出来。 */
function frontendVersion() {
  const tag = document.querySelector('script[src*="app.js"]');
  const source = (tag && tag.getAttribute('src')) || '';
  const match = source.match(/v=([a-f0-9]+)/);
  return match ? match[1] : '未标记';
}

function registerServiceWorker() {
  if (!('serviceWorker' in navigator)) return;
  // 只在正常网页环境下注册（file:// 或隐私模式下会失败，忽略即可）
  if (location.protocol !== 'http:' && location.protocol !== 'https:') return;
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/sw.js').then((registration) => {
      // 主动问一次有没有新版本，别等到下次冷启动
      registration.update().catch(() => { /* 忽略 */ });
    }).catch(() => { /* 忽略 */ });
  });

  // 新版本 Service Worker 接管后刷新一次：
  // 否则「外壳已经换新、页面还在跑旧 app.js」会出现一半按钮失灵这种诡异状态。
  const hadController = !!navigator.serviceWorker.controller;
  let reloading = false;
  navigator.serviceWorker.addEventListener('controllerchange', () => {
    if (reloading || !hadController) return;   // 首次安装时页面本来就是最新的
    let guard = null;
    try { guard = sessionStorage.getItem('macnas-sw-reloaded'); } catch (e) { guard = null; }
    if (guard === '1') return;                 // 防止极端情况下反复刷新
    try { sessionStorage.setItem('macnas-sw-reloaded', '1'); } catch (e) { /* 忽略 */ }
    reloading = true;
    location.reload();
  });
}

/* ---------------- 缩略图加载器 ----------------
   照片墙/网格一次会有几十个格子，如果每个 <img> 直接指 src，浏览器会同时发几十个请求，
   服务端转换槽位会被瞬间打满、后面的要排很久。
   这里统一排队：进入可视区域才加载，同时最多 4 个并发。 */
const thumbLoader = {
  queue: [],
  active: 0,
  limit: 4,
  observer: null,

  ensureObserver() {
    if (this.observer || !('IntersectionObserver' in window)) return;
    this.observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        this.observer.unobserve(entry.target);
        const job = entry.target.__thumbJob;
        if (job) this.queue.push(job);
      });
      this.pump();
    }, { rootMargin: '240px' });
  },

  schedule(image, url) {
    image.__thumbUrl = url;
    const job = () => {
      if (!image.isConnected || image.__thumbUrl !== url) { this.done(); return; }
      image.src = url;
      const finish = () => { image.removeEventListener('load', finish); image.removeEventListener('error', finish); this.done(); };
      image.addEventListener('load', finish);
      image.addEventListener('error', finish);
    };
    this.ensureObserver();
    if (this.observer) {
      image.__thumbJob = job;
      this.observer.observe(image);
    } else {
      this.queue.push(job);
      this.pump();
    }
  },

  pump() {
    while (this.active < this.limit && this.queue.length) {
      const job = this.queue.shift();
      this.active += 1;
      try { job(); } catch (e) { this.active -= 1; }
    }
  },

  done() {
    this.active = Math.max(0, this.active - 1);
    this.pump();
  }
};

/* ---------------- 文件管理视图 ---------------- */
function openFileManager(props) {
  const options = props || {};
  const win = WM.open(APPS.files, { title: options.title || '文件管理' });
  const view = buildFileManager(win, options);
  win.onClose = () => { state.sessions = state.sessions.filter((v) => v !== view); };
  // 布局记忆：记住这个窗口在看哪个卷的哪个目录
  win.sessionState = () => ({ volumeId: view.volumeId, path: view.path, mode: view.mode, sort: view.sort });
  return view;
}

function refreshAllFileManagers() {
  state.sessions.forEach((view) => refreshView(view));
}

async function refreshView(view) {
  if (view.volumeId === null) {
    view.volumes = state.volumes;
    renderView(view);
    return;
  }
  view.loading = true;
  renderView(view);
  try {
    const data = await api('/api/list', { params: { volume: view.volumeId, path: view.path } });
    view.path = data.path;
    view.crumbs = data.breadcrumbs || [];
    view.folders = data.folders || [];
    view.files = data.files || [];
    view.error = null;
    const volume = volumeById(view.volumeId);
    WM.setTitle(view.win, '文件管理 · ' + (volume ? volume.name : '') + (view.path === '/' ? '' : view.path));
  } catch (err) {
    if (err.status !== 401) view.error = err.message;
    view.folders = [];
    view.files = [];
  } finally {
    view.loading = false;
    renderView(view);
  }
}

function buildFileManager(win, props) {
  const view = {
    win,
    volumeId: props.volumeId || null,
    path: props.path || '/',
    mode: props.mode === 'grid' ? 'grid' : 'list',
    sort: props.sort && props.sort.key ? props.sort : { key: 'name', dir: 'asc' },
    anchorKey: null,
    focusKey: null,
    crumbs: [],
    folders: [],
    files: [],
    volumes: state.volumes.slice(),
    selection: new Set(),
    loading: false,
    error: null
  };

  const body = win.body;
  body.textContent = '';
  const fm = el('div', 'fm');
  const toolbar = el('div', 'fm-toolbar');
  const upButton = iconButton(ICONS.arrowUp, '上一级', () => {
    if (view.volumeId === null) return;
    if (view.path === '/') {
      view.volumeId = null;
      view.selection.clear();
      view.error = null;
      refreshView(view);
      return;
    }
    navigateTo(view, view.volumeId, parentPath(view.path));
  });
  const crumbs = el('nav', 'crumbs');
  const actions = el('div', 'fm-actions');
  const pasteButton = el('button', 'btn text');
  pasteButton.addEventListener('click', () => pasteInto(view, view.path));
  const mkdirButton = el('button', 'btn text', '新建文件夹');
  mkdirButton.addEventListener('click', () => makeFolder(view));
  const uploadButton = el('button', 'btn filled');
  uploadButton.innerHTML = ICONS.upload + '<span>上传</span>';
  uploadButton.addEventListener('click', () => showUploadMenu(view, uploadButton));
  // 手机上再给一个直接调用相机的入口
  const cameraButton = el('button', 'btn text camera-btn');
  cameraButton.innerHTML = ICONS.camera + '<span>拍照</span>';
  cameraButton.addEventListener('click', () => pickPhotos(view));
  const viewButton = iconButton(ICONS.grid, '切换网格/列表视图', () => {
    view.mode = view.mode === 'grid' ? 'list' : 'grid';
    viewButton.innerHTML = view.mode === 'grid' ? ICONS.list : ICONS.grid;
    viewButton.title = view.mode === 'grid' ? '切换到列表视图' : '切换到网格（缩略图）视图';
    renderView(view);
    Session.scheduleSave();
  });
  viewButton.innerHTML = view.mode === 'grid' ? ICONS.list : ICONS.grid;
  const refreshButton = iconButton(ICONS.refresh, '刷新', () => refreshView(view));
  actions.appendChild(pasteButton);
  actions.appendChild(mkdirButton);
  const sortButton = el('button', 'btn text sort-btn', sortLabel(view));
  sortButton.addEventListener('click', () => showSortMenu(view, sortButton));
  view.sortButton = sortButton;
  actions.appendChild(uploadButton);
  actions.appendChild(cameraButton);
  actions.appendChild(sortButton);
  actions.appendChild(viewButton);
  actions.appendChild(refreshButton);
  toolbar.appendChild(upButton);
  toolbar.appendChild(crumbs);
  toolbar.appendChild(actions);

  const listEl = el('div', 'fm-body');
  const statusEl = el('div', 'fm-status');

  fm.appendChild(toolbar);
  fm.appendChild(listEl);
  fm.appendChild(statusEl);
  body.appendChild(fm);

  view.crumbsEl = crumbs;
  view.listEl = listEl;
  view.statusEl = statusEl;
  view.uploadButton = uploadButton;
  view.mkdirButton = mkdirButton;
  view.pasteButton = pasteButton;

  bindDropZone(listEl, view, () => view.path);
  listEl.addEventListener('contextmenu', (event) => {
    if (event.target.closest('.row')) return;
    event.preventDefault();
    showContextMenu(blankContextItems(view), event.clientX, event.clientY);
  });
  state.sessions.push(view);
  refreshView(view);
  return view;
}

function renderView(view) {
  const list = view.listEl;
  list.textContent = '';

  // 面包屑
  view.crumbsEl.textContent = '';
  const rootCrumb = el('button', 'crumb', view.volumeId === null ? '这台 Mac' : '根目录');
  rootCrumb.addEventListener('click', () => {
    if (view.volumeId === null) return;
    navigateTo(view, view.volumeId, '/');
  });
  view.crumbsEl.appendChild(rootCrumb);
  if (view.volumeId !== null) {
    (view.crumbs || []).slice(1).forEach((crumb) => {
      view.crumbsEl.appendChild(el('span', 'crumb-sep', '/'));
      const button = el('button', 'crumb' + (crumb.path === view.path ? ' current' : ''), crumb.name);
      button.addEventListener('click', () => navigateTo(view, view.volumeId, crumb.path));
      view.crumbsEl.appendChild(button);
    });
  }

  const isRoot = view.volumeId === null;
  view.mkdirButton.disabled = isRoot;
  view.uploadButton.disabled = isRoot;

  if (view.loading) {
    list.appendChild(el('div', 'fm-loading', '正在读取…'));
    updateStatus(view);
    return;
  }
  if (view.error) {
    const box = el('div', 'fm-error');
    box.appendChild(el('h3', null, '读不到这个目录'));
    box.appendChild(el('p', null, view.error));
    const retry = el('button', 'btn text', '重试');
    retry.addEventListener('click', () => refreshView(view));
    box.appendChild(retry);
    list.appendChild(box);
    updateStatus(view);
    return;
  }

  if (isRoot) {
    list.classList.remove('grid-mode');
    renderVolumeRows(view, list);
    updateStatus(view);
    return;
  }

  const volume = volumeById(view.volumeId);
  if (volume && volume.readOnly) {
    list.appendChild(el('div', 'readonly-banner', '这个目录由更新版本的 MacNas 写入，当前版本以只读方式打开（可浏览、可下载，不会改写内容）。'));
  }
  if (volume && volume.rebuilt) {
    list.appendChild(el('div', 'readonly-banner', '这个目录的索引是按内容哈希重建的，文件名无法还原，已用 recovered-<哈希前8位> 命名。'));
  }

  const total = view.folders.length + view.files.length;
  if (!total) {
    const empty = el('div', 'fm-empty');
    empty.innerHTML = ICONS.empty;
    empty.appendChild(el('h3', null, '这里还没有文件'));
    empty.appendChild(el('p', null, '把文件或文件夹拖进这个窗口，或者点右上角「上传」'));
    list.appendChild(empty);
    updateStatus(view);
    return;
  }

  const sortedFolders = sortItems(view, view.folders, true);
  const sortedFiles = sortItems(view, view.files, false);
  // 记住屏幕上真实的顺序：Shift 连选和方向键都必须按「看到的顺序」走，
  // 否则一旦换了排序方式，连选就会选到错误的区间
  view.renderOrder = [
    ...sortedFolders.map((folder) => ({ kind: 'folder', key: 'dir:' + folder.path, item: folder })),
    ...sortedFiles.map((file) => ({ kind: 'file', key: file.id, item: file }))
  ];
  if (view.sortButton) view.sortButton.textContent = sortLabel(view);
  if (view.mode === 'grid') {
    list.classList.add('grid-mode');
    const grid = el('div', 'fm-grid');
    sortedFolders.forEach((folder) => grid.appendChild(gridCell(view, folder, true)));
    sortedFiles.forEach((file) => grid.appendChild(gridCell(view, file, false)));
    list.appendChild(grid);
  } else {
    list.classList.remove('grid-mode');
    sortedFolders.forEach((folder) => list.appendChild(folderRow(view, folder)));
    sortedFiles.forEach((file) => list.appendChild(fileRow(view, file)));
  }
  updateStatus(view);
  if (view.revealName) setTimeout(() => applyReveal(view), 30);
}

function renderVolumeRows(view, list) {
  if (!view.volumes.length) {
    const empty = el('div', 'fm-empty');
    empty.innerHTML = ICONS.empty;
    empty.appendChild(el('h3', null, '还没有可用的目录'));
    empty.appendChild(el('p', null, '请先在 Mac 上的 MacNas 软件里添加目录'));
    list.appendChild(empty);
    return;
  }
  view.volumes.forEach((volume) => {
    const row = el('div', 'row');
    row.appendChild(el('div', 'row-check'));
    const icon = el('div', 'row-icon volume');
    icon.innerHTML = volume.readOnly ? ICONS.link : ICONS.storage;
    row.appendChild(icon);

    const main = el('div', 'row-main');
    main.appendChild(el('div', 'row-name', volume.name));
    const sub = el('div', 'row-sub');
    sub.appendChild(el('span', null, volume.available ? `${volume.fileCount} 条记录 · ${fmtSize(volume.physicalBytes)}` : '不可用（磁盘未挂载？）'));
    if (typeof volume.freeBytes === 'number') sub.appendChild(el('span', null, `剩余 ${fmtSize(volume.freeBytes)}`));
    sub.appendChild(el('span', null, volume.path));
    if (volume.readOnly) {
      const tag = el('span', 'tag warn', '只读');
      sub.appendChild(tag);
    }
    main.appendChild(sub);
    main.addEventListener('click', () => navigateTo(view, volume.id, '/'));
    row.appendChild(main);
    row.addEventListener('dblclick', () => navigateTo(view, volume.id, '/'));
    list.appendChild(row);
  });
}

function navigateTo(view, volumeId, path) {
  view.volumeId = volumeId;
  view.path = path || '/';
  view.selection.clear();
  view.error = null;
  refreshView(view);
}

function folderRow(view, folder) {
  const row = el('div', 'row');
  const key = 'dir:' + folder.path;
  const check = el('button', 'row-check');
  check.title = '选择';
  check.addEventListener('click', (event) => { event.stopPropagation(); toggleSelection(view, key); });
  row.appendChild(check);
  markCheck(check, view.selection.has(key));

  const icon = el('div', 'row-icon folder');
  icon.innerHTML = ICONS.folder;
  row.appendChild(icon);

  const main = el('div', 'row-main');
  main.appendChild(el('div', 'row-name', folder.name));
  main.appendChild(el('div', 'row-sub', folder.fileCount + ' 个文件'));
  main.addEventListener('click', (event) => {
    const folderKey = 'dir:' + folder.path;
    view.focusKey = folderKey;
    if (event.shiftKey) { event.preventDefault(); selectRange(view, folderKey); renderView(view); return; }
    if (event.metaKey || event.ctrlKey) { event.preventDefault(); toggleSelectionKey(view, folderKey); renderView(view); return; }
    navigateTo(view, view.volumeId, folder.path);
  });
  row.appendChild(main);
  row.addEventListener('contextmenu', (event) => {
    event.preventDefault();
    if (!view.selection.has(key)) { view.selection.clear(); view.selection.add(key); renderView(view); }
    showContextMenu(folderContextItems(view, folder), event.clientX, event.clientY);
  });

  const actions = el('div', 'row-actions');
  actions.appendChild(iconButton(ICONS.copy, '复制', (e) => { e.stopPropagation(); copyToClipboard(view, 'copy', { kind: 'folder', folder }); }));
  actions.appendChild(iconButton(ICONS.share, '分享', (e) => { e.stopPropagation(); shareEntry(view, { kind: 'folder', folder }); }));
  actions.appendChild(iconButton(ICONS.pencil, '重命名', (e) => { e.stopPropagation(); renameFolder(view, folder); }));
  actions.appendChild(iconButton(ICONS.trash, '删除', (e) => { e.stopPropagation(); removeFolder(view, folder); }, 'danger'));
  row.appendChild(actions);

  makeDraggable(row, view, () => folderDragPayload(view, folder));
  bindDropZone(row, view, () => folder.path, row);
  return row;
}

/** 网格视图里的一个格子：媒体显示缩略图，其它显示图标 */
function gridCell(view, item, isFolder) {
  const cell = el('div', 'grid-cell');
  cell.dataset.name = item.name;
  const art = el('div', 'grid-art');

  if (!isFolder && isMediaName(item.name)) {
    const image = el('img', 'grid-thumb');
    image.loading = 'lazy';
    image.alt = item.name;
    image.decoding = 'async';
    thumbLoader.schedule(image, '/api/thumbnail?' + new URLSearchParams({ volume: view.volumeId, id: item.id, size: '320' }));
    image.addEventListener('error', () => {
      art.classList.add('no-thumb');
      art.innerHTML = iconFor(item);
    });
    art.appendChild(image);
    const badge = el('button', 'grid-badge');
    badge.innerHTML = ICONS.eye;
    badge.title = '预览';
    badge.addEventListener('click', (event) => { event.stopPropagation(); previewFile(view, item); });
    cell.appendChild(badge);
  } else {
    art.innerHTML = isFolder ? ICONS.folder : iconFor(item);
    if (isFolder) art.classList.add('folder');
  }
  cell.appendChild(art);
  cell.appendChild(el('div', 'grid-name', item.name));

  cell.addEventListener('click', (event) => {
    const key = isFolder ? 'dir:' + item.path : item.id;
    view.focusKey = key;
    if (event.shiftKey) { event.preventDefault(); selectRange(view, key); renderView(view); return; }
    if (event.metaKey || event.ctrlKey) { event.preventDefault(); toggleSelectionKey(view, key); renderView(view); return; }
    if (isFolder) navigateTo(view, view.volumeId, item.path);
    else if (looksPreviewable(item.name)) previewFile(view, item);
    else downloadFile(view, item);
  });
  cell.addEventListener('contextmenu', (event) => {
    event.preventDefault();
    const payload = isFolder ? { kind: 'folder', folder: item } : { kind: 'file', file: item };
    showContextMenu(isFolder ? folderContextItems(view, item) : fileContextItems(view, item),
                    event.clientX, event.clientY);
    void payload;
  });
  makeDraggable(cell, view, () => (isFolder ? folderDragPayload(view, item) : fileDragPayload(view, item)));
  return cell;
}

function isMediaName(name) {
  const kind = previewKindOf(name);
  return kind === 'image' || kind === 'video';
}

function fileRow(view, file) {
  const row = el('div', 'row' + (view.selection.has(file.id) ? ' selected' : ''));
  const check = el('button', 'row-check');
  check.title = '选择';
  check.addEventListener('click', (event) => { event.stopPropagation(); toggleSelection(view, file.id); });
  row.appendChild(check);
  markCheck(check, view.selection.has(file.id));

  const icon = el('div', 'row-icon');
  icon.innerHTML = iconFor(file);
  row.appendChild(icon);

  const main = el('div', 'row-main');
  main.appendChild(el('div', 'row-name', file.name));
  const sub = el('div', 'row-sub');
  sub.appendChild(el('span', null, fmtSize(file.size)));
  sub.appendChild(el('span', null, fmtDate(file.createdAt)));
  if (file.deduplicated) {
    const tag = el('span', 'tag', '已去重 ×' + file.refCount);
    tag.title = '相同内容的文件全局只保存一份，这条记录指向已有内容';
    sub.appendChild(tag);
  }
  main.appendChild(sub);
  main.addEventListener('click', (event) => {
    view.focusKey = file.id;
    if (event.shiftKey) { event.preventDefault(); selectRange(view, file.id); renderView(view); return; }
    if (event.metaKey || event.ctrlKey) { event.preventDefault(); toggleSelectionKey(view, file.id); renderView(view); return; }
    if (looksPreviewable(file.name)) previewFile(view, file); else downloadFile(view, file);
  });
  row.appendChild(main);
  row.addEventListener('contextmenu', (event) => {
    event.preventDefault();
    if (!view.selection.has(file.id)) { view.selection.clear(); view.selection.add(file.id); renderView(view); }
    showContextMenu(fileContextItems(view, file), event.clientX, event.clientY);
  });

  const actions = el('div', 'row-actions');
  const previewable = looksPreviewable(file.name);
  actions.appendChild(iconButton(previewable ? ICONS.eye : ICONS.download, previewable ? '预览' : '下载',
    (e) => { e.stopPropagation(); if (previewable) previewFile(view, file); else downloadFile(view, file); }));
  actions.appendChild(iconButton(ICONS.copy, '复制', (e) => { e.stopPropagation(); copyToClipboard(view, 'copy', { kind: 'file', file }); }));
  actions.appendChild(iconButton(ICONS.share, '分享', (e) => { e.stopPropagation(); shareEntry(view, { kind: 'file', file }); }));
  actions.appendChild(iconButton(ICONS.pencil, '重命名', (e) => { e.stopPropagation(); renameFile(view, file); }));
  actions.appendChild(touchMenuButton((button) => showMenuFromButton(button, fileContextItems(view, file))));
  row.appendChild(actions);

  makeDraggable(row, view, () => fileDragPayload(view, file));
  return row;
}

function markCheck(button, on) {
  button.classList.toggle('on', !!on);
  button.innerHTML = on ? ICONS.check : '';
}

function toggleSelection(view, key) {
  if (view.selection.has(key)) view.selection.delete(key); else view.selection.add(key);
  renderView(view);
}

function updateStatus(view) {
  const status = view.statusEl;
  status.textContent = '';
  if (view.volumeId === null) {
    status.appendChild(el('span', null, state.volumes.length + ' 个目录'));
  } else {
    status.appendChild(el('span', null, `${view.folders.length} 个文件夹 · ${view.files.length} 个文件`));
    if (view.selection.size) {
      status.appendChild(el('span', null, `已选 ${view.selection.size} 项`));
      renderSelectionBar(view);
    }
  }
  // 粘贴按钮：剪贴板有内容且当前目录可写时才可用
  if (view.pasteButton) {
    const volume = view.volumeId ? volumeById(view.volumeId) : null;
    const writable = !!view.volumeId && !(volume && volume.readOnly);
    const count = clipboardCount();
    view.pasteButton.textContent = count ? ('粘贴 ' + count + ' 项') : '粘贴';
    view.pasteButton.disabled = !count || !writable;
    view.pasteButton.title = count
      ? (fileClipboard.mode === 'cut' ? '移动到这里' : '复制到这里')
      : '先用「复制」或「剪切」选择内容';
  }

  if (clipboardHasItems() && view.volumeId) {
    const chip = el('span');
    chip.style.color = 'var(--primary)';
    chip.style.fontWeight = '600';
    chip.textContent = '剪贴板：' + clipboardCount() + ' 项 · ' + (fileClipboard.mode === 'cut' ? '剪切（将移动）' : '复制');
    status.appendChild(chip);
    const cancel = el('button', 'btn text', '取消');
    cancel.addEventListener('click', clearClipboard);
    status.appendChild(cancel);
  }

  const spacer = el('span', 'spacer');
  status.appendChild(spacer);

  if (view.selection.size) {
    const downloadButton = el('button', 'btn text', '下载所选');
    downloadButton.addEventListener('click', () => {
      const ids = [...view.selection].filter((key) => !key.startsWith('dir:'));
      ids.forEach((id, index) => {
        const file = view.files.find((item) => item.id === id);
        if (file) setTimeout(() => downloadFile(view, file), index * 320);
      });
    });
    status.appendChild(downloadButton);
    const deleteButton = el('button', 'btn text danger', '删除所选');
    deleteButton.addEventListener('click', () => deleteSelection(view));
    status.appendChild(deleteButton);
    const clearButton = el('button', 'btn text', '取消选择');
    clearButton.addEventListener('click', () => { view.selection.clear(); renderView(view); });
    status.appendChild(clearButton);
  } else if (view.volumeId !== null) {
    status.appendChild(el('span', null, '拖动文件可移动到别的窗口；按住 ⌥ 拖动为复制'));
  }
}

/* ---------------- 选择与拖拽 ---------------- */
function selectionPayload(view) {
  const ids = [];
  const paths = [];
  [...view.selection].forEach((key) => {
    if (key.startsWith('dir:')) paths.push(key.slice(4)); else ids.push(key);
  });
  return { volumeId: view.volumeId, ids, paths, names: [] };
}

function fileDragPayload(view, file) {
  if (view.selection.has(file.id) && view.selection.size > 1) return selectionPayload(view);
  return { volumeId: view.volumeId, ids: [file.id], paths: [], names: [file.name] };
}

function folderDragPayload(view, folder) {
  const key = 'dir:' + folder.path;
  if (view.selection.has(key) && view.selection.size > 1) return selectionPayload(view);
  return { volumeId: view.volumeId, ids: [], paths: [folder.path], names: [folder.name] };
}

let dragPayload = null;

function makeDraggable(row, view, payloadFactory) {
  if (view.volumeId === null) return;
  const volume = volumeById(view.volumeId);
  if (volume && volume.readOnly) return;
  row.draggable = true;
  row.addEventListener('dragstart', (event) => {
    dragPayload = payloadFactory();
    dragPayload.names = dragPayload.names || [];
    event.dataTransfer.effectAllowed = 'copyMove';
    try {
      event.dataTransfer.setData('application/x-macnas', '1');
      event.dataTransfer.setData('text/plain', dragPayload.names.join('\n') || 'macnas');
    } catch (e) { /* 忽略 */ }
    row.classList.add('drag-source');
  });
  row.addEventListener('dragend', () => {
    dragPayload = null;
    row.classList.remove('drag-source');
    document.querySelectorAll('.drop-into').forEach((node) => node.classList.remove('drop-into'));
    document.querySelectorAll('.fm-body.drop-in').forEach((node) => node.classList.remove('drop-in'));
  });
}

function dragHasFiles(event) {
  const types = event.dataTransfer && event.dataTransfer.types;
  return !!types && Array.prototype.indexOf.call(types, 'Files') >= 0;
}

function isCopyDrag(event) {
  return !!(event.altKey || event.ctrlKey || event.metaKey);
}

function bindDropZone(node, view, targetDir, rowNode) {
  node.addEventListener('dragover', (event) => {
    if (!dragPayload && !dragHasFiles(event)) return;
    event.preventDefault();
    event.stopPropagation();
    if (dragPayload) event.dataTransfer.dropEffect = isCopyDrag(event) ? 'copy' : 'move';
    else event.dataTransfer.dropEffect = 'copy';
    if (rowNode) rowNode.classList.add('drop-into'); else node.classList.add('drop-in');
    const mode = view.statusEl.querySelector('.drop-mode') || (() => {
      const span = el('span', 'drop-mode');
      view.statusEl.appendChild(span);
      return span;
    })();
    mode.textContent = dragPayload
      ? (isCopyDrag(event) ? '松开复制到这里' : '松开移动到这里')
      : '松开上传到这里';
  });
  node.addEventListener('dragleave', () => {
    if (rowNode) rowNode.classList.remove('drop-into'); else node.classList.remove('drop-in');
    const mode = view.statusEl.querySelector('.drop-mode');
    if (mode) mode.remove();
  });
  node.addEventListener('drop', async (event) => {
    if (!dragPayload && !dragHasFiles(event)) return;
    event.preventDefault();
    event.stopPropagation();
    if (rowNode) rowNode.classList.remove('drop-into'); else node.classList.remove('drop-in');
    const mode = view.statusEl.querySelector('.drop-mode');
    if (mode) mode.remove();
    const dir = typeof targetDir === 'function' ? targetDir() : targetDir;
    if (dragPayload) await performTransfer(dragPayload, view, dir, isCopyDrag(event));
    else await handleOsDrop(event, view, dir);
  });
}

async function performTransfer(payload, view, dir, copy) {
  dragPayload = null;
  if (!view.volumeId || !payload.volumeId) return;
  if (payload.volumeId === view.volumeId && !payload.ids.length && !payload.paths.length) return;
  if (!copy && payload.volumeId === view.volumeId && payload.paths.length === 1 && payload.paths[0] === dir && !payload.ids.length) return;
  try {
    const result = await api('/api/transfer', {
      method: 'POST',
      body: {
        fromVolume: payload.volumeId,
        ids: payload.ids,
        paths: payload.paths,
        toVolume: view.volumeId,
        toPath: dir,
        mode: copy ? 'copy' : 'move'
      }
    });
    const count = (result.moved || 0) + (result.copied || 0);
    snackbar(`${copy ? '已复制' : '已移动'} ${count} 项` + (result.renamed ? `（${result.renamed} 项重名，已自动改名）` : ''), 'ok');
    await Promise.all([loadVolumes(), loadStatus(), refreshAllFileManagers()]);
  } catch (err) {
    snackbar(err.message, 'err');
  }
}


/* ---------------- 复制 / 剪切 / 粘贴 ---------------- */
const fileClipboard = { mode: null, volumeId: null, ids: [], paths: [], names: [] };

function clipboardCount() { return fileClipboard.ids.length + fileClipboard.paths.length; }
function clipboardHasItems() { return clipboardCount() > 0; }

function clearClipboard() {
  fileClipboard.mode = null;
  fileClipboard.volumeId = null;
  fileClipboard.ids = [];
  fileClipboard.paths = [];
  fileClipboard.names = [];
  state.sessions.forEach((view) => updateStatus(view));
}

/** 把当前选中项（或指定的单个目标）放进内部剪贴板 */
function copyToClipboard(view, mode, target) {
  if (!view.volumeId) return;
  const volume = volumeById(view.volumeId);
  if (volume && volume.readOnly) { snackbar('该目录为只读，无法复制内容出去', 'err'); return; }
  const payload = target ? targetPayload(view, target) : selectionPayload(view);
  if (!payload.ids.length && !payload.paths.length) { snackbar('请先选择要' + (mode === 'cut' ? '剪切' : '复制') + '的文件', 'err'); return; }
  fileClipboard.mode = mode;
  fileClipboard.volumeId = view.volumeId;
  fileClipboard.ids = payload.ids;
  fileClipboard.paths = payload.paths;
  fileClipboard.names = payload.names;
  state.sessions.forEach((item) => updateStatus(item));
  snackbar('已' + (mode === 'cut' ? '剪切' : '复制') + ' ' + clipboardCount() + ' 项，切换到目标文件夹后点「粘贴」或按 ⌘V', 'ok');
}

function targetPayload(view, target) {
  if (target.kind === 'file') {
    return { volumeId: view.volumeId, ids: [target.file.id], paths: [], names: [target.file.name] };
  }
  return { volumeId: view.volumeId, ids: [], paths: [target.folder.path], names: [target.folder.name] };
}

/** 粘贴到指定目录；剪切 → 移动，复制 → 复制（内容按哈希共享，不占额外空间） */
async function pasteInto(view, dir) {
  if (!clipboardHasItems()) return;
  if (!view.volumeId) { snackbar('请先打开一个目录再粘贴', 'err'); return; }
  const volume = volumeById(view.volumeId);
  if (volume && volume.readOnly) { snackbar('该目录为只读，无法粘贴', 'err'); return; }
  const mode = fileClipboard.mode === 'cut' ? 'move' : 'copy';
  const payload = {
    volumeId: fileClipboard.volumeId,
    ids: fileClipboard.ids.slice(),
    paths: fileClipboard.paths.slice(),
    names: fileClipboard.names.slice()
  };
  try {
    const result = await api('/api/transfer', {
      method: 'POST',
      body: {
        fromVolume: payload.volumeId,
        ids: payload.ids,
        paths: payload.paths,
        toVolume: view.volumeId,
        toPath: dir,
        mode
      }
    });
    const count = (result.moved || 0) + (result.copied || 0);
    snackbar((mode === 'move' ? '已移动到' : '已复制到') + dir + '（' + count + ' 项'
      + (result.renamed ? '，' + result.renamed + ' 项重名已自动改名' : '') + '）', 'ok');
    if (mode === 'move') clearClipboard();
    await Promise.all([loadVolumes(), loadStatus(), refreshAllFileManagers()]);
  } catch (err) {
    snackbar(err.message, 'err');
  }
}

/** 在原地创建一份副本（内容共享，不占空间） */
async function duplicateEntry(view, target) {
  const payload = targetPayload(view, target);
  try {
    const result = await api('/api/transfer', {
      method: 'POST',
      body: {
        fromVolume: view.volumeId,
        ids: payload.ids,
        paths: payload.paths,
        toVolume: view.volumeId,
        toPath: view.path,
        mode: 'copy'
      }
    });
    snackbar('已创建副本' + (result.renamed ? '（重名自动改名）' : ''), 'ok');
    await Promise.all([loadVolumes(), loadStatus(), refreshAllFileManagers()]);
  } catch (err) {
    snackbar(err.message, 'err');
  }
}

/** 「复制到…」：选目标目录再复制，手机上也能用 */
async function copyToDialog(view, target, mode) {
  const copy = mode !== 'move';
  const payload = target ? targetPayload(view, target) : selectionPayload(view);
  if (!payload.ids.length && !payload.paths.length) { snackbar('请先选择要' + (copy ? '复制' : '移动') + '的文件', 'err'); return; }

  const picker = { volumeId: view.volumeId, path: view.path || '/' };
  const box = el('div');
  const scopeRow = el('div');
  scopeRow.style.cssText = 'display:flex;gap:8px;align-items:center;margin-bottom:10px';
  const volumeSelect = document.createElement('select');
  volumeSelect.style.cssText = 'flex:1 1 auto;font:inherit;font-size:12.5px;padding:9px 10px;border-radius:10px;border:1px solid var(--outline);background:var(--glass-strong);color:var(--on-surface)';
  state.volumes.forEach((volume) => {
    const option = document.createElement('option');
    option.value = volume.id;
    option.textContent = volume.name + (volume.readOnly ? '（只读）' : '');
    option.disabled = !!volume.readOnly;
    if (volume.id === picker.volumeId) option.selected = true;
    volumeSelect.appendChild(option);
  });
  scopeRow.appendChild(volumeSelect);
  const upButton = el('button', 'btn text', '上一级');
  scopeRow.appendChild(upButton);
  box.appendChild(scopeRow);

  const crumb = el('div');
  crumb.style.cssText = 'font-family:ui-monospace,Menlo,monospace;font-size:11.5px;color:var(--on-surface-variant);margin-bottom:8px;word-break:break-all';
  box.appendChild(crumb);

  const list = el('div');
  list.style.cssText = 'max-height:280px;overflow-y:auto;border:1px solid var(--outline);border-radius:12px;padding:6px';
  box.appendChild(list);

  async function load() {
    crumb.textContent = (volumeById(picker.volumeId) || {}).name + picker.path;
    list.textContent = '';
    list.appendChild(el('div', 'fm-loading', '读取中…'));
    try {
      const data = await api('/api/list', { params: { volume: picker.volumeId, path: picker.path } });
      picker.path = data.path;
      crumb.textContent = (volumeById(picker.volumeId) || {}).name + picker.path;
      list.textContent = '';
      const folders = data.folders || [];
      if (!folders.length) {
        list.appendChild(el('div', 'share-note', '这个文件夹里没有子文件夹，可以直接' + (copy ? '复制' : '移动') + '到这里'));
      }
      folders.forEach((folder) => {
        const row = el('div', 'row');
        const icon = el('div', 'row-icon folder');
        icon.innerHTML = ICONS.folder;
        row.appendChild(icon);
        const main = el('div', 'row-main');
        main.appendChild(el('div', 'row-name', folder.name));
        main.appendChild(el('div', 'row-sub', folder.fileCount + ' 个文件'));
        row.appendChild(main);
        row.addEventListener('click', () => { picker.path = folder.path; load(); });
        list.appendChild(row);
      });
    } catch (err) {
      list.textContent = '';
      list.appendChild(el('div', 'fm-error', err.message));
    }
  }

  volumeSelect.addEventListener('change', () => { picker.volumeId = volumeSelect.value; picker.path = '/'; load(); });
  upButton.addEventListener('click', () => {
    if (picker.path === '/') return;
    picker.path = parentPath(picker.path);
    load();
  });
  await load();

  const value = await openDialog({
    title: (copy ? '复制 ' : '移动 ') + (payload.ids.length + payload.paths.length) + ' 项到…',
    message: '选择目标文件夹，然后点「' + (copy ? '复制' : '移动') + '到这里」',
    body: box,
    actions: [
      { label: (copy ? '复制' : '移动') + '到这里', value: 'copy' },
      { label: '取消', value: null, variant: 'text' }
    ]
  });
  if (value !== 'copy') return;

  try {
    const result = await api('/api/transfer', {
      method: 'POST',
      body: {
        fromVolume: payload.volumeId,
        ids: payload.ids,
        paths: payload.paths,
        toVolume: picker.volumeId,
        toPath: picker.path,
        mode: copy ? 'copy' : 'move'
      }
    });
    snackbar('已' + (copy ? '复制 ' : '移动 ') + ((result.copied || 0) + (result.moved || 0)) + ' 项到 ' + picker.path
      + (result.renamed ? '（' + result.renamed + ' 项重名已自动改名）' : ''), 'ok');
    await Promise.all([loadVolumes(), loadStatus(), refreshAllFileManagers()]);
  } catch (err) {
    snackbar(err.message, 'err');
  }
}

/* ---------------- 右键菜单 ---------------- */
let contextMenuNode = null;

function closeContextMenu() {
  if (contextMenuNode) { contextMenuNode.remove(); contextMenuNode = null; }
}

function showContextMenu(items, x, y) {
  closeContextMenu();
  const menu = el('div', 'context-menu glass');
  items.forEach((item) => {
    if (item.separator) { menu.appendChild(el('div', 'ctx-sep')); return; }
    const button = el('button', 'ctx-item' + (item.danger ? ' danger' : ''));
    if (item.icon) {
      const art = el('span', 'ctx-icon');
      art.innerHTML = item.icon;
      button.appendChild(art);
    }
    button.appendChild(el('span', null, item.label));
    if (item.disabled) button.disabled = true;
    else button.addEventListener('click', () => { closeContextMenu(); item.onClick(); });
    menu.appendChild(button);
  });
  document.body.appendChild(menu);
  const rect = menu.getBoundingClientRect();
  const left = Math.max(6, Math.min(x, window.innerWidth - rect.width - 8));
  const top = Math.max(6, Math.min(y, window.innerHeight - rect.height - 8));
  menu.style.left = left + 'px';
  menu.style.top = top + 'px';
  contextMenuNode = menu;
  setTimeout(() => {
    document.addEventListener('pointerdown', closeContextMenu, { once: true });
  }, 0);
}

function fileContextItems(view, file) {
  const items = [];
  if (looksPreviewable(file.name)) items.push({ label: '预览', icon: ICONS.eye, onClick: () => previewFile(view, file) });
  items.push({ label: '下载', icon: ICONS.download, onClick: () => downloadFile(view, file) });
  items.push({ separator: true });
  items.push({ label: '复制', icon: ICONS.copy, onClick: () => copyToClipboard(view, 'copy', { kind: 'file', file }) });
  items.push({ label: '剪切', icon: ICONS.move, onClick: () => copyToClipboard(view, 'cut', { kind: 'file', file }) });
  items.push({ label: '创建副本', icon: ICONS.copy, onClick: () => duplicateEntry(view, { kind: 'file', file }) });
  items.push({ label: '复制到…', icon: ICONS.folder, onClick: () => copyToDialog(view, { kind: 'file', file }) });
  items.push({ separator: true });
  items.push({ label: '分享', icon: ICONS.share, onClick: () => shareEntry(view, { kind: 'file', file }) });
  items.push({ label: '版本历史…', icon: ICONS.refresh, onClick: () => showVersions(view, file) });
  items.push({ label: '重命名', icon: ICONS.pencil, onClick: () => renameFile(view, file) });
  items.push({ label: '移到回收站', icon: ICONS.trash, danger: true, onClick: () => removeFile(view, file) });
  return items;
}

function folderContextItems(view, folder) {
  const items = [];
  items.push({ label: '打开', icon: ICONS.folder, onClick: () => navigateTo(view, view.volumeId, folder.path) });
  items.push({ separator: true });
  items.push({ label: '复制', icon: ICONS.copy, onClick: () => copyToClipboard(view, 'copy', { kind: 'folder', folder }) });
  items.push({ label: '剪切', icon: ICONS.move, onClick: () => copyToClipboard(view, 'cut', { kind: 'folder', folder }) });
  items.push({ label: '创建副本', icon: ICONS.copy, onClick: () => duplicateEntry(view, { kind: 'folder', folder }) });
  items.push({ label: '复制到…', icon: ICONS.folder, onClick: () => copyToDialog(view, { kind: 'folder', folder }) });
  items.push({ separator: true });
  items.push({ label: '分享', icon: ICONS.share, onClick: () => shareEntry(view, { kind: 'folder', folder }) });
  items.push({ label: '收集照片…', icon: ICONS.camera, onClick: () => createCollectDialog(view, folder.path) });
  items.push({ label: '重命名', icon: ICONS.pencil, onClick: () => renameFolder(view, folder) });
  items.push({ label: '移到回收站', icon: ICONS.trash, danger: true, onClick: () => removeFolder(view, folder) });
  return items;
}

function blankContextItems(view) {
  const items = [
    { label: '上传文件', icon: ICONS.upload, onClick: () => pickFiles(view) },
    { label: '新建文件夹', icon: ICONS.folderPlus, onClick: () => makeFolder(view) }
  ];
  if (clipboardHasItems()) {
    items.push({ separator: true });
    items.push({
      label: '粘贴 ' + clipboardCount() + ' 项',
      icon: ICONS.copy,
      onClick: () => pasteInto(view, view.path)
    });
  }
  items.push({ separator: true });
  items.push({ label: '刷新', icon: ICONS.refresh, onClick: () => refreshView(view) });
  return items;
}

/* ---------------- 文件操作 ---------------- */
function pickFiles(view) {
  if (!view.volumeId) { snackbar('请先打开一个目录', 'err'); return; }
  pendingUploadTarget = { view };
  $('file-input').click();
}

let pendingUploadTarget = null;

function downloadFile(view, file) {
  const url = '/api/download?' + new URLSearchParams({ volume: view.volumeId, id: file.id });
  const link = document.createElement('a');
  link.href = url;
  link.download = file.name;
  document.body.appendChild(link);
  link.click();
  link.remove();
}

function previewFile(view, file) {
  return openPreview({ volumeId: view.volumeId, id: file.id, path: file.logicalPath });
}

async function renameFile(view, file) {
  const name = await promptDialog({ title: '重命名', label: '新名称', value: file.name, confirmLabel: '保存' });
  if (!name || name === file.name) return;
  try {
    await api('/api/rename', { method: 'POST', body: { volume: view.volumeId, id: file.id, name } });
    snackbar('已重命名', 'ok');
    await refreshAfterChange(view);
  } catch (err) { snackbar(err.message, 'err'); }
}

async function renameFolder(view, folder) {
  const name = await promptDialog({ title: '重命名文件夹', label: '新名称', value: folder.name, confirmLabel: '保存' });
  if (!name || name === folder.name) return;
  try {
    await api('/api/rename-folder', { method: 'POST', body: { volume: view.volumeId, path: folder.path, name } });
    snackbar('已重命名文件夹', 'ok');
    await refreshAfterChange(view);
  } catch (err) { snackbar(err.message, 'err'); }
}

async function removeFile(view, file) {
  const ok = await confirmDialog({
    title: '移到回收站？',
    message: `「${file.name}」会移到回收站，可以随时还原。`,
    confirmLabel: '移到回收站'
  });
  if (!ok) return;
  try {
    await api('/api/delete', { method: 'POST', body: { volume: view.volumeId, id: file.id } });
    snackbar('已移到回收站', 'ok');
    refreshTrashBadge();
    await refreshAfterChange(view);
  } catch (err) { snackbar(err.message, 'err'); }
}

async function removeFolder(view, folder) {
  const ok = await confirmDialog({
    title: '删除文件夹？',
    message: `「${folder.name}」以及其中的 ${folder.fileCount} 个文件都会被删除记录。`,
    confirmLabel: '删除文件夹'
  });
  if (!ok) return;
  try {
    const result = await api('/api/delete', { method: 'POST', body: { volume: view.volumeId, path: folder.path } });
    snackbar(`文件夹已移到回收站（${result.deleted} 个文件）`, 'ok');
    refreshTrashBadge();
    await refreshAfterChange(view);
  } catch (err) { snackbar(err.message, 'err'); }
}

async function deleteSelection(view) {
  const keys = [...view.selection];
  const ids = keys.filter((key) => !key.startsWith('dir:'));
  const paths = keys.filter((key) => key.startsWith('dir:')).map((key) => key.slice(4));
  const ok = await confirmDialog({
    title: '删除所选项目？',
    message: `共 ${keys.length} 项。相同内容的其它记录不受影响；只有最后一条记录被删除时才会真正移除内容。`,
    confirmLabel: '删除'
  });
  if (!ok) return;
  try {
    if (ids.length) {
      const result = await api('/api/delete-batch', { method: 'POST', body: { volume: view.volumeId, ids } });
      if (result.failed) snackbar(`已移到回收站 ${result.deleted} 项，${result.failed} 项失败`, 'err');
      else snackbar(`已移到回收站 ${result.deleted} 项`, 'ok');
      refreshTrashBadge();
    }
    for (const path of paths) {
      await api('/api/delete', { method: 'POST', body: { volume: view.volumeId, path } });
    }
    view.selection.clear();
    await refreshAfterChange(view);
  } catch (err) { snackbar(err.message, 'err'); }
}

async function makeFolder(view) {
  if (!view.volumeId) { snackbar('请先打开一个目录', 'err'); return; }
  const name = await promptDialog({ title: '新建文件夹', label: '文件夹名称', value: '', confirmLabel: '创建' });
  if (!name) return;
  try {
    await api('/api/mkdir', { method: 'POST', body: { volume: view.volumeId, path: view.path, name } });
    snackbar('已创建文件夹', 'ok');
    await refreshAfterChange(view);
  } catch (err) { snackbar(err.message, 'err'); }
}

async function refreshAfterChange(view) {
  await Promise.all([loadVolumes(), loadStatus()]);
  await refreshAllFileManagers();
}

/* ---------------- 上传 ---------------- */
const upload = {
  items: [],
  running: false,
  conflictPolicy: 'ask',
  createdDirs: new Set()
};

/* ---------------- SHA-256（秒传用） ----------------
   局域网用 http:// 访问时属于「不安全来源」，crypto.subtle 不可用，
   所以这里带一份纯 JS 实现兜底；能用 Web Crypto 时优先用它（快很多）。 */
const SHA256 = (() => {
  const K = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
  ];

  function rotr(value, bits) { return (value >>> bits) | (value << (32 - bits)); }

  function fallback(bytes) {
    const H = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    const length = bytes.length;
    const withPadding = new Uint8Array((((length + 8) >> 6) + 1) << 6);
    withPadding.set(bytes);
    withPadding[length] = 0x80;
    const view = new DataView(withPadding.buffer);
    const bits = length * 8;
    view.setUint32(withPadding.length - 4, bits >>> 0, false);
    view.setUint32(withPadding.length - 8, Math.floor(bits / 4294967296), false);

    const w = new Uint32Array(64);
    for (let offset = 0; offset < withPadding.length; offset += 64) {
      for (let i = 0; i < 16; i++) w[i] = view.getUint32(offset + i * 4, false);
      for (let i = 16; i < 64; i++) {
        const s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
        const s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
      }
      let [a, b, c, d, e, f, g, h] = H;
      for (let i = 0; i < 64; i++) {
        const S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
        const ch = (e & f) ^ (~e & g);
        const temp1 = (h + S1 + ch + K[i] + w[i]) >>> 0;
        const S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
        const maj = (a & b) ^ (a & c) ^ (b & c);
        const temp2 = (S0 + maj) >>> 0;
        h = g; g = f; f = e; e = (d + temp1) >>> 0;
        d = c; c = b; b = a; a = (temp1 + temp2) >>> 0;
      }
      H[0] = (H[0] + a) >>> 0; H[1] = (H[1] + b) >>> 0; H[2] = (H[2] + c) >>> 0; H[3] = (H[3] + d) >>> 0;
      H[4] = (H[4] + e) >>> 0; H[5] = (H[5] + f) >>> 0; H[6] = (H[6] + g) >>> 0; H[7] = (H[7] + h) >>> 0;
    }
    return H.map((value) => value.toString(16).padStart(8, '0')).join('');
  }

  async function hex(buffer) {
    if (window.crypto && window.crypto.subtle && window.isSecureContext) {
      try {
        const digest = await window.crypto.subtle.digest('SHA-256', buffer);
        return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, '0')).join('');
      } catch (e) { /* 退回纯 JS */ }
    }
    return fallback(new Uint8Array(buffer));
  }

  return { hex, fallback };
})();

/* 秒传：只在不太大的文件上尝试（要先把内容读进内存算哈希） */
const INSTANT_UPLOAD_LIMIT = 64 * 1024 * 1024;

/** 试着秒传；返回 true 表示已经建好记录、不需要再传字节 */
async function tryInstantUpload(item, dir, overwrite) {
  if (!item.file || item.file.size > INSTANT_UPLOAD_LIMIT) return false;
  if (!window.crypto || !window.crypto.subtle) {
    // 没有 Web Crypto 时纯 JS 算大文件太慢，超过 8MB 就放弃秒传（走正常上传，服务端照样去重）
    if (item.file.size > 8 * 1024 * 1024) return false;
  }
  let hash = '';
  try {
    hash = await SHA256.hex(await item.file.arrayBuffer());
  } catch (e) {
    return false;
  }
  item.message = '正在核对…';
  renderUploadPanel();
  let probe = null;
  try {
    probe = await api('/api/has', { params: { sha256: hash } });
  } catch (e) {
    return false;   // 探测失败就当普通上传处理
  }
  if (!probe || !probe.exists) return false;
  try {
    await api('/api/register', {
      method: 'POST',
      body: { volume: item.volumeId, path: dir, name: item.file.name, sha256: hash, overwrite: !!overwrite }
    });
  } catch (err) {
    if (err.status === 409) throw err;   // 同名冲突交给上层询问用户
    return false;
  }
  item.status = 'done';
  item.loaded = item.file.size;
  item.instant = true;
  item.message = '秒传完成（内容已在库里，未传输字节）';
  renderUploadPanel();
  return true;
}

function enqueueUploads(entries, volumeId, destPath) {
  if (!volumeId) { snackbar('请先打开一个目录再上传', 'err'); return; }
  if (!entries.length) return;
  entries.forEach((entry) => {
    upload.items.push({
      id: uid(),
      file: entry.file,
      relPath: entry.relPath || '',
      volumeId,
      destPath,
      loaded: 0,
      status: 'pending',
      message: ''
    });
  });
  renderUploadPanel();
  pumpUploads();
}

async function pumpUploads() {
  if (upload.running) return;
  upload.running = true;
  for (;;) {
    const item = upload.items.find((entry) => entry.status === 'pending');
    if (!item) break;
    await runUpload(item);
  }
  upload.running = false;
  renderUploadPanel();
  await Promise.all([loadVolumes(), loadStatus(), refreshAllFileManagers()]);
}

async function runUpload(item) {
  item.status = 'uploading';
  renderUploadPanel();
  try {
    let dir = item.destPath;
    if (item.relPath) dir = await ensureDirectory(item.volumeId, dir, item.relPath);
    // 先问一句「库里有没有这份内容」：命中就零字节建记录
    if (await tryInstantUpload(item, dir, false)) return;
    await sendUpload(item, dir, false);
  } catch (err) {
    if (err.status === 409) {
      const answer = await resolveConflict(item, err);
      if (answer === 'overwrite') {
        try {
          let dir = item.destPath;
          if (item.relPath) dir = await ensureDirectory(item.volumeId, dir, item.relPath);
          if (await tryInstantUpload(item, dir, true)) return;
          await sendUpload(item, dir, true);
        } catch (retryError) {
          item.status = 'error';
          item.message = retryError.message;
        }
      } else if (answer === 'skip') {
        item.status = 'skipped';
        item.message = '已跳过（同名文件）';
      } else {
        item.status = 'error';
        item.message = '已取消';
      }
    } else {
      item.status = 'error';
      item.message = err.message;
    }
  }
  renderUploadPanel();
}

async function resolveConflict(item, err) {
  if (upload.conflictPolicy === 'overwrite') return 'overwrite';
  if (upload.conflictPolicy === 'skip') return 'skip';
  let applyAll = false;
  const value = await openDialog({
    title: '已存在同名文件',
    message: `${item.file.name}：${err.message}`,
    checkbox: '对后续同名文件都这样做',
    actions: [
      { label: '覆盖', value: 'overwrite' },
      { label: '跳过', value: 'skip', variant: 'text' }
    ],
    onMount: ({ wrap }) => {
      const box = wrap.querySelector('input[type="checkbox"]');
      if (box) box.addEventListener('change', () => { applyAll = box.checked; });
    }
  });
  if (!value) return 'cancel';
  if (applyAll) upload.conflictPolicy = value;
  return value;
}

async function ensureDirectory(volumeId, basePath, relativePath) {
  const parts = relativePath.split('/').filter(Boolean);
  let current = basePath;
  for (const part of parts) {
    const next = (current === '/' ? '' : current) + '/' + part;
    if (!upload.createdDirs.has(volumeId + '|' + next)) {
      try {
        await api('/api/mkdir', { method: 'POST', body: { volume: volumeId, path: current, name: part } });
      } catch (err) {
        if (err.status !== 409) throw err;
      }
      upload.createdDirs.add(volumeId + '|' + next);
    }
    current = next;
  }
  return current;
}

function sendUpload(item, dir, overwrite) {
  return new Promise((resolve, reject) => {
    const params = new URLSearchParams({
      volume: item.volumeId,
      path: dir,
      name: item.file.name,
      overwrite: overwrite ? '1' : '0'
    });
    const request = new XMLHttpRequest();
    request.open('POST', '/api/upload?' + params.toString(), true);
    request.setRequestHeader('Content-Type', item.file.type || 'application/octet-stream');
    request.upload.addEventListener('progress', (event) => {
      if (event.lengthComputable) {
        item.loaded = event.loaded;
        renderUploadPanel();
      }
    });
    request.addEventListener('load', () => {
      let data = null;
      try { data = JSON.parse(request.responseText); } catch (e) { data = null; }
      if (request.status === 401) { showLockScreen(); reject(new Error('登录状态已失效')); return; }
      if (request.status >= 200 && request.status < 300 && data && data.ok) {
        item.status = 'done';
        item.loaded = item.file.size;
        if (data.outcome === 'deduplicated') {
          item.message = '内容已存在，未占用新空间（节省 ' + fmtSize(item.file.size) + '）';
          item.deduplicated = true;
        } else {
          item.message = '上传完成';
        }
        resolve(data);
      } else {
        const error = new Error((data && data.error) || ('上传失败（' + request.status + '）'));
        error.status = request.status;
        reject(error);
      }
    });
    request.addEventListener('error', () => reject(new Error('网络错误')));
    request.addEventListener('abort', () => reject(new Error('已取消')));
    request.send(item.file);
  });
}

function renderUploadPanel() {
  const panel = $('upload-panel');
  if (!upload.items.length) {
    setVisible(panel, false);
    panel.textContent = '';
    return;
  }
  setVisible(panel, true);
  panel.textContent = '';

  const head = el('div', 'upload-head');
  const done = upload.items.filter((item) => item.status === 'done').length;
  const failed = upload.items.filter((item) => item.status === 'error').length;
  head.appendChild(el('span', null, '上传队列 ' + done + '/' + upload.items.length + (failed ? ' · 失败 ' + failed : '')));
  const clear = iconButton(ICONS.close, '清空已完成的记录', () => {
    upload.items = upload.items.filter((item) => item.status === 'pending' || item.status === 'uploading');
    renderUploadPanel();
  });
  head.appendChild(clear);
  panel.appendChild(head);

  const list = el('div', 'upload-list');
  upload.items.slice(-40).forEach((item) => {
    const row = el('div', 'upload-item');
    const line = el('div', 'u-name');
    line.appendChild(el('span', null, (item.relPath ? item.relPath + '/' : '') + item.file.name));
    line.appendChild(el('span', null, fmtSize(item.file.size)));
    row.appendChild(line);

    if (item.status === 'uploading' || item.status === 'pending') {
      const progress = el('div', 'progress');
      const bar = el('i');
      const ratio = item.file.size ? Math.min(100, (item.loaded / item.file.size) * 100) : 0;
      bar.style.width = ratio.toFixed(1) + '%';
      progress.appendChild(bar);
      row.appendChild(progress);
    }

    const status = el('div', 'u-status');
    if (item.status === 'done') { status.classList.add('ok'); status.textContent = item.message || '上传完成'; }
    else if (item.status === 'error') { status.classList.add('err'); status.textContent = item.message || '上传失败'; }
    else if (item.status === 'skipped') { status.classList.add('conflict'); status.textContent = item.message || '已跳过'; }
    else if (item.status === 'uploading') { status.textContent = '上传中…'; }
    else { status.textContent = '等待上传'; }
    row.appendChild(status);
    list.appendChild(row);
  });
  panel.appendChild(list);
}

/* ---------------- 从系统拖入文件（含文件夹） ---------------- */
async function collectDropped(dataTransfer) {
  const items = Array.from(dataTransfer.items || []);
  const entries = items
    .map((item) => (item.kind === 'file' && item.webkitGetAsEntry ? item.webkitGetAsEntry() : null))
    .filter(Boolean);

  if (!entries.length) {
    return Array.from(dataTransfer.files || []).map((file) => ({ file, relPath: '' }));
  }

  const results = [];
  async function walk(entry, prefix, depth) {
    if (depth > 12) return;
    if (entry.isFile) {
      await new Promise((resolve) => {
        entry.file((file) => { results.push({ file, relPath: prefix }); resolve(); }, () => resolve());
      });
      return;
    }
    if (entry.isDirectory) {
      const reader = entry.createReader();
      for (;;) {
        const batch = await new Promise((resolve) => reader.readEntries(resolve, () => resolve([])));
        if (!batch.length) break;
        for (const child of batch) {
          await walk(child, prefix ? prefix + '/' + entry.name : entry.name, depth + 1);
        }
      }
    }
  }

  for (const entry of entries) await walk(entry, '', 0);
  return results;
}

async function handleOsDrop(event, view, dir) {
  if (!view.volumeId) { snackbar('请先打开一个目录', 'err'); return; }
  const entries = await collectDropped(event.dataTransfer);
  if (!entries.length) return;
  enqueueUploads(entries, view.volumeId, dir);
}

/* ---------------- 对话框 ---------------- */
function openDialog(options) {
  return new Promise((resolve) => {
    const layer = $('dialog-layer');
    const wrap = el('div', 'dialog-layer');
    const scrim = el('div', 'scrim');
    const dialog = el('div', 'dialog glass');

    dialog.appendChild(el('h2', null, options.title || ''));
    if (options.message) dialog.appendChild(el('p', null, options.message));

    if (options.body) {
      const body = el('div', 'dialog-body');
      if (typeof options.body === 'string') body.innerHTML = options.body;
      else body.appendChild(options.body);
      dialog.appendChild(body);
    }

    let fieldInput = null;
    if (options.field) {
      const field = el('label', 'field');
      field.appendChild(el('span', null, options.field.label));
      fieldInput = document.createElement('input');
      fieldInput.value = options.field.value || '';
      fieldInput.placeholder = options.field.placeholder || '';
      field.appendChild(fieldInput);
      dialog.appendChild(field);
    }

    let checkbox = null;
    if (options.checkbox) {
      const row = el('label', 'check-row');
      checkbox = document.createElement('input');
      checkbox.type = 'checkbox';
      row.appendChild(checkbox);
      row.appendChild(el('span', null, options.checkbox));
      dialog.appendChild(row);
    }

    const actions = el('div', 'dialog-actions');
    const close = (value) => {
      document.removeEventListener('keydown', onKey);
      wrap.remove();
      resolve(value);
    };
    (options.actions || []).forEach((action) => {
      const button = el('button', 'btn ' + (action.variant === 'text' ? 'text' : 'filled'));
      button.textContent = action.label;
      if (action.danger) button.classList.add('danger');
      button.addEventListener('click', () => close(action.value));
      actions.appendChild(button);
    });
    dialog.appendChild(actions);

    wrap.appendChild(scrim);
    wrap.appendChild(dialog);
    layer.appendChild(wrap);
    scrim.addEventListener('click', () => close(null));
    const onKey = (event) => { if (event.key === 'Escape') close(null); };
    document.addEventListener('keydown', onKey);
    if (fieldInput) setTimeout(() => fieldInput.focus(), 40);
    if (options.onMount) options.onMount({ close, dialog, wrap, checkbox });
  });
}

async function confirmDialog(options) {
  const value = await openDialog({
    title: options.title,
    message: options.message,
    actions: [
      { label: options.confirmLabel || '确定', value: 'yes' },
      { label: '取消', value: null, variant: 'text' }
    ]
  });
  return value === 'yes';
}

function promptDialog(options) {
  return new Promise((resolve) => {
    const layer = $('dialog-layer');
    const wrap = el('div', 'dialog-layer');
    const scrim = el('div', 'scrim');
    const dialog = el('div', 'dialog glass');

    dialog.appendChild(el('h2', null, options.title));
    const field = el('label', 'field');
    field.appendChild(el('span', null, options.label));
    const input = document.createElement('input');
    input.value = options.value || '';
    input.placeholder = options.placeholder || '';
    input.spellcheck = false;
    field.appendChild(input);
    dialog.appendChild(field);

    const actions = el('div', 'dialog-actions');
    const done = (value) => {
      document.removeEventListener('keydown', onKey);
      wrap.remove();
      resolve(value);
    };
    const okButton = el('button', 'btn filled', options.confirmLabel || '保存');
    okButton.addEventListener('click', () => done(input.value.trim()));
    const cancelButton = el('button', 'btn text', '取消');
    cancelButton.addEventListener('click', () => done(null));
    actions.appendChild(okButton);
    actions.appendChild(cancelButton);
    dialog.appendChild(actions);

    wrap.appendChild(scrim);
    wrap.appendChild(dialog);
    layer.appendChild(wrap);
    scrim.addEventListener('click', () => done(null));
    const onKey = (event) => {
      if (event.key === 'Escape') done(null);
      if (event.key === 'Enter') { event.preventDefault(); done(input.value.trim()); }
    };
    document.addEventListener('keydown', onKey);
    setTimeout(() => { input.focus(); input.select(); }, 40);
  });
}

/* ---------------- 应用：系统信息 ---------------- */
function openAbout() {
  const existing = WM.items.find((win) => win.app.id === 'about');
  if (existing) { WM.focus(existing); return; }

  const win = WM.open(APPS.about, { title: '系统信息', width: 620, height: 560 });
  const body = win.body;
  body.textContent = '';

  const content = el('div');
  content.style.padding = '18px 20px';
  content.style.overflowY = 'auto';

  const render = async () => {
    content.textContent = '';
    let status = {};
    try { status = await api('/api/status'); } catch (e) { /* 忽略 */ }
    const rows = [
      ['版本', 'MacNas ' + (status.version || '-')],
      ['磁盘格式', 'v' + (status.formatVersion || 1) + '（结构已冻结，升级不改动）'],
      ['前端版本', frontendVersion() + '（刷新后应当变化；一直是老值说明浏览器缓存没更新）'],
      ['账号', status.username || state.username],
      ['网站端口', String(status.port || '-')],
      ['访问地址', location.origin],
      ['目录数量', String(status.volumeCount || 0)],
      ['文件记录', String(status.fileCount || 0)],
      ['独立文件', String(status.uniqueBlobCount || 0) + '（相同内容全局只存一份）'],
      ['已节省空间', fmtSize(status.savedBytes || 0)],
      ['实际占用', fmtSize(status.physicalBytes || 0) + ' / 逻辑大小 ' + fmtSize(status.logicalBytes || 0)]
    ];
    const table = el('table');
    rows.forEach(([key, value]) => {
      const tr = el('tr');
      tr.appendChild(el('td', null, key));
      const td = el('td');
      td.textContent = value;
      tr.appendChild(td);
      table.appendChild(tr);
    });
    content.appendChild(table);

    const note = el('div');
    note.style.cssText = 'margin-top:18px;font-size:12.5px;line-height:1.8;color:var(--on-surface-variant)';
    note.innerHTML =
      '<b style="color:var(--on-surface)">文件存在哪里？</b><br>' +
      '每个目录下只有两个子文件夹：<code>document/</code> 与 <code>info/</code>。' +
      '内容按 SHA-256 存放在 <code>document/blobs/&lt;前2位&gt;/&lt;哈希&gt;.&lt;扩展名&gt;</code>，' +
      '相同内容在所有目录里只保存一份；你在界面上看到的文件夹与文件名记录在 <code>info/index.json</code> 里。' +
      '所以用 Finder 直接看磁盘时文件名是哈希，这是去重存储的正常表现。<br><br>' +
      '<b style="color:var(--on-surface)">拖拽提示</b><br>' +
      '在不同窗口之间拖动文件即可移动（按住 ⌥ 为复制，因为内容是共享的，复制不会额外占用空间）；' +
      '把系统里的文件或文件夹拖进窗口即可上传。';
    content.appendChild(note);

    const volumesTitle = el('div');
    volumesTitle.style.cssText = 'margin:20px 0 8px;font-size:13px;font-weight:650';
    volumesTitle.textContent = '存储目录';
    content.appendChild(volumesTitle);

    state.volumes.forEach((volume) => {
      const box = el('div');
      box.style.cssText = 'padding:10px 12px;border-radius:12px;background:var(--hover);margin-bottom:8px;font-size:12px';
      const name = el('div', null, volume.name + (volume.readOnly ? '（只读）' : ''));
      name.style.fontWeight = '650';
      box.appendChild(name);
      const path = el('div', null, volume.path);
      path.style.cssText = 'font-family:ui-monospace,Menlo,monospace;font-size:11px;color:var(--on-surface-variant);word-break:break-all';
      box.appendChild(path);
      box.appendChild(el('div', null, `${volume.fileCount} 条记录 · ${fmtSize(volume.physicalBytes)}`));
      content.appendChild(box);
    });
  };

  body.appendChild(content);
  const refreshButton = iconButton(ICONS.refresh, '刷新', render);
  win.bar.insertBefore(refreshButton, win.bar.querySelector('.win-buttons'));
  render();
}


/* ---------------- 分享链接 ---------------- */
const SHARE_EXPIRY_OPTIONS = [
  { label: '1 天', hours: 24 },
  { label: '7 天', hours: 24 * 7 },
  { label: '30 天', hours: 24 * 30 },
  { label: '永久有效', hours: 0 }
];

async function shareEntry(view, target) {
  if (!view.volumeId) return;
  const isFile = target.kind === 'file';
  const name = isFile ? target.file.name : target.folder.name;
  const kindText = isFile ? '文件' : '文件夹';

  const form = el('div');
  const expiryField = el('label', 'field');
  expiryField.appendChild(el('span', null, '有效期'));
  const select = document.createElement('select');
  select.style.cssText = 'width:100%;font:inherit;padding:10px 12px;border-radius:10px;border:1px solid var(--outline);background:var(--glass-strong);color:var(--on-surface)';
  SHARE_EXPIRY_OPTIONS.forEach((option, index) => {
    const node = document.createElement('option');
    node.value = String(option.hours);
    node.textContent = option.label;
    if (index === 1) node.selected = true;
    select.appendChild(node);
  });
  expiryField.appendChild(select);
  form.appendChild(expiryField);

  const passwordField = el('label', 'field');
  passwordField.appendChild(el('span', null, '访问密码（可留空）'));
  const passwordInput = document.createElement('input');
  passwordInput.type = 'text';
  passwordInput.placeholder = '留空表示凭链接即可访问';
  passwordField.appendChild(passwordInput);
  form.appendChild(passwordField);

  const value = await openDialog({
    title: '分享' + kindText + '「' + name + '」',
    message: isFile ? '生成一个链接，任何人打开即可下载这个文件。' : '生成一个链接，任何人打开即可浏览并下载这个文件夹里的内容。',
    body: form,
    actions: [
      { label: '创建链接', value: 'create' },
      { label: '取消', value: null, variant: 'text' }
    ]
  });
  if (value !== 'create') return;

  try {
    const body = { volume: view.volumeId, expiresInHours: Number(select.value), password: passwordInput.value };
    if (isFile) body.id = target.file.id; else body.path = target.folder.path;
    const result = await api('/api/share/create', { method: 'POST', body });
    await showShareLink(result.share);
  } catch (err) {
    snackbar(err.message, 'err');
  }
}

async function showShareLink(share) {
  const box = el('div');
  const row = el('div');
  row.style.cssText = 'display:flex;gap:8px;align-items:center';
  const input = document.createElement('input');
  input.value = share.url;
  input.readOnly = true;
  input.style.cssText = 'flex:1 1 auto;font:inherit;font-size:12px;padding:10px 12px;border-radius:10px;border:1px solid var(--outline);background:var(--glass-strong);color:var(--on-surface)';
  const copyButton = el('button', 'btn filled');
  copyButton.textContent = '复制';
  copyButton.addEventListener('click', () => copyText(share.url));
  row.appendChild(input);
  row.appendChild(copyButton);
  box.appendChild(row);

  const info = el('p');
  info.style.cssText = 'margin:12px 0 0;font-size:12px;color:var(--on-surface-variant)';
  info.textContent = (share.permanent ? '永久有效' : '有效期至 ' + fmtDate(share.expiresAt))
    + (share.hasPassword ? ' · 需要密码' : ' · 凭链接访问');
  box.appendChild(info);

  const value = await openDialog({
    title: '分享链接已创建',
    body: box,
    actions: [
      { label: '打开链接', value: 'open' },
      { label: '完成', value: null, variant: 'text' }
    ]
  });
  if (value === 'open') window.open(share.url, '_blank');
}

function copyText(text) {
  const done = () => snackbar('链接已复制到剪贴板', 'ok');
  if (navigator.clipboard && window.isSecureContext) {
    navigator.clipboard.writeText(text).then(done, () => fallbackCopy(text, done));
  } else {
    fallbackCopy(text, done);
  }
}

function fallbackCopy(text, done) {
  const area = document.createElement('textarea');
  area.value = text;
  area.style.cssText = 'position:fixed;opacity:0';
  document.body.appendChild(area);
  area.select();
  try { document.execCommand('copy'); done(); } catch (e) { snackbar('复制失败，请手动选择链接', 'err'); }
  area.remove();
}


/* ---------------- 应用：全局搜索 ---------------- */
function openSearch(initialQuery) {
  const existing = WM.items.find((win) => win.app.id === 'search');
  if (existing) {
    WM.focus(existing);
    if (existing.searchView) {
      if (initialQuery !== undefined && initialQuery !== null) existing.searchView.setQuery(initialQuery);
      existing.searchView.focus();
    }
    return existing;
  }

  const win = WM.open(APPS.search, { title: '全局搜索', width: 900, height: 620 });
  const body = win.body;
  body.textContent = '';

  const wrap = el('div', 'fm');
  const toolbar = el('div', 'fm-toolbar');

  const searchIcon = el('span');
  searchIcon.style.cssText = 'flex:0 0 auto;color:var(--primary)';
  searchIcon.innerHTML = ICONS.search;
  toolbar.appendChild(searchIcon);

  const input = document.createElement('input');
  input.type = 'search';
  input.placeholder = '搜索所有目录里的文件和文件夹…';
  input.style.cssText = 'flex:1 1 auto;min-width:0;font:inherit;font-size:13.5px;padding:8px 12px;border-radius:100px;border:1px solid var(--outline);background:var(--glass-strong);color:var(--on-surface);outline:none';
  toolbar.appendChild(input);

  const scope = document.createElement('select');
  scope.style.cssText = 'flex:0 0 auto;font:inherit;font-size:12.5px;padding:8px 10px;border-radius:100px;border:1px solid var(--outline);background:var(--glass-strong);color:var(--on-surface)';
  const allOption = document.createElement('option');
  allOption.value = '';
  allOption.textContent = '所有目录';
  scope.appendChild(allOption);
  state.volumes.forEach((volume) => {
    const option = document.createElement('option');
    option.value = volume.id;
    option.textContent = volume.name;
    scope.appendChild(option);
  });
  toolbar.appendChild(scope);

  const actions = el('div', 'fm-actions');
  const clearButton = iconButton(ICONS.close, '清空', () => { input.value = ''; run(''); input.focus(); });
  actions.appendChild(clearButton);
  toolbar.appendChild(actions);

  const listEl = el('div', 'fm-body');
  const statusEl = el('div', 'fm-status');
  wrap.appendChild(toolbar);
  wrap.appendChild(listEl);
  wrap.appendChild(statusEl);
  body.appendChild(wrap);

  let requestId = 0;
  let timer = null;

  function setStatus(text) {
    statusEl.textContent = '';
    statusEl.appendChild(el('span', null, text));
    const spacer = el('span', 'spacer');
    statusEl.appendChild(spacer);
    statusEl.appendChild(el('span', null, '⌘K / Ctrl+K 随时打开搜索'));
  }

  function empty(message, hint) {
    listEl.textContent = '';
    const box = el('div', 'fm-empty');
    box.innerHTML = ICONS.search;
    box.appendChild(el('h3', null, message));
    box.appendChild(el('p', null, hint || ''));
    listEl.appendChild(box);
  }

  async function run(query) {
    const text = query.trim();
    if (!text) {
      empty('输入关键词开始搜索', '支持空格分隔多个关键词，会同时匹配文件名与所在路径');
      setStatus('尚未搜索');
      return;
    }
    const current = ++requestId;
    listEl.textContent = '';
    listEl.appendChild(el('div', 'fm-loading', '正在搜索…'));
    let data = null;
    try {
      const params = { q: text, limit: 300 };
      if (scope.value) params.volume = scope.value;
      data = await api('/api/search', { params });
    } catch (err) {
      if (current !== requestId) return;
      listEl.textContent = '';
      const box = el('div', 'fm-error');
      box.appendChild(el('h3', null, '搜索失败'));
      box.appendChild(el('p', null, err.message));
      listEl.appendChild(box);
      setStatus('搜索失败');
      return;
    }
    if (current !== requestId) return;
    render(data, text);
  }

  function render(data, text) {
    listEl.textContent = '';
    const hits = data.hits || [];
    if (!hits.length) {
      empty('没有找到「' + text + '」', '换个关键词试试，或者确认文件所在目录已经添加到 MacNas');
      setStatus('0 个结果');
      return;
    }
    hits.forEach((hit) => listEl.appendChild(searchRow(hit, text)));
    setStatus('找到 ' + data.total + ' 个结果' + (data.truncated ? '（只显示前 ' + data.hits.length + ' 个）' : ''));
  }

  function searchRow(hit, text) {
    const row = el('div', 'row');
    const icon = el('div', 'row-icon' + (hit.kind === 'folder' ? ' folder' : ''));
    icon.innerHTML = hit.kind === 'folder' ? ICONS.folder : iconFor(hit);
    row.appendChild(icon);

    const main = el('div', 'row-main');
    main.appendChild(el('div', 'row-name')).appendChild(highlight(hit.name, text));
    const sub = el('div', 'row-sub');
    sub.appendChild(el('span', null, hit.volumeName));
    sub.appendChild(el('span', null, hit.kind === 'folder' ? (hit.fileCount + ' 个文件') : fmtSize(hit.size)));
    if (hit.createdAt) sub.appendChild(el('span', null, fmtDate(hit.createdAt)));
    main.appendChild(sub);
    const location = el('div');
    location.style.cssText = 'font-family:ui-monospace,Menlo,monospace;font-size:11px;color:var(--on-surface-variant);margin-top:3px;word-break:break-all';
    location.textContent = hit.path;
    main.appendChild(location);
    main.addEventListener('click', () => revealHit(hit));
    row.appendChild(main);

    const rowActions = el('div', 'row-actions');
    rowActions.appendChild(iconButton(ICONS.locate, '打开所在位置', () => revealHit(hit)));
    if (hit.kind === 'file') {
      rowActions.appendChild(iconButton(ICONS.download, '下载', () => {
        const link = document.createElement('a');
        link.href = '/api/download?' + new URLSearchParams({ volume: hit.volumeId, id: hit.id });
        link.download = hit.name;
        document.body.appendChild(link);
        link.click();
        link.remove();
      }));
    }
    rowActions.appendChild(iconButton(ICONS.share, '分享', () => {
      if (hit.kind === 'file') shareEntry({ volumeId: hit.volumeId }, { kind: 'file', file: { id: hit.id, name: hit.name } });
      else shareEntry({ volumeId: hit.volumeId }, { kind: 'folder', folder: { path: hit.path, name: hit.name } });
    }));
    rowActions.appendChild(iconButton(ICONS.copy, '复制路径', () => copyText(hit.volumeName + hit.path)));
    row.appendChild(rowActions);
    return row;
  }

  /** 在名字里高亮命中的关键词（只拆文字节点，不拼 HTML，避免注入） */
  function highlight(name, text) {
    const fragment = document.createDocumentFragment();
    const tokens = text.trim().split(/\s+/).filter(Boolean);
    if (!tokens.length) { fragment.appendChild(document.createTextNode(name)); return fragment; }
    const lowered = name.toLowerCase();
    const marked = new Array(name.length).fill(false);
    tokens.forEach((token) => {
      const needle = token.toLowerCase();
      let from = lowered.indexOf(needle);
      while (from >= 0) {
        for (let i = from; i < from + needle.length && i < marked.length; i++) marked[i] = true;
        from = lowered.indexOf(needle, from + needle.length);
      }
    });
    let cursor = 0;
    while (cursor < name.length) {
      const on = marked[cursor];
      let end = cursor;
      while (end < name.length && marked[end] === on) end++;
      const piece = name.slice(cursor, end);
      if (on) {
        const mark = document.createElement('mark');
        mark.textContent = piece;
        fragment.appendChild(mark);
      } else {
        fragment.appendChild(document.createTextNode(piece));
      }
      cursor = end;
    }
    return fragment;
  }

  function revealHit(hit) {
    const view = openFileManager({ volumeId: hit.volumeId, path: hit.parent, skipAutoFocus: true });
    view.revealName = hit.name;
    // 文件管理器异步读取完成后再定位
    const tick = () => {
      if (view.loading) { setTimeout(tick, 120); return; }
      applyReveal(view);
    };
    tick();
  }

  const view = {
    focus: () => { input.focus(); input.select(); },
    setQuery: (text) => { input.value = text; run(text); }
  };
  win.searchView = view;
  win.sessionState = () => ({ query: input.value });

  let debounce = null;
  input.addEventListener('input', () => {
    clearTimeout(debounce);
    const text = input.value;
    debounce = setTimeout(() => run(text), 220);
  });
  input.addEventListener('keydown', (event) => {
    if (event.key === 'Enter') { clearTimeout(debounce); run(input.value); }
    if (event.key === 'Escape') { input.value = ''; run(''); }
  });
  scope.addEventListener('change', () => run(input.value));

  empty('输入关键词开始搜索', '支持空格分隔多个关键词，会同时匹配文件名与所在路径');
  setStatus('尚未搜索');
  if (initialQuery) { input.value = initialQuery; run(initialQuery); }
  setTimeout(() => input.focus(), 80);
  return win;
}

/* 在文件管理窗口里高亮并滚动到某个文件（搜索结果定位用） */
function applyReveal(view) {
  if (!view.revealName) return;
  const target = [...view.listEl.querySelectorAll('.row')].find((row) => {
    const name = row.querySelector('.row-name');
    return name && name.textContent === view.revealName;
  });
  if (target) {
    target.classList.add('flash');
    target.scrollIntoView({ block: 'center' });
    setTimeout(() => target.classList.remove('flash'), 2200);
  }
  view.revealName = null;
}

/* ---------------- 应用：分享管理 ---------------- */
function openShareManager() {
  const existing = WM.items.find((win) => win.app.id === 'shares');
  if (existing) { WM.focus(existing); return; }

  const win = WM.open(APPS.shares, { title: '分享管理', width: 920, height: 580 });
  const body = win.body;
  body.textContent = '';
  const wrap = el('div', 'fm');
  const toolbar = el('div', 'fm-toolbar');
  toolbar.appendChild(el('div', 'crumbs')).appendChild(el('span', null, '我创建的分享链接'));
  const actions = el('div', 'fm-actions');
  const collectButton = el('button', 'btn text', '新建照片收集');
  collectButton.addEventListener('click', async () => {
    // 分享管理里没有「当前目录」，所以先让用户挑一个目标文件夹
    const target = await pickFolderTarget();
    if (!target) return;
    await createCollectDialog({ volumeId: target.volumeId, path: target.path }, target.path);
    render();
  });
  actions.appendChild(collectButton);
  const refreshButton = iconButton(ICONS.refresh, '刷新', () => render());
  actions.appendChild(refreshButton);
  toolbar.appendChild(actions);

  const listEl = el('div', 'fm-body');
  const statusEl = el('div', 'fm-status');
  wrap.appendChild(toolbar);
  wrap.appendChild(listEl);
  wrap.appendChild(statusEl);
  body.appendChild(wrap);

  const targetUrl = (share) => location.origin + share.path;

  async function render() {
    listEl.textContent = '';
    listEl.appendChild(el('div', 'fm-loading', '正在读取…'));
    let data = null;
    try {
      data = await api('/api/shares');
    } catch (err) {
      listEl.textContent = '';
      const box = el('div', 'fm-error');
      box.appendChild(el('h3', null, '读取失败'));
      box.appendChild(el('p', null, err.message));
      listEl.appendChild(box);
      return;
    }
    const shares = data.shares || [];
    listEl.textContent = '';

    if (!shares.length) {
      const empty = el('div', 'fm-empty');
      empty.innerHTML = ICONS.share;
      empty.appendChild(el('h3', null, '还没有分享链接'));
      empty.appendChild(el('p', null, '在文件管理窗口里点某一行的「分享」按钮即可创建'));
      listEl.appendChild(empty);
      updateStatus();
      return;
    }

    shares.forEach((share) => {
      const row = el('div', 'row');
      const icon = el('div', 'row-icon' + (share.kind === 'folder' ? ' folder' : ''));
      icon.innerHTML = share.collect ? ICONS.camera : (share.kind === 'folder' ? ICONS.folder : ICONS.file);
      row.appendChild(icon);

      const main = el('div', 'row-main');
      main.appendChild(el('div', 'row-name', share.name));
      const sub = el('div', 'row-sub');
      sub.appendChild(el('span', null, share.type));
      sub.appendChild(el('span', null, share.permanent ? '永久有效' : '至 ' + fmtDate(share.expiresAt)));
      if (share.hasPassword) sub.appendChild(el('span', null, '有密码'));
      sub.appendChild(el('span', null, '访问 ' + share.visits + ' · 下载 ' + share.downloads));
      if (share.collect) {
        sub.appendChild(el('span', null, '已收 ' + (share.uploadedCount || 0) + ' 张 / ' +
          fmtSize(share.uploadedBytes || 0) + (share.maxTotalBytes > 0 ? '（上限 ' + fmtSize(share.maxTotalBytes) + '）' : '')));
        if (share.maxFileBytes > 0) sub.appendChild(el('span', null, '单个 ≤ ' + fmtSize(share.maxFileBytes)));
      }
      main.appendChild(sub);

      const link = el('div');
      link.style.cssText = 'font-family:ui-monospace,Menlo,monospace;font-size:11px;color:var(--on-surface-variant);word-break:break-all;margin-top:4px';
      link.textContent = targetUrl(share);
      main.appendChild(link);

      if (share.status !== 'valid') {
        const pill = el('span', 'tag warn', share.note || '已失效');
        main.querySelector('.row-sub').appendChild(pill);
      }
      row.appendChild(main);

      const rowActions = el('div', 'row-actions');
      rowActions.appendChild(iconButton(ICONS.copy, '复制链接', () => copyText(targetUrl(share))));
      rowActions.appendChild(iconButton(ICONS.eye, '打开链接', () => window.open(targetUrl(share), '_blank')));
      rowActions.appendChild(iconButton(ICONS.trash, '取消分享', async () => {
        const ok = await confirmDialog({
          title: '取消分享？',
          message: '「' + share.name + '」的链接将立即失效，文件本身不会被删除。',
          confirmLabel: '取消分享'
        });
        if (!ok) return;
        try {
          await api('/api/share/revoke', { method: 'POST', body: { token: share.token } });
          snackbar('已取消分享', 'ok');
          await render();
        } catch (err) { snackbar(err.message, 'err'); }
      }, 'danger'));
      row.appendChild(rowActions);

      listEl.appendChild(row);
    });
    updateStatus();
  }

  function updateStatus() {
    statusEl.textContent = '';
    statusEl.appendChild(el('span', null, '链接只有拿到地址的人才能打开；可以随时取消'));
    const spacer = el('span', 'spacer');
    statusEl.appendChild(spacer);
    const help = el('button', 'btn text', '怎么用？');
    help.addEventListener('click', () => openDialog({
      title: '分享链接怎么用',
      message: '把链接（或二维码内容）发给别人，对方用浏览器打开即可浏览、下载，不需要登录 MacNas。'
        + '若设置了密码，对方需要先输入密码。删除文件或取消分享后，链接会立即失效。',
      actions: [{ label: '知道了', value: null, variant: 'text' }]
    }));
    statusEl.appendChild(help);
  }

  render();
}

/* ---------------- 分享页（匿名访问 /s/<token>） ---------------- */
function shareTokenFromPath() {
  const match = location.pathname.match(/^\/s\/([A-Za-z0-9_-]+)/);
  return match ? match[1] : null;
}

function shareDownloadURL(token, file) {
  return '/api/pub/' + token + '/download?id=' + encodeURIComponent(file.id);
}

async function renderSharePage(token) {
  $('lockscreen').classList.add('hidden');
  $('desktop').classList.add('hidden');
  const page = $('share-view');
  page.classList.remove('hidden');
  page.textContent = '';
  const wrap = el('div', 'share-wrap');
  page.appendChild(wrap);

  const state = { path: null };

  async function load() {
    wrap.textContent = '';
    wrap.appendChild(el('div', 'share-note', '正在读取…'));
    let data = null;
    try {
      const params = state.path ? { path: state.path } : null;
      data = await apiPublic('/api/pub/' + token, { params });
    } catch (err) {
      wrap.textContent = '';
      const note = el('div', 'share-note');
      note.innerHTML = ICONS.link;
      note.appendChild(el('h3', null, '链接无法访问'));
      note.appendChild(el('p', null, err.message));
      wrap.appendChild(note);
      return;
    }
    wrap.textContent = '';

    if (data.needsPassword) {
      renderPassword(data);
      return;
    }

    if (data.collect) {
      renderCollectShell(data, token, wrap);
      return;
    }

    const head = el('header', 'share-head glass');
    const logo = el('img', 'share-logo');
    logo.src = '/logo.png';
    logo.alt = '';
    head.appendChild(logo);
    const title = el('div', 'share-title');
    title.appendChild(el('h1', null, data.name));
    const meta = el('p');
    meta.textContent = data.type + ' · 由 MacNas 分享' + (data.volumeName ? '（' + data.volumeName + '）' : '');
    title.appendChild(meta);
    head.appendChild(title);
    const themeButton = iconButton(document.documentElement.dataset.theme === 'dark' ? ICONS.sun : ICONS.moon, '切换深浅色', () => { toggleTheme(); load(); });
    themeButton.id = 'share-theme-btn';
    head.appendChild(themeButton);
    wrap.appendChild(head);

    const bodyEl = el('div', 'share-body glass');
    wrap.appendChild(bodyEl);

    if (data.kind === 'file') {
      const file = (data.files || [])[0];
      if (!file) {
        bodyEl.appendChild(el('div', 'share-note', '这个文件已经不存在了'));
      } else {
        const card = el('div', 'share-file');
        const art = el('div', 'sf-icon');
        art.innerHTML = iconFor(file);
        card.appendChild(art);
        card.appendChild(el('div', 'sf-name', file.name));
        card.appendChild(el('div', 'sf-meta', fmtSize(file.size)));
        const button = el('button', 'btn filled');
        button.innerHTML = ICONS.download + '<span>下载文件</span>';
        button.addEventListener('click', () => {
          const link = document.createElement('a');
          link.href = shareDownloadURL(token, file);
          link.download = file.name;
          document.body.appendChild(link);
          link.click();
          link.remove();
        });
        card.appendChild(button);
        bodyEl.appendChild(card);
      }
    } else {
      const crumbs = el('nav', 'crumbs');
      (data.crumbs || []).forEach((crumb, index, all) => {
        if (index > 0) crumbs.appendChild(el('span', 'crumb-sep', '/'));
        const button = el('button', 'crumb' + (index === all.length - 1 ? ' current' : ''), crumb.name);
        button.addEventListener('click', () => { state.path = crumb.path; load(); });
        crumbs.appendChild(button);
      });
      if ((data.crumbs || []).length > 1) {
        const toolbar = el('div', 'fm-toolbar');
        toolbar.appendChild(crumbs);
        bodyEl.appendChild(toolbar);
      }

      const total = (data.folders || []).length + (data.files || []).length;
      if (!total) {
        const note = el('div', 'share-note');
        note.innerHTML = ICONS.empty;
        note.appendChild(el('h3', null, '这个文件夹是空的'));
        bodyEl.appendChild(note);
      }

      (data.folders || []).forEach((folder) => {
        const row = el('div', 'row');
        const icon = el('div', 'row-icon folder');
        icon.innerHTML = ICONS.folder;
        row.appendChild(icon);
        const main = el('div', 'row-main');
        main.appendChild(el('div', 'row-name', folder.name));
        main.appendChild(el('div', 'row-sub', folder.fileCount + ' 个文件'));
        main.addEventListener('click', () => { state.path = folder.path; load(); });
        row.appendChild(main);
        const actions = el('div', 'row-actions');
        actions.appendChild(iconButton(ICONS.chevron || ICONS.eye, '打开', () => { state.path = folder.path; load(); }));
        row.appendChild(actions);
        bodyEl.appendChild(row);
      });

      (data.files || []).forEach((file) => {
        const row = el('div', 'row');
        const icon = el('div', 'row-icon');
        icon.innerHTML = iconFor(file);
        row.appendChild(icon);
        const main = el('div', 'row-main');
        main.appendChild(el('div', 'row-name', file.name));
        const sub = el('div', 'row-sub');
        sub.appendChild(el('span', null, fmtSize(file.size)));
        sub.appendChild(el('span', null, fmtDate(file.createdAt)));
        main.appendChild(sub);
        row.appendChild(main);
        const actions = el('div', 'row-actions');
        // 能预览的给一个预览按钮，点文件名也能直接预览
        if (looksPreviewable(file.name)) {
          const preview = el('button', 'btn text');
          preview.innerHTML = ICONS.eye + '<span>预览</span>';
          preview.addEventListener('click', (event) => { event.stopPropagation(); openSharePreview(token, file); });
          actions.appendChild(preview);
          main.classList.add('clickable');
          main.addEventListener('click', () => openSharePreview(token, file));
        }
        const download = el('button', 'btn text');
        download.innerHTML = ICONS.download + '<span>下载</span>';
        download.addEventListener('click', () => {
          const link = document.createElement('a');
          link.href = shareDownloadURL(token, file);
          link.download = file.name;
          document.body.appendChild(link);
          link.click();
          link.remove();
        });
        actions.appendChild(download);
        row.appendChild(actions);
        bodyEl.appendChild(row);
      });
    }

    const foot = el('footer', 'share-foot');
    foot.appendChild(el('div', null, data.permanent ? '此分享永久有效' : '此分享有效期至 ' + fmtDate(data.expiresAt)));
    foot.appendChild(el('div', null, '由 MacNas 提供 · 内容按哈希去重存储'));
    wrap.appendChild(foot);
  }

  function renderPassword(data) {
    const card = el('div', 'share-body glass share-password');
    card.appendChild(el('h1', null, data.name));
    const hint = el('p');
    hint.style.cssText = 'margin:4px 0 16px;font-size:12.5px;color:var(--on-surface-variant)';
    hint.textContent = '这是一个带密码的分享，请输入访问密码';
    card.appendChild(hint);

    const form = el('form');
    const field = el('label', 'field');
    field.appendChild(el('span', null, '访问密码'));
    const input = document.createElement('input');
    input.type = 'password';
    input.autocomplete = 'off';
    field.appendChild(input);
    form.appendChild(field);
    const button = el('button', 'btn filled block', '打开分享');
    button.type = 'submit';
    form.appendChild(button);
    const error = el('p', 'form-error');
    setVisible(error, false);
    form.appendChild(error);

    form.addEventListener('submit', async (event) => {
      event.preventDefault();
      button.disabled = true;
      setVisible(error, false);
      try {
        await apiPublic('/api/pub/' + token + '/auth', { method: 'POST', body: { password: input.value } });
        await load();
      } catch (err) {
        error.textContent = err.message;
        setVisible(error, true);
      } finally {
        button.disabled = false;
      }
    });

    card.appendChild(form);
    wrap.appendChild(card);
    setTimeout(() => input.focus(), 80);
  }

  await load();
}

/* ---------------- 应用定义与桌面 ---------------- */
const APPS = {
  files: { id: 'files', name: '文件管理', icon: ICONS.appFiles },
  preview: { id: 'preview', name: '预览', icon: ICONS.eye },
  search: { id: 'search', name: '全局搜索', icon: ICONS.search },
  shares: { id: 'shares', name: '分享管理', icon: ICONS.share },
  trash: { id: 'trash', name: '回收站', icon: ICONS.trash },
  photos: { id: 'photos', name: '照片', icon: ICONS.photos },
  analytics: { id: 'analytics', name: '存储分析', icon: ICONS.storage },
  about: { id: 'about', name: '系统信息', icon: '<img class="app-logo" src="/logo.png" alt="">' }
};

/* ---------------- 照片收集 ---------------- */

/** 挑一个目标文件夹（分享管理里创建收集链接时用） */
async function pickFolderTarget() {
  const picker = { volumeId: (state.volumes[0] || {}).id, path: '/' };
  const box = el('div');
  const crumb = el('div', 'picker-crumb');
  const list = el('div', 'picker-list');
  box.appendChild(crumb);
  box.appendChild(list);

  async function load() {
    crumb.textContent = ((volumeById(picker.volumeId) || {}).name || '') + picker.path;
    list.textContent = '';
    list.appendChild(el('div', 'fm-loading', '读取中…'));
    try {
      const data = await api('/api/list', { params: { volume: picker.volumeId, path: picker.path } });
      picker.path = data.path;
      crumb.textContent = ((volumeById(picker.volumeId) || {}).name || '') + picker.path;
      list.textContent = '';
      const folders = data.folders || [];
      list.appendChild(el('div', 'picker-hint', folders.length ? '选一个文件夹，或直接点「就用这个目录」' : '这里没有子文件夹，可以直接用这个目录'));
      if (picker.path !== '/') {
        const up = el('div', 'row');
        up.appendChild(el('div', 'row-icon folder')).innerHTML = ICONS.folder;
        const main = el('div', 'row-main');
        main.appendChild(el('div', 'row-name', '返回上一级'));
        up.appendChild(main);
        up.addEventListener('click', () => { picker.path = parentPath(picker.path); load(); });
        list.appendChild(up);
      }
      folders.forEach((folder) => {
        const row = el('div', 'row');
        row.appendChild(el('div', 'row-icon folder')).innerHTML = ICONS.folder;
        const main = el('div', 'row-main');
        main.appendChild(el('div', 'row-name', folder.name));
        main.appendChild(el('div', 'row-sub', folder.fileCount + ' 个文件'));
        row.appendChild(main);
        row.addEventListener('click', () => { picker.path = folder.path; load(); });
        list.appendChild(row);
      });
    } catch (err) {
      list.textContent = '';
      list.appendChild(el('div', 'fm-error', err.message));
    }
  }
  await load();

  const choice = await openDialog({
    title: '选择收集目标文件夹',
    message: '访客上传的照片会存进这个目录',
    body: box,
    actions: [{ label: '就用这个目录', value: 'ok' }, { label: '取消', value: null, variant: 'text' }]
  });
  if (choice !== 'ok') return null;
  return { volumeId: picker.volumeId, path: picker.path };
}

/** 创建照片收集链接：访客免登录上传，额度可限制 */
async function createCollectDialog(view, presetPath) {
  if (!view || !view.volumeId) { snackbar('请先打开一个目录', 'err'); return; }
  const folderField = document.createElement('input');
  folderField.value = presetPath || view.path || '/';
  const nameField = document.createElement('input');
  nameField.value = '照片收集-' + new Date().toISOString().slice(0, 10);
  nameField.placeholder = '例如：小明生日会';
  const hoursField = document.createElement('input');
  hoursField.type = 'number';
  hoursField.value = '168';
  const fileMBField = document.createElement('input');
  fileMBField.type = 'number';
  fileMBField.value = '20';
  const totalMBField = document.createElement('input');
  totalMBField.type = 'number';
  totalMBField.value = '2048';
  const passwordField = document.createElement('input');
  passwordField.type = 'text';
  passwordField.placeholder = '留空表示不需要密码';

  const box = el('div', 'collect-form');
  const rows = [
    ['目标文件夹', folderField, '照片会存进这个目录（可以是还不存在的新目录名）'],
    ['收集名称', nameField, '访客在链接页看到的标题'],
    ['有效期（小时）', hoursField, '0 或留空表示永久有效'],
    ['单个文件上限（MB）', fileMBField, '超过就拒绝，0 表示不限'],
    ['总共最多（MB）', totalMBField, '收满后链接自动停止接收，0 表示不限'],
    ['访问密码', passwordField, '可选，留空则拿到链接的人都能上传']
  ];
  rows.forEach(([label, input, hint]) => {
    const row = el('div', 'collect-row');
    const text = el('div', 'collect-label');
    text.appendChild(el('div', 'collect-label-main', label));
    text.appendChild(el('div', 'collect-label-hint', hint));
    row.appendChild(text);
    input.className = 'collect-input';
    row.appendChild(input);
    box.appendChild(row);
  });

  const imagesOnlyRow = el('label', 'check-row');
  const imagesOnly = document.createElement('input');
  imagesOnly.type = 'checkbox';
  imagesOnly.checked = true;
  imagesOnlyRow.appendChild(imagesOnly);
  imagesOnlyRow.appendChild(el('span', null, '只接受照片和视频（推荐，挡掉乱传的文件）'));
  box.appendChild(imagesOnlyRow);

  const value = await openDialog({
    title: '创建照片收集链接',
    message: '把链接发给朋友，他们不用登录就能上传照片；你可以限制单个文件和总量。',
    body: box,
    actions: [{ label: '创建链接', value: 'create' }, { label: '取消', value: null, variant: 'text' }]
  });
  if (value !== 'create') return;

  const body = {
    volume: view.volumeId,
    kind: 'collect',
    collect: true,
    path: folderField.value.trim() || '/',
    name: nameField.value.trim(),
    expiresInHours: Number(hoursField.value || 0),
    password: passwordField.value,
    maxFileMB: Number(fileMBField.value || 0),
    maxTotalMB: Number(totalMBField.value || 0),
    imagesOnly: imagesOnly.checked
  };
  try {
    const result = await api('/api/share/create', { method: 'POST', body });
    const share = result.share;
    showCollectLink(share);
    refreshAllFileManagers();
  } catch (err) {
    snackbar(err.message, 'err');
  }
}

/** 创建成功后把链接亮出来，方便直接复制发给别人 */
function showCollectLink(share) {
  const box = el('div');
  const url = el('div', 'collect-link');
  url.textContent = share.url;
  box.appendChild(url);
  const hints = el('div', 'collect-hints');
  hints.appendChild(el('div', null, '· 访客打开链接即可上传，不需要账号'));
  hints.appendChild(el('div', null, '· 单个文件上限 ' + (share.maxFileBytes > 0 ? fmtSize(share.maxFileBytes) : '不限') +
    '，总共最多 ' + (share.maxTotalBytes > 0 ? fmtSize(share.maxTotalBytes) : '不限')));
  hints.appendChild(el('div', null, '· ' + (share.imagesOnly ? '只接受照片和视频' : '接受任意文件')));
  hints.appendChild(el('div', null, '· ' + (share.permanent ? '永久有效' : '有效期至 ' + fmtDate(share.expiresAt))));
  box.appendChild(hints);
  openDialog({
    title: '链接已创建',
    message: '把下面的地址发给要收集的人（也可以直接在这里复制）',
    body: box,
    actions: [
      { label: '复制链接', value: 'copy' },
      { label: '关闭', value: null, variant: 'text' }
    ]
  }).then((choice) => {
    if (choice === 'copy') {
      copyTextToClipboard(share.url);
      snackbar('链接已复制', 'ok');
    }
  });
}

function copyTextToClipboard(text) {
  if (navigator.clipboard && navigator.clipboard.writeText) {
    navigator.clipboard.writeText(text).catch(() => {});
    return;
  }
  const area = document.createElement('textarea');
  area.value = text;
  document.body.appendChild(area);
  area.select();
  try { document.execCommand('copy'); } catch (e) { /* 忽略 */ }
  area.remove();
}

/** 收集页整体：头部（标题与说明）+ 上传区 */
function renderCollectShell(data, token, wrap) {
  const head = el('header', 'share-head glass');
  const logo = el('img', 'share-logo');
  logo.src = '/logo.png';
  logo.alt = '';
  head.appendChild(logo);
  const title = el('div', 'share-title');
  title.appendChild(el('h1', null, data.name));
  title.appendChild(el('p', null, '照片收集 · 上传后由对方整理'));
  head.appendChild(title);
  const themeButton = iconButton(document.documentElement.style.getPropertyValue('--x') ? ICONS.sun : ICONS.moon,
                                 '切换深浅色', () => {
    toggleTheme();
    document.querySelectorAll('.share-head .icon-btn').forEach((button) => {
      button.innerHTML = document.documentElement.dataset.theme === 'dark' ? ICONS.sun : ICONS.moon;
    });
  });
  themeButton.id = 'share-theme-btn';
  head.appendChild(themeButton);
  wrap.appendChild(head);

  const bodyEl = renderCollectPage(data, token);
  wrap.appendChild(bodyEl);

  const foot = el('footer', 'share-foot');
  foot.appendChild(el('div', null, '由 MacNas 提供 · 上传即完成，无需注册'));
  wrap.appendChild(foot);
}

/** 访客看到的收集页：选照片 → 上传队列 → 进度与结果 */
function renderCollectPage(data, token) {
  const bodyEl = el('div', 'share-body glass collect-body');
  const state = { total: data.uploadedBytes || 0, count: data.uploadedCount || 0, remaining: data.remainingBytes };

  const drop = el('div', 'collect-drop');
  drop.innerHTML = ICONS.camera;
  drop.appendChild(el('div', 'collect-drop-title', '点这里选择照片'));
  drop.appendChild(el('div', 'collect-drop-sub', '也可以把照片直接拖进来'));

  const hint = el('div', 'collect-hint');
  function renderHint() {
    hint.textContent = '';
    hint.appendChild(el('div', null, '已收到 ' + state.count + ' 张'));
    const limits = [];
    if (data.maxFileBytes > 0) limits.push('单个不超过 ' + fmtSize(data.maxFileBytes));
    if (data.maxTotalBytes > 0) limits.push('总共最多 ' + fmtSize(data.maxTotalBytes));
    if (limits.length) hint.appendChild(el('div', null, limits.join(' · ')));
    if (state.remaining !== undefined && data.maxTotalBytes > 0) {
      hint.appendChild(el('div', null, '还可以上传 ' + fmtSize(Math.max(0, state.remaining))));
    }
    if (data.imagesOnly) hint.appendChild(el('div', null, '只收照片和视频'));
  }
  renderHint();

  const queue = el('div', 'collect-queue');
  bodyEl.appendChild(drop);
  bodyEl.appendChild(hint);
  bodyEl.appendChild(queue);

  function uploadOne(file) {
    return new Promise((resolve) => {
      const row = el('div', 'collect-item');
      const name = el('div', 'collect-item-name', file.name);
      const bar = el('div', 'progress');
      const fill = el('div', 'bar');
      bar.appendChild(fill);
      const status = el('div', 'collect-item-status', '准备中…');
      row.appendChild(name);
      row.appendChild(bar);
      row.appendChild(status);
      queue.appendChild(row);

      const params = new URLSearchParams({ name: file.name });
      const request = new XMLHttpRequest();
      request.open('POST', '/api/pub/' + token + '/upload?' + params.toString(), true);
      request.setRequestHeader('Content-Type', file.type || 'application/octet-stream');
      request.upload.addEventListener('progress', (event) => {
        if (event.lengthComputable) fill.style.width = Math.round((event.loaded / event.total) * 100) + '%';
      });
      request.addEventListener('load', () => {
        let payload = null;
        try { payload = JSON.parse(request.responseText); } catch (e) { payload = null; }
        if (request.status >= 200 && request.status < 300 && payload && payload.ok) {
          fill.style.width = '100%';
          row.classList.add('done');
          status.textContent = payload.outcome === 'deduplicated' ? '已收到（这张之前传过，不占新空间）' : '已收到';
          state.count = payload.uploadedCount || state.count + 1;
          state.remaining = payload.remainingBytes !== undefined ? payload.remainingBytes : state.remaining;
          renderHint();
          resolve(true);
        } else {
          row.classList.add('failed');
          status.textContent = (payload && payload.error) || ('上传失败（' + request.status + '）');
          resolve(false);
        }
      });
      request.addEventListener('error', () => {
        row.classList.add('failed');
        status.textContent = '网络错误';
        resolve(false);
      });
      request.send(file);
    });
  }

  async function uploadFiles(files) {
    const list = [...files].filter(Boolean);
    if (!list.length) return;
    for (const file of list) {
      await uploadOne(file);
    }
  }

  drop.addEventListener('click', () => {
    // 走统一入口：手机上必须先把 input 挂进文档，点击才会弹出选择器
    openFilePicker({
      accept: data.imagesOnly ? 'image/*,video/*' : '*/*',
      multiple: true,
      onFiles: (files) => uploadFiles(files)
    });
  });
  bindCollectDrop(drop, uploadFiles);

  return bodyEl;
}

/** 收集页的拖拽：只处理文件（不需要目录展开） */
function bindCollectDrop(node, onFiles) {
  node.addEventListener('dragover', (event) => {
    event.preventDefault();
    node.classList.add('over');
  });
  node.addEventListener('dragleave', () => node.classList.remove('over'));
  node.addEventListener('drop', (event) => {
    event.preventDefault();
    node.classList.remove('over');
    if (event.dataTransfer && event.dataTransfer.files) onFiles(event.dataTransfer.files);
  });
}

/* ---------------- 存储分析 ---------------- */

const CATEGORY_COLORS = ['#0B57D0', '#16855C', '#B26A00', '#8E24AA', '#C2185B', '#00838F',
                         '#5D4037', '#455A64', '#7B1FA2', '#2E7D32', '#EF6C00', '#546E7A'];

function categoryLabel(key) {
  if (!key || key === '其它') return '无扩展名';
  return key.toUpperCase();
}

async function openAnalytics(options) {
  const opts = options || {};
  const existing = WM.items.find((win) => win.app.id === 'analytics');
  if (existing) { WM.focus(existing); return existing.analyticsView; }

  const win = WM.open(APPS.analytics, { title: '存储分析', width: 1000, height: 700 });
  const view = { win, volumeId: opts.volumeId || null, data: null, loading: true };
  win.analyticsView = view;
  win.sessionState = () => ({ volumeId: view.volumeId });

  const body = win.body;
  const box = el('div', 'an');
  const head = el('div', 'an-head');
  const chips = el('div', 'an-chips');
  const refresh = iconButton(ICONS.refresh, '刷新', () => load());
  head.appendChild(chips);
  head.appendChild(refresh);
  box.appendChild(head);
  const content = el('div', 'an-body');
  box.appendChild(content);
  body.appendChild(box);

  function renderChips() {
    chips.textContent = '';
    const all = el('button', 'photos-chip' + (view.volumeId === null ? ' on' : ''), '全部目录');
    all.addEventListener('click', () => { view.volumeId = null; renderChips(); load(); });
    chips.appendChild(all);
    (state.volumes || []).forEach((volume) => {
      const chip = el('button', 'photos-chip' + (volume.id === view.volumeId ? ' on' : ''), volume.name);
      chip.addEventListener('click', () => { view.volumeId = volume.id; renderChips(); load(); });
      chips.appendChild(chip);
    });
  }

  function statCard(label, value, hint, tone) {
    const card = el('div', 'an-card' + (tone ? ' ' + tone : ''));
    card.appendChild(el('div', 'an-card-label', label));
    card.appendChild(el('div', 'an-card-value', value));
    if (hint) card.appendChild(el('div', 'an-card-hint', hint));
    return card;
  }

  function render() {
    content.textContent = '';
    if (view.loading) { content.appendChild(el('div', 'pv-loading', '正在统计…')); return; }
    const data = view.data;
    if (!data) { content.appendChild(el('div', 'pv-loading', '暂时拿不到统计数据')); return; }

    // 概览卡片
    const cards = el('div', 'an-cards');
    cards.appendChild(statCard('逻辑大小', fmtSize(data.logicalBytes), data.fileCount + ' 个文件'));
    cards.appendChild(statCard('实际占用', fmtSize(data.physicalBytes), data.uniqueBlobCount + ' 份唯一内容'));
    cards.appendChild(statCard('去重节省', fmtSize(data.savedBytes),
      '省了 ' + (data.savedRatio * 100).toFixed(1) + '%', 'good'));
    cards.appendChild(statCard('重复浪费', fmtSize(data.wastedBytes),
      (data.duplicates || []).length + ' 组重复内容', data.wastedBytes > 0 ? 'warn' : ''));
    if (data.historyCount > 0) {
      cards.appendChild(statCard('历史版本', fmtSize(data.historyBytes), data.historyCount + ' 个版本'));
    }
    if (data.trashCount > 0) {
      cards.appendChild(statCard('回收站', fmtSize(data.trashBytes), data.trashCount + ' 项待清理'));
    }
    content.appendChild(cards);

    // 类型分布
    const categories = (data.categories || []).filter((item) => item.logicalBytes > 0);
    const total = categories.reduce((sum, item) => sum + item.logicalBytes, 0);
    const section = el('section', 'an-section glass');
    section.appendChild(el('h3', null, '文件类型分布'));
    if (!categories.length) {
      section.appendChild(el('div', 'an-empty', '这个范围里还没有文件'));
    } else {
      const bar = el('div', 'an-bar');
      categories.slice(0, 12).forEach((item, index) => {
        const segment = el('span', 'an-seg');
        segment.style.width = Math.max(1.2, (item.logicalBytes / total) * 100) + '%';
        segment.style.background = CATEGORY_COLORS[index % CATEGORY_COLORS.length];
        segment.title = categoryLabel(item.key) + ' · ' + fmtSize(item.logicalBytes);
        bar.appendChild(segment);
      });
      section.appendChild(bar);
      const legend = el('div', 'an-legend');
      categories.slice(0, 12).forEach((item, index) => {
        const row = el('div', 'an-legend-row');
        const dot = el('span', 'an-dot');
        dot.style.background = CATEGORY_COLORS[index % CATEGORY_COLORS.length];
        row.appendChild(dot);
        row.appendChild(el('span', 'an-legend-name', categoryLabel(item.key)));
        row.appendChild(el('span', 'an-legend-count', item.fileCount + ' 个'));
        row.appendChild(el('span', 'an-legend-size', fmtSize(item.logicalBytes)));
        const percent = el('span', 'an-legend-percent', (item.logicalBytes / total * 100).toFixed(1) + '%');
        row.appendChild(percent);
        legend.appendChild(row);
      });
      section.appendChild(legend);
    }
    content.appendChild(section);

    // 大小分布
    const buckets = (data.sizeBuckets || []).filter((item) => item.fileCount > 0);
    const sizeSection = el('section', 'an-section glass');
    sizeSection.appendChild(el('h3', null, '文件大小分布'));
    if (!buckets.length) {
      sizeSection.appendChild(el('div', 'an-empty', '还没有文件'));
    } else {
      const maxBytes = Math.max(...buckets.map((item) => item.bytes), 1);
      const rows = el('div', 'an-buckets');
      [...(data.sizeBuckets || [])].forEach((bucket) => {
        const row = el('div', 'an-bucket-row');
        row.appendChild(el('span', 'an-bucket-label', bucket.label));
        const track = el('div', 'an-bucket-track');
        const fill = el('div', 'an-bucket-fill');
        fill.style.width = Math.max(bucket.bytes > 0 ? 1.5 : 0, (bucket.bytes / maxBytes) * 100) + '%';
        track.appendChild(fill);
        row.appendChild(track);
        row.appendChild(el('span', 'an-bucket-count', bucket.fileCount + ' 个'));
        row.appendChild(el('span', 'an-bucket-size', fmtSize(bucket.bytes)));
        if (bucket.largestId) {
          const jump = el('button', 'btn text an-bucket-jump', '看最大的');
          jump.addEventListener('click', () => openPreview({ volumeId: bucket.largestVolumeId, id: bucket.largestId, path: bucket.largestName }));
          row.appendChild(jump);
        }
        rows.appendChild(row);
      });
      sizeSection.appendChild(rows);
    }
    content.appendChild(sizeSection);

    // 重复内容
    const dupSection = el('section', 'an-section glass');
    dupSection.appendChild(el('h3', null, '重复内容报告'));
    const dups = data.duplicates || [];
    if (!dups.length) {
      dupSection.appendChild(el('div', 'an-empty', '没有重复内容，空间利用得很干净'));
    } else {
      dupSection.appendChild(el('div', 'an-note', '同一份内容被多条记录引用。删掉多余的记录就能收回这些空间（内容不会被删，直到最后一条记录也删掉）。'));
      dups.slice(0, 12).forEach((item) => {
        const row = el('div', 'an-dup-row');
        const info = el('div', 'an-dup-info');
        info.appendChild(el('div', 'an-dup-name', (item.names && item.names[0]) || item.sha256.slice(0, 12)));
        info.appendChild(el('div', 'an-dup-sub',
          '被引用 ' + item.refCount + ' 次 · 单份 ' + fmtSize(item.size) + ' · ' +
          (item.names || []).slice(1, 4).join('、')));
        row.appendChild(info);
        const wasted = el('div', 'an-dup-wasted', '可省 ' + fmtSize(item.wastedBytes));
        row.appendChild(wasted);
        dupSection.appendChild(row);
      });
    }
    content.appendChild(dupSection);

    // 大文件
    const bigSection = el('section', 'an-section glass');
    bigSection.appendChild(el('h3', null, '最大的文件'));
    const largest = data.largest || [];
    if (!largest.length) {
      bigSection.appendChild(el('div', 'an-empty', '还没有文件'));
    } else {
      largest.slice(0, 10).forEach((item) => {
        const row = el('div', 'an-big-row');
        row.appendChild(el('div', 'an-big-name', item.name));
        row.appendChild(el('div', 'an-big-path', item.path));
        row.appendChild(el('div', 'an-big-size', fmtSize(item.size)));
        row.addEventListener('click', () => {
          openPreview({ volumeId: item.volumeId, id: item.id, path: item.path });
        });
        bigSection.appendChild(row);
      });
    }
    content.appendChild(bigSection);

    if (data.missingBlobs > 0) {
      content.appendChild(el('div', 'readonly-banner', '有 ' + data.missingBlobs + ' 条记录找不到对应内容（可能是被外部删除了），可以在设置里用「按内容重建索引」修复。'));
    }
  }

  async function load() {
    view.loading = true;
    render();
    try {
      const params = view.volumeId ? { volume: view.volumeId } : {};
      view.data = await api('/api/analytics', { params });
      WM.setTitle(win, '存储分析 · 已省 ' + fmtSize(view.data.savedBytes));
    } catch (err) {
      view.data = null;
      snackbar(err.message, 'err');
    }
    view.loading = false;
    render();
  }

  renderChips();
  render();
  await load();
  return view;
}

/* ---------------- 照片（时间线） ---------------- */

function monthLabel(iso) {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return '未知时间';
  return date.getFullYear() + ' 年 ' + (date.getMonth() + 1) + ' 月';
}

async function openPhotos(options) {
  const opts = options || {};
  const existing = WM.items.find((win) => win.app.id === 'photos');
  if (existing) { WM.focus(existing); return existing.photosView; }

  const win = WM.open(APPS.photos, { title: '照片', width: 1040, height: 700 });
  const view = {
    win,
    volumeId: opts.volumeId || (state.volumes[0] ? state.volumes[0].id : null),
    path: '/',
    kind: 'all',
    loading: true,
    items: []
  };
  win.photosView = view;
  win.sessionState = () => ({ volumeId: view.volumeId });

  const body = win.body;
  const box = el('div', 'photos');
  const head = el('div', 'photos-head');
  const chips = el('div', 'photos-chips');
  const actions = el('div', 'photos-actions');
  const kindButton = el('button', 'btn text');
  const refreshButton = iconButton(ICONS.refresh, '刷新', () => load());
  actions.appendChild(kindButton);
  actions.appendChild(refreshButton);
  head.appendChild(chips);
  head.appendChild(actions);
  box.appendChild(head);
  const list = el('div', 'photos-body');
  box.appendChild(list);
  body.appendChild(box);

  function renderChips() {
    chips.textContent = '';
    (state.volumes || []).forEach((volume) => {
      const chip = el('button', 'photos-chip' + (volume.id === view.volumeId ? ' on' : ''), volume.name);
      chip.addEventListener('click', () => { view.volumeId = volume.id; renderChips(); load(); });
      chips.appendChild(chip);
    });
    kindButton.textContent = view.kind === 'all' ? '只看图片' : (view.kind === 'image' ? '只看视频' : '全部媒体');
  }

  function render() {
    kindButton.textContent = view.kind === 'all' ? '只看图片' : (view.kind === 'image' ? '只看视频' : '全部媒体');
    list.textContent = '';
    if (view.loading) { list.appendChild(el('div', 'photos-empty', '正在读取…')); return; }
    if (!view.items.length) {
      const empty = el('div', 'photos-empty');
      empty.innerHTML = ICONS.photos;
      empty.appendChild(el('div', null, '这里还没有照片或视频'));
      empty.appendChild(el('div', 'photos-empty-hint', '把照片拖进「文件管理」上传，就会出现在这里'));
      list.appendChild(empty);
      return;
    }
    let currentMonth = '';
    let grid = null;
    view.items.forEach((item) => {
      const month = monthLabel(item.createdAt);
      if (month !== currentMonth) {
        currentMonth = month;
        list.appendChild(el('div', 'photos-month', month + ' · ' + view.items.filter((one) => monthLabel(one.createdAt) === month).length + ' 项'));
        grid = el('div', 'photos-grid');
        list.appendChild(grid);
      }
      const cell = el('div', 'photo-cell');
      const image = el('img', 'photo-thumb');
      image.loading = 'lazy';
      image.alt = item.name;
      thumbLoader.schedule(image, '/api/thumbnail?' + new URLSearchParams({ volume: view.volumeId, id: item.id, size: '320' }));
      image.addEventListener('error', () => { cell.classList.add('broken'); image.remove(); });
      cell.appendChild(image);
      if (!item.isImage) cell.appendChild(el('span', 'photo-badge', '视频'));
      cell.appendChild(el('div', 'photo-name', item.name));
      cell.addEventListener('click', () => {
        openPreview({ volumeId: view.volumeId, id: item.id, path: item.path });
      });
      grid.appendChild(cell);
    });
  }

  async function load() {
    if (!view.volumeId) {
      view.loading = false;
      render();
      return;
    }
    view.loading = true;
    render();
    try {
      const data = await api('/api/media', { params: { volume: view.volumeId, path: view.path, kind: view.kind, limit: 400 } });
      view.items = data.items || [];
      view.total = data.total || view.items.length;
      WM.setTitle(win, '照片 · ' + view.items.length + (view.total > view.items.length ? ' / ' + view.total : '') + ' 项');
    } catch (err) {
      view.items = [];
      snackbar(err.message, 'err');
    }
    view.loading = false;
    render();
  }

  kindButton.addEventListener('click', () => {
    view.kind = view.kind === 'all' ? 'image' : (view.kind === 'image' ? 'video' : 'all');
    kindButton.textContent = view.kind === 'all' ? '只看图片' : (view.kind === 'image' ? '只看视频' : '全部媒体');
    load();
  });

  renderChips();
  render();
  await load();
  return view;
}

/* ---------------- 回收站 ---------------- */

/** 收集所有卷的回收站条目 */
async function fetchTrash() {
  const volumes = state.volumes || [];
  const results = await Promise.all(volumes.map(async (volume) => {
    try {
      const data = await api('/api/trash', { params: { volume: volume.id } });
      return { volume, items: data.items || [], retentionDays: data.retentionDays };
    } catch (err) {
      return { volume, items: [], retentionDays: 0 };
    }
  }));
  const items = [];
  let retentionDays = 30;
  results.forEach((result) => {
    retentionDays = result.retentionDays || retentionDays;
    result.items.forEach((item) => items.push(Object.assign({ volumeName: result.volume.name }, item)));
  });
  items.sort((a, b) => String(b.trashedAt || '').localeCompare(String(a.trashedAt || '')));
  return { items, retentionDays };
}

function trashDaysLeft(item, retentionDays) {
  if (!retentionDays || !item.trashedAt) return null;
  const trashed = new Date(item.trashedAt).getTime();
  if (Number.isNaN(trashed)) return null;
  const left = retentionDays - Math.floor((Date.now() - trashed) / 86400000);
  return Math.max(0, left);
}

async function openTrashManager() {
  const existing = WM.items.find((win) => win.app.id === 'trash');
  if (existing) { WM.focus(existing); return existing.trashView; }

  const win = WM.open(APPS.trash, { title: '回收站', width: 900, height: 620 });
  const view = { win, items: [], retentionDays: 30, loading: true };
  win.trashView = view;
  win.sessionState = () => ({});

  const body = win.body;
  body.textContent = '';
  const box = el('div', 'trash');
  const head = el('div', 'trash-head');
  const info = el('div', 'trash-info');
  const refreshButton = iconButton(ICONS.refresh, '刷新', () => load());
  const emptyButton = el('button', 'btn text danger');
  emptyButton.textContent = '清空回收站';
  emptyButton.addEventListener('click', async () => {
    if (!view.items.length) { snackbar('回收站已经是空的', 'err'); return; }
    const ok = await confirmDialog({
      title: '清空回收站？',
      message: '回收站里的 ' + view.items.length + ' 项将被彻底删除。若内容还被别处的文件引用，那一份会保留。',
      confirmLabel: '彻底删除'
    });
    if (!ok) return;
    const volumeIds = [...new Set(view.items.map((item) => item.volumeId))];
    for (const volumeId of volumeIds) {
      try { await api('/api/trash/empty', { method: 'POST', body: { volume: volumeId } }); }
      catch (err) { snackbar(err.message, 'err'); }
    }
    snackbar('回收站已清空', 'ok');
    await load();
    refreshTrashBadge();
  });
  head.appendChild(info);
  head.appendChild(refreshButton);
  head.appendChild(emptyButton);
  box.appendChild(head);
  const list = el('div', 'trash-list');
  box.appendChild(list);
  body.appendChild(box);

  function render() {
    info.textContent = '';
    const total = view.items.reduce((sum, item) => sum + (item.size || 0), 0);
    info.appendChild(el('div', 'trash-title', '回收站'));
    info.appendChild(el('div', 'trash-sub',
      view.items.length + ' 项 · ' + fmtSize(total) +
      (view.retentionDays > 0 ? ' · 保留 ' + view.retentionDays + ' 天后自动清理' : ' · 不会自动清理')));

    list.textContent = '';
    if (view.loading) { list.appendChild(el('div', 'trash-empty', '正在读取…')); return; }
    if (!view.items.length) {
      const empty = el('div', 'trash-empty');
      empty.innerHTML = ICONS.trash;
      empty.appendChild(el('div', null, '回收站是空的'));
      empty.appendChild(el('div', 'trash-empty-hint', '删除的文件会先放到这里，可以随时还原'));
      list.appendChild(empty);
      return;
    }
    view.items.forEach((item) => {
      const row = el('div', 'row trash-row');
      const icon = el('div', 'row-icon');
      icon.innerHTML = ICONS.file;
      row.appendChild(icon);

      const main = el('div', 'row-main');
      main.appendChild(el('div', 'row-name', item.name));
      const sub = el('div', 'row-sub');
      sub.appendChild(el('span', null, fmtSize(item.size)));
      sub.appendChild(el('span', null, '原位置 ' + (item.originalPath || item.path)));
      if (item.volumeName) sub.appendChild(el('span', 'tag', item.volumeName));
      if (item.historyCount > 0) sub.appendChild(el('span', 'tag', item.historyCount + ' 个历史版本'));
      const left = trashDaysLeft(item, view.retentionDays);
      if (left !== null) sub.appendChild(el('span', null, left > 0 ? left + ' 天后清理' : '待清理'));
      main.appendChild(sub);
      row.appendChild(main);

      const actions = el('div', 'row-actions');
      const restore = el('button', 'btn text');
      restore.textContent = '还原';
      restore.addEventListener('click', async () => {
        try {
          const result = await api('/api/trash/restore', { method: 'POST', body: { volume: item.volumeId, id: item.id } });
          snackbar('已还原到 ' + (result.path || '原位置'), 'ok');
          await load();
          refreshTrashBadge();
          refreshAllFileManagers();
        } catch (err) { snackbar(err.message, 'err'); }
      });
      actions.appendChild(restore);

      const purge = el('button', 'btn text danger');
      purge.textContent = '彻底删除';
      purge.addEventListener('click', async () => {
        const ok = await confirmDialog({
          title: '彻底删除？',
          message: '「' + item.name + '」将被永久删除。若内容还被别处的文件引用，那一份会保留。',
          confirmLabel: '彻底删除'
        });
        if (!ok) return;
        try {
          await api('/api/trash/purge', { method: 'POST', body: { volume: item.volumeId, id: item.id } });
          snackbar('已彻底删除', 'ok');
          await load();
          refreshTrashBadge();
        } catch (err) { snackbar(err.message, 'err'); }
      });
      actions.appendChild(purge);
      row.appendChild(actions);
      list.appendChild(row);
    });
  }

  async function load() {
    view.loading = true;
    render();
    const data = await fetchTrash();
    view.items = data.items;
    view.retentionDays = data.retentionDays;
    view.loading = false;
    render();
  }

  render();
  await load();
  return view;
}

/** 桌面图标上的回收站数量角标 */
function refreshTrashBadge() {
  // 桌面图标没了，角标挂在「应用」列表的回收站那一项上
  const badge = document.getElementById('trash-badge');
  if (!badge) return;
  const count = state.trashCount || 0;
  badge.textContent = count > 99 ? '99+' : String(count);
  setVisible(badge, !!count);
}

/* ---------------- 版本历史 ---------------- */

async function showVersions(view, file) {
  let data = null;
  try {
    data = await api('/api/versions', { params: { volume: view.volumeId, id: file.id } });
  } catch (err) {
    snackbar(err.message, 'err');
    return;
  }
  const versions = data.versions || [];
  const list = el('div', 'version-list');
  if (versions.length <= 1) {
    list.appendChild(el('div', 'version-empty', '这个文件还没有历史版本。覆盖上传后，旧内容会自动留在这里。'));
  } else {
    versions.forEach((version) => {
      const row = el('div', 'version-row' + (version.isCurrent ? ' current' : ''));
      const info = el('div', 'version-info');
      const title = el('div', 'version-title');
      title.textContent = version.isCurrent ? '当前版本' : '历史版本';
      if (version.isCurrent) title.appendChild(el('span', 'tag', '正在使用'));
      info.appendChild(title);
      const sub = el('div', 'version-sub');
      sub.appendChild(el('span', null, fmtSize(version.size)));
      sub.appendChild(el('span', null, version.isCurrent
        ? '上传于 ' + fmtDate(version.createdAt)
        : '替换于 ' + fmtDate(version.replacedAt)));
      sub.appendChild(el('span', 'mono', String(version.sha256).slice(0, 10) + '…'));
      info.appendChild(sub);
      row.appendChild(info);

      const actions = el('div', 'version-actions');
      if (!version.isCurrent && version.download) {
        const download = el('button', 'btn text');
        download.textContent = '下载';
        download.addEventListener('click', () => { window.location.href = version.download; });
        actions.appendChild(download);

        const restore = el('button', 'btn text');
        restore.textContent = '恢复此版本';
        restore.addEventListener('click', async () => {
          try {
            await api('/api/versions/restore', { method: 'POST', body: { volume: view.volumeId, id: file.id, sha256: version.sha256 } });
            snackbar('已恢复到该版本', 'ok');
            close();
            refreshView(view);
          } catch (err) { snackbar(err.message, 'err'); }
        });
        actions.appendChild(restore);
      }
      row.appendChild(actions);
      list.appendChild(row);
    });
  }

  let close = () => {};
  await openDialog({
    title: '版本历史 · ' + file.name,
    message: '每次覆盖上传都会把旧内容留成一个版本。因为内容按哈希存储，历史版本几乎不占用额外空间。',
    body: list,
    actions: [{ label: '关闭', value: null, variant: 'text' }],
    onMount: (context) => { close = () => context.close(null); }
  });
}

/* ---------------- 预览 ----------------
   与服务器端 PreviewRegistry 保持同一套扩展名判断：
   图片/视频/音频/PDF 走原文件，文本读出来，Word 转 HTML，其余用系统 QuickLook 出图。 */
const PREVIEW_EXTENSIONS = {
  image: ['jpg', 'jpeg', 'png', 'gif', 'webp', 'heic', 'heif', 'bmp', 'tiff', 'tif', 'svg', 'avif', 'ico'],
  video: ['mp4', 'm4v', 'mov', 'mkv', 'webm', 'avi', 'flv', 'wmv', 'mpg', 'mpeg', '3gp'],
  audio: ['mp3', 'm4a', 'wav', 'flac', 'aac', 'ogg', 'oga', 'opus', 'aiff', 'aif'],
  text: ['txt', 'md', 'markdown', 'log', 'csv', 'tsv', 'json', 'xml', 'yml', 'yaml', 'toml', 'ini', 'conf',
         'html', 'htm', 'css', 'js', 'mjs', 'ts', 'tsx', 'jsx', 'py', 'rb', 'go', 'rs', 'java', 'kt', 'c', 'h',
         'cpp', 'hpp', 'swift', 'sh', 'bash', 'zsh', 'sql', 'plist', 'srt', 'vtt', 'tex', 'diff', 'patch', 'env'],
  document: ['doc', 'docx', 'rtf', 'rtfd', 'odt', 'wordml', 'webarchive'],
  render: ['xls', 'xlsx', 'xlsm', 'numbers', 'ods', 'ppt', 'pptx', 'pps', 'ppsx', 'key', 'odp',
           'pages', 'epub', 'dwg', 'sketch', 'stl', 'obj', 'psd', 'ai', 'eps']
};
const PDF_EXTENSIONS = ['pdf'];

function previewExtension(name) {
  const dot = name.lastIndexOf('.');
  return dot >= 0 ? name.slice(dot + 1).toLowerCase() : '';
}

function previewKindOf(name) {
  const ext = previewExtension(name);
  if (!ext) return null;
  if (PDF_EXTENSIONS.includes(ext)) return 'pdf';
  const found = Object.keys(PREVIEW_EXTENSIONS).find((kind) => PREVIEW_EXTENSIONS[kind].includes(ext));
  return found || null;
}

function looksPreviewable(name) {
  return previewKindOf(name) !== null;
}

/** 取预览信息：桌面走 /api/preview，分享页走 /api/pub/<token>/preview */
async function fetchPreviewMeta(options) {
  if (options.shareToken) {
    return await apiPublic('/api/pub/' + options.shareToken + '/preview', { params: { id: options.id } });
  }
  const params = options.id
    ? { volume: options.volumeId, id: options.id }
    : { volume: options.volumeId, path: options.path };
  return await api('/api/preview', { params });
}

/** 根据预览信息造出内容节点（桌面窗口与分享页共用） */
function buildPreviewContent(meta, state) {
  const box = el('div', 'pv-canvas');
  const kind = meta.kind;
  const url = meta.content;

  if (kind === 'image' || kind === 'render') {
    const image = el('img', 'pv-image' + (state.scale === 'actual' ? ' actual' : ''));
    image.src = url;
    image.alt = meta.name;
    image.loading = 'eager';
    box.appendChild(image);
    return box;
  }
  if (kind === 'video') {
    const video = el('video', 'pv-media');
    video.src = url;
    video.controls = true;
    video.preload = 'metadata';
    video.playsInline = true;
    box.appendChild(video);
    return box;
  }
  if (kind === 'audio') {
    const wrap = el('div', 'pv-audio');
    const art = el('div', 'pv-audio-art');
    art.innerHTML = ICONS.audio;
    wrap.appendChild(art);
    const audio = el('audio', 'pv-media');
    audio.src = url;
    audio.controls = true;
    wrap.appendChild(audio);
    box.appendChild(wrap);
    return box;
  }
  if (kind === 'pdf' || kind === 'document') {
    const frame = el('iframe', 'pv-frame');
    if (kind === 'document') frame.setAttribute('sandbox', '');
    frame.src = url;
    box.appendChild(frame);
    return box;
  }
  if (kind === 'text') {
    const pre = el('pre', 'pv-text', '正在读取…');
    box.appendChild(pre);
    fetch(url, { credentials: 'same-origin' })
      .then((res) => res.text())
      .then((text) => { pre.textContent = text; })
      .catch(() => { pre.textContent = '读取失败，可以点右上角下载后用本地软件打开。'; });
    return box;
  }
  const card = el('div', 'pv-none');
  const art = el('div', 'pv-none-art', '?');
  card.appendChild(art);
  card.appendChild(el('div', 'pv-none-title', meta.name || '这个文件'));
  card.appendChild(el('div', 'pv-none-text', meta.note || '这个格式暂时无法预览，可以下载后用本地软件打开。'));
  box.appendChild(card);
  return box;
}

/** 预览窗口的工具栏 */
function buildPreviewToolbar(win, meta, state, onScaleChange, downloadURL, onClose) {
  const bar = el('div', 'pv-toolbar');
  const info = el('div', 'pv-info');
  info.appendChild(el('div', 'pv-name', meta.name || '预览'));
  const sub = el('div', 'pv-sub');
  sub.appendChild(el('span', null, fmtSize(meta.size || 0)));
  const kindLabel = { image: '图片', render: '渲染预览', video: '视频', audio: '音频', pdf: 'PDF',
                      text: '文本', document: '文档', none: '不可预览' }[meta.kind] || '';
  if (kindLabel) sub.appendChild(el('span', null, kindLabel));
  if (meta.note) sub.appendChild(el('span', null, meta.note));
  info.appendChild(sub);
  bar.appendChild(info);

  const actions = el('div', 'pv-actions');
  if (state.canScale) {
    const scaleButton = el('button', 'btn text');
    scaleButton.innerHTML = '<span>' + (state.scale === 'actual' ? '适应窗口' : '原始尺寸') + '</span>';
    scaleButton.addEventListener('click', () => {
      state.scale = state.scale === 'actual' ? 'fit' : 'actual';
      onScaleChange();
    });
    actions.appendChild(scaleButton);
  }
  const download = el('button', 'btn filled');
  download.innerHTML = ICONS.download + '<span>下载</span>';
  download.addEventListener('click', () => {
    if (downloadURL) { window.location.href = downloadURL; return; }
    if (meta.download) window.location.href = meta.download;
  });
  actions.appendChild(download);
  // 关闭按钮：桌面预览窗口和分享页浮层都要有。
  // 分享页以前只靠 Esc 或点浮层外部关闭，手机上根本关不掉 —— 这里补上明确的按钮。
  if (onClose) {
    const close = el('button', 'btn text pv-close');
    close.innerHTML = ICONS.close + '<span>关闭</span>';
    close.addEventListener('click', onClose);
    actions.appendChild(close);
  } else if (!win.isSharePreview) {
    const close = iconButton(ICONS.close, '关闭', () => WM.close(win));
    actions.appendChild(close);
  }
  bar.appendChild(actions);
  return bar;
}

/** 桌面：打开一个预览窗口 */
function openPreview(options) {
  const opts = options || {};
  const existing = WM.items.find((w) => w.app.id === 'preview' && w.previewKey === (opts.id || opts.path));
  if (existing) { WM.focus(existing); return existing.previewView; }

  const win = WM.open(APPS.preview, { title: '预览', width: 1020, height: 700 });
  win.previewKey = opts.id || opts.path;
  const state = { scale: 'fit', canScale: false };
  const view = { win, options: opts, state };
  win.previewView = view;

  // 布局记忆：下次打开时把同一个文件也恢复出来
  win.sessionState = () => (opts.shareToken ? {} : { volumeId: opts.volumeId, id: opts.id, path: opts.path });

  const paint = (meta) => {
    win.body.textContent = '';
    const shell = el('div', 'pv');
    state.canScale = meta.kind === 'image' || meta.kind === 'render';
    const toolbar = buildPreviewToolbar(win, meta, state, () => paint(meta));
    shell.appendChild(toolbar);
    shell.appendChild(buildPreviewContent(meta, state));
    win.body.appendChild(shell);
  };

  const loading = el('div', 'pv');
  loading.appendChild(el('div', 'pv-loading', '正在准备预览…'));
  win.body.appendChild(loading);

  WM.setTitle(win, '预览');
  fetchPreviewMeta(opts)
    .then((meta) => {
      view.meta = meta;
      WM.setTitle(win, '预览 · ' + (meta.name || ''));
      paint(meta);
    })
    .catch((err) => {
      win.body.textContent = '';
      const shell = el('div', 'pv');
      shell.appendChild(el('div', 'pv-loading', '预览失败：' + err.message));
      win.body.appendChild(shell);
    });
  return view;
}

/** 分享页：全屏浮层预览（分享页没有桌面窗口系统） */
async function openSharePreview(token, file) {
  const overlay = el('div', 'pv-overlay glass');
  const shell = el('div', 'pv pv-overlay-inner');
  const fakeWin = { isSharePreview: true, body: shell };
  const state = { scale: 'fit', canScale: false };
  overlay.appendChild(shell);
  overlay.addEventListener('click', (event) => { if (event.target === overlay) close(); });
  // 除了工具栏里的「关闭」，右上角再放一个 ×：内容很长或工具栏换行时也能一眼看到
  const corner = el('button', 'pv-corner-close');
  corner.innerHTML = ICONS.close;
  corner.title = '关闭';
  corner.setAttribute('aria-label', '关闭预览');
  corner.addEventListener('click', (event) => { event.stopPropagation(); close(); });
  overlay.appendChild(corner);
  const onKey = (event) => { if (event.key === 'Escape') close(); };
  function close() {
    document.removeEventListener('keydown', onKey);
    overlay.remove();
  }
  document.addEventListener('keydown', onKey);
  document.body.appendChild(overlay);
  shell.appendChild(el('div', 'pv-loading', '正在准备预览…'));

  try {
    const meta = await fetchPreviewMeta({ shareToken: token, id: file.id });
    state.canScale = meta.kind === 'image' || meta.kind === 'render';
    shell.textContent = '';
    shell.appendChild(buildPreviewToolbar(fakeWin, meta, state, () => {
      shell.textContent = '';
      shell.appendChild(buildPreviewToolbar(fakeWin, meta, state, () => {}, meta.download, close));
      shell.appendChild(buildPreviewContent(meta, state));
    }, meta.download, close));
    shell.appendChild(buildPreviewContent(meta, state));
  } catch (err) {
    shell.textContent = '';
    shell.appendChild(el('div', 'pv-loading', '预览失败：' + err.message));
  }
  return overlay;
}

/** 桌面不再放应用图标：应用入口只保留左下角的「应用」按钮。
    这里留一个空实现，是为了兼容历史上调用它的地方。 */
function renderDesktopIcons() {
  const box = $('desktop-icons');
  if (box) box.textContent = '';
}


function openApp(appId, session) {
  const saved = session || null;
  const extra = (saved && saved.extra) || {};
  const before = WM.items.length;
  // 恢复布局时目录可能已经不存在（换过卷/删过文件夹），统一做一次兜底
  const validVolume = extra.volumeId && volumeById(extra.volumeId) ? extra.volumeId : null;

  if (appId === 'files') {
    openFileManager({ volumeId: validVolume, path: validVolume ? (extra.path || '/') : '/',
                      mode: extra.mode, sort: extra.sort });
  } else if (appId === 'photos') {
    // 注意：这里必须无条件打开。之前这里被写成「只有 extra.volumeId 有效才打开」，
    // 而桌面图标点击时根本没有 volumeId，于是点「照片」永远没反应。
    openPhotos(validVolume ? { volumeId: validVolume } : {});
  } else if (appId === 'analytics') {
    openAnalytics(validVolume ? { volumeId: validVolume } : {});
  } else if (appId === 'preview') {
    if (validVolume) openPreview({ volumeId: validVolume, id: extra.id, path: extra.path });
  } else if (appId === 'search') {
    openSearch(extra.query || '');
  } else if (appId === 'trash') {
    openTrashManager();
  } else if (appId === 'shares') {
    openShareManager();
  } else if (appId === 'about') {
    openAbout();
  }

  const win = WM.items.length > before ? WM.items[WM.items.length - 1] : null;
  if (win && saved) applySessionGeometry(win, saved);
  return win;
}

function renderLauncher() {
  const box = $('app-launcher');
  box.textContent = '';
  [APPS.files, APPS.photos, APPS.analytics, APPS.search, APPS.shares, APPS.trash, APPS.about].forEach((app) => {
    const button = el('button', 'launcher-item');
    button.dataset.app = app.id;      // 给测试和自动化用，避免靠文字匹配
    const art = el('div', 'li-art');
    art.innerHTML = app.icon;
    button.appendChild(art);
    button.appendChild(el('span', null, app.name));
    if (app.id === 'trash') {
      const badge = el('span', 'li-badge');
      badge.id = 'trash-badge';
      setVisible(badge, false);
      button.appendChild(badge);
    }
    button.addEventListener('click', () => {
      setVisible(box, false);
      openApp(app.id);
    });
    box.appendChild(button);
  });
}

/** 关网页、切到后台、退出登录前立刻落盘，避免去抖的 400ms 内丢改动 */
function bindSessionFlush() {
  const flush = () => Session.save();
  window.addEventListener('pagehide', flush);
  window.addEventListener('beforeunload', flush);
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') flush();
  });
}

function bindSessionButton() {
  const button = $('session-btn');
  if (button) {
    button.addEventListener('click', () => {
      Session.setEnabled(!Session.enabled);
      const chip = $('tb-stats');
      if (chip) {
        setVisible(chip, true);
        const previous = chip.textContent;
        chip.textContent = Session.enabled ? '已记住窗口布局' : '不再记住窗口布局';
        setTimeout(() => {
          if (chip.textContent === '已记住窗口布局' || chip.textContent === '不再记住窗口布局') chip.textContent = previous;
        }, 2200);
      }
    });
  }
  Session.updateButton();
}

/* ---------------- 主题 ---------------- */
function applyTheme(theme) {
  document.documentElement.dataset.theme = theme;
  const icon = theme === 'dark' ? ICONS.sun : ICONS.moon;
  const themeButton = $('theme-btn');
  if (themeButton) themeButton.innerHTML = icon;
  const shareThemeButton = $('share-theme-btn');
  if (shareThemeButton) shareThemeButton.innerHTML = icon;
  try { localStorage.setItem('macnas-theme', theme); } catch (e) { /* 忽略 */ }
}

/* 元素的显示/隐藏在 CSS 里由 .hidden 类控制（display: none !important）。
   注意不要用 element.hidden 属性：静态面板在 HTML 里带的就是 class="hidden"，
   属性切来切去也不会让 .hidden 类消失，面板就永远显示不出来（「点应用没反应」就是这么来的）。 */
function setVisible(node, visible) {
  if (!node) return;
  node.classList.toggle('hidden', !visible);
}

function isVisible(node) {
  return !!node && !node.classList.contains('hidden');
}

function toggleTheme() {
  applyTheme(document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark');
}

/* ---------------- 事件绑定 ---------------- */
function bindEvents() {
  $('login-form').addEventListener('submit', submitLogin);
  $('logout-btn').addEventListener('click', logout);
  $('theme-btn').addEventListener('click', toggleTheme);
  $('tb-apps').addEventListener('click', (event) => {
    event.stopPropagation();
    setVisible($('app-launcher'), !isVisible($('app-launcher')));
  });
  $('app-launcher').addEventListener('click', (event) => event.stopPropagation());
  document.addEventListener('click', () => { setVisible($('app-launcher'), false); });

  $('file-input').addEventListener('change', (event) => {
    const files = Array.from(event.target.files || []);
    event.target.value = '';
    const view = pendingUploadTarget ? pendingUploadTarget.view : state.sessions[0];
    pendingUploadTarget = null;
    if (!view) return;
    enqueueUploads(files.map((file) => ({ file, relPath: '' })), view.volumeId, view.path);
  });

  const area = $('desktop-area');
  area.addEventListener('dragover', (event) => {
    if (dragHasFiles(event)) event.preventDefault();
  });
  area.addEventListener('drop', (event) => {
    if (dragHasFiles(event)) event.preventDefault();
  });

  document.addEventListener('keydown', (event) => {
    // 全局快捷键：任何时候都能唤起搜索
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
      event.preventDefault();
      openSearch();
      return;
    }
    // 在输入框里不劫持快捷键（搜索框要能正常复制文字）
    if (event.target && event.target.closest && event.target.closest('input, textarea, select')) return;

    const view = state.sessions.find((item) => item.win.id === WM.activeId);
    if (!view) return;

    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'c') {
      if (view.selection.size) { event.preventDefault(); copyToClipboard(view, 'copy'); }
      return;
    }
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'x') {
      if (view.selection.size) { event.preventDefault(); copyToClipboard(view, 'cut'); }
      return;
    }
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'v') {
      if (clipboardHasItems()) { event.preventDefault(); pasteInto(view, view.path); }
      return;
    }

    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'a') {
      event.preventDefault();
      selectAll(view);
      return;
    }
    if (event.key === 'Escape') {
      if (quickLookState) { event.preventDefault(); closeQuickLook(); return; }
      if (view.selection.size) { view.selection.clear(); renderView(view); }
      return;
    }
    if (event.key === 'Delete' || event.key === 'Backspace') {
      if (view.selection.size) { event.preventDefault(); deleteSelection(view); }
      return;
    }
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'u') {
      event.preventDefault();
      pickFiles(view);
      return;
    }
    // 空格 = Quick Look 式快速查看
    if (event.key === ' ' || event.code === 'Space') {
      event.preventDefault();
      if (quickLookState) closeQuickLook(); else openQuickLookForFocus(view);
      return;
    }
    if (event.key === 'Enter' && view.selection.size === 1) {
      const key = [...view.selection][0];
      event.preventDefault();
      if (key.startsWith('dir:')) {
        navigateTo(view, view.volumeId, key.slice(4));
      } else {
        const file = view.files.find((item) => item.id === key);
        if (file) (looksPreviewable(file.name) ? previewFile : renameFile)(view, file);
      }
      return;
    }
    if (event.key === 'ArrowDown' || event.key === 'ArrowUp' || event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
      const list = visibleEntries(view);
      if (!list.length) return;
      const current = list.findIndex((entry) => entry.key === view.focusKey);
      const forward = event.key === 'ArrowDown' || event.key === 'ArrowRight';
      let next = current < 0 ? (forward ? 0 : list.length - 1) : current + (forward ? 1 : -1);
      next = Math.max(0, Math.min(list.length - 1, next));
      event.preventDefault();
      view.focusKey = list[next].key;
      view.selection.clear();
      view.selection.add(list[next].key);
      view.anchorKey = list[next].key;
      renderView(view);
      if (quickLookState) openQuickLookForFocus(view, true);
      return;
    }
  });
}

/* ---------------- 启动 ---------------- */
async function init() {
  Session.init();
  bindSessionButton();
  bindSessionFlush();
  registerServiceWorker();
  document.body.classList.toggle('narrow', isNarrowScreen());
  window.addEventListener('resize', () => document.body.classList.toggle('narrow', isNarrowScreen()));
  let stored = null;
  try { stored = localStorage.getItem('macnas-theme'); } catch (e) { stored = null; }
  const prefersDark = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches;
  applyTheme(stored || (prefersDark ? 'dark' : 'light'));

  // 分享链接：只渲染分享页，不进入登录与桌面
  const shareToken = shareTokenFromPath();
  if (shareToken) {
    await renderSharePage(shareToken);
    return;
  }

  renderDesktopIcons();
  renderLauncher();
  bindEvents();

  try {
    const session = await api('/api/session');
    if (session.authenticated) await showDesktop(session.username);
    else showLockScreen();
  } catch (err) {
    showLockScreen();
  }
}

/* 供自动化测试使用 */
window.MacNas = {
  state,
  WM,
  APPS,
  Session,
  openApp,
  saveSession: () => Session.save(),
  restoreSession: () => Session.restore(),
  clearSession: () => Session.clear(),
  sessionEnabled: () => Session.enabled,
  openFileManager,
  openAbout,
  refreshAllFileManagers,
  enqueueUploads,
  navigateTo,
  refreshView,
  performTransfer,
  renderView,
  shareEntry,
  copyToClipboard,
  pasteInto,
  duplicateEntry,
  copyToDialog,
  showContextMenu,
  fileContextItems,
  blankContextItems,
  fileClipboard,
  clearClipboard,
  openSearch,
  openPreview,
  openSharePreview,
  looksPreviewable,
  applyReveal,
  openShareManager,
  openTrashManager,
  openPhotos,
  openAnalytics,
  createCollectDialog,
  openQuickLook,
  closeQuickLook,
  showUploadMenu,
  pickFolder,
  sortItems,
  selectAll,
  downloadSelectionZip,
  selectionZipURL,
  encodeFolderUpload: (files, rootName) => files.map((file) => {
    const relative = file.webkitRelativePath || file.name;
    const parts = relative.split('/');
    parts.pop();
    return { file, relPath: parts.join('/') };
  }),
  thumbLoader,
  isNarrowScreen,
  pickPhotos,
  SHA256,
  api,
  tryInstantUpload,
  enqueueUploads,
  fetchTrash,
  showVersions,
  refreshTrashBadge,
  renderSharePage,
  apiPublic
};

init();
