// files/twenty-web-server.js — Twenty's front door.
//
// Why this exists: `yarn build` produces an API on :3000 and a static SPA in
// packages/twenty-front/build. The API does not serve the SPA. Deployments therefore
// need something that (a) serves the static files and (b) forwards the API prefixes to
// the server. This does exactly that, in ~100 lines of stdlib node, no nginx required.
//
//   PORT/PORTS      listen port (default 80)
//   WEB_ROOT        path to packages/twenty-front/build
//   API_HOST/PORT   where twenty-server listens (default 127.0.0.1:3000)
//
// Proxied prefixes: /graphql /api /files /file /metadata /webhooks /healthz /client-config
// Everything else: static file, falling back to index.html for client-side routes.

const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = parseInt(process.env.PORTS || process.env.PORT || '80', 10);
const API_HOST = process.env.API_HOST || '127.0.0.1';
const API_PORT = parseInt(process.env.API_PORT || '3000', 10);
const WEB_ROOT = process.env.WEB_ROOT || '/opt/twenty/packages/twenty-front/build';

const API_PREFIXES = [
  '/graphql', '/api', '/files', '/file', '/metadata',
  '/webhooks', '/healthz', '/client-config', '/assets/',
];

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.ico': 'image/x-icon',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.ttf': 'font/ttf',
  '.map': 'application/json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
  '.webmanifest': 'application/manifest+json',
};

function proxy(req, res) {
  const opts = {
    host: API_HOST,
    port: API_PORT,
    method: req.method,
    path: req.url,
    headers: { ...req.headers, host: `${API_HOST}:${API_PORT}` },
  };
  const up = http.request(opts, (upRes) => {
    res.writeHead(upRes.statusCode || 502, upRes.headers);
    upRes.pipe(res);
  });
  up.on('error', (err) => {
    res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' });
    res.end(`API unreachable at ${API_HOST}:${API_PORT} — ${err.message}\n`);
  });
  req.pipe(up);
}

function sendFile(res, file, status = 200) {
  const ext = path.extname(file).toLowerCase();
  const headers = { 'content-type': MIME[ext] || 'application/octet-stream' };
  // hashed bundles are immutable; index.html must never be cached
  if (path.basename(file) === 'index.html') headers['cache-control'] = 'no-cache';
  else if (/\.[0-9a-f]{8,}\./.test(path.basename(file))) headers['cache-control'] = 'public, max-age=31536000, immutable';
  res.writeHead(status, headers);
  fs.createReadStream(file).pipe(res);
}

const server = http.createServer((req, res) => {
  const url = req.url.split('?')[0];

  if (API_PREFIXES.some((p) => url === p || url.startsWith(p + '/') || url.startsWith(p))) {
    return proxy(req, res);
  }

  // path traversal guard
  const rel = decodeURIComponent(url).replace(/^\/+/, '');
  let file = path.join(WEB_ROOT, rel);
  if (!path.resolve(file).startsWith(path.resolve(WEB_ROOT))) {
    res.writeHead(403); return res.end('forbidden');
  }

  fs.stat(file, (err, st) => {
    if (!err && st.isFile()) return sendFile(res, file);
    // directory-ish route -> index.html (client-side routing)
    const idx = path.join(WEB_ROOT, 'index.html');
    fs.access(idx, fs.constants.R_OK, (e2) => {
      if (e2) {
        res.writeHead(500, { 'content-type': 'text/plain; charset=utf-8' });
        return res.end(`SPA build not found at ${WEB_ROOT}\n`);
      }
      sendFile(res, idx);
    });
  });
});

server.on('error', (e) => {
  console.error('front door error:', e.message);
  process.exit(1);
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`twenty front door on :${PORT} -> web ${WEB_ROOT}, api ${API_HOST}:${API_PORT}`);
});
