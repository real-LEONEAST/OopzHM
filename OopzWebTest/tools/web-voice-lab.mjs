import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';

const assets = new Map([
  ['/', { url: new URL('web-voice-lab/index.html', import.meta.url), type: 'text/html; charset=utf-8' }],
  ['/lab.js', { url: new URL('web-voice-lab/lab.js', import.meta.url), type: 'text/javascript; charset=utf-8' }]
]);

createServer(async (request, response) => {
  const asset = assets.get(request.url);
  if (request.method !== 'GET' || !asset) {
    response.writeHead(404).end();
    return;
  }
  try {
    const body = await readFile(asset.url);
    response.writeHead(200, {
      'Content-Type': asset.type,
      'Cache-Control': 'no-store',
      'Content-Security-Policy': "default-src 'none'; script-src 'self'; media-src 'self' blob:",
      'Permissions-Policy': 'microphone=(self), camera=()'
    });
    response.end(body);
  } catch {
    response.writeHead(500).end();
  }
}).listen(28691, '127.0.0.1');
