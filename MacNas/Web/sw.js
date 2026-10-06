/* MacNas 的 Service Worker
   目标只有一个：让手机把网页「加到主屏」后能像应用一样打开，
   断网时至少还能看到外壳并给出提示。所有 /api/ 请求都直接走网络，不缓存数据。 */
// 缓存名带版本号：sw.js 内容一变，浏览器就会重新安装，
// 安装时 skipWaiting + activate 里清掉旧缓存，用户不会卡在老版本上。
const CACHE = 'macnas-shell-v2';
// 只缓存这几个外壳文件；带 ?v= 指纹的 URL 也会进这里，旧的自然被新版清掉
const SHELL_PATHS = ['/', '/index.html', '/styles.css', '/app.js', '/logo.png', '/manifest.webmanifest'];
const SHELL = ['/', '/index.html', '/styles.css', '/app.js', '/logo.png', '/manifest.webmanifest'];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE).then((cache) => cache.addAll(SHELL)).then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE).map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;
  // 接口、分享、WebDAV 一律不缓存
  if (url.pathname.startsWith('/api/') || url.pathname.startsWith('/s/') || url.pathname.startsWith('/dav')) return;

  // 网页导航：网络优先，断网时退回缓存的外壳
  if (request.mode === 'navigate') {
    event.respondWith(
      fetch(request).catch(() => caches.match('/index.html').then((hit) => hit || caches.match('/')))
    );
    return;
  }

  // 静态资源也走「网络优先 + 断网回退缓存」。
  // 之前这里是缓存优先：只要 sw.js 自己没变，浏览器就不会重新安装，
  // 于是 /app.js 永远命中老缓存 —— 服务端已经更新了，用户手机上还在跑几天前的前端，
  // 表现就是「新加的功能点了没反应」。现在服务端一更新，刷新即可生效。
  event.respondWith(
    fetch(request)
      .then((response) => {
        if (response && response.ok && response.type === 'basic' && SHELL_PATHS.includes(url.pathname)) {
          const copy = response.clone();
          caches.open(CACHE).then((cache) => cache.put(request, copy));
        }
        return response;
      })
      .catch(() => caches.match(request).then((hit) => hit || caches.match('/index.html')))
  );
});
