'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { createRequire } = require('node:module');
const { EventEmitter } = require('node:events');
const { Readable } = require('node:stream');
const childProcess = require('node:child_process');

// Exercise the real HTTP handler and CLI protocols without binding a socket.
// The enclosing Codex sandbox cannot nest sandbox-exec: permission enforcement
// remains covered by the separate external-server suite, not this harness.
module.exports = function inProcessServer(directory, options = {}) {
  let handler;
  const timers = new Set(), children = new Set(), errors = [];
  const localProcess = new EventEmitter();
  Object.assign(localProcess, { env: process.env, platform: process.platform, pid: process.pid, stdin: new Readable({ read() {} }), exit() {} });
  const server = new EventEmitter(); server.listen = (_port, _host, ready) => ready();
  function spawn(file, args, options) {
    if (file === '/usr/bin/sandbox-exec') { file = args[2]; args = args.slice(3); }
    const child = childProcess.spawn(file, args, options); children.add(child); child.on('close', () => children.delete(child)); return child;
  }
  const localRequire = createRequire(path.join(directory, 'server.js'));
  const context = vm.createContext({
    require: name => name === 'http' ? { createServer: listener => { handler = listener; return server; } } : name === 'child_process' ? { ...childProcess, spawn } : localRequire(name),
    __dirname: directory, process: localProcess, Buffer, URL, fetch,
    console: { log() {}, error: (...args) => errors.push(args.join(' ')) },
    setTimeout(fn, ms) { const timer = setTimeout(fn, ms); timers.add(timer); return timer; }, clearTimeout,
    setInterval(fn, ms) { const timer = setInterval(fn, ms); timers.add(timer); return timer; }, clearInterval,
  });
  let source = fs.readFileSync(path.join(directory, 'server.js'), 'utf8');
  if (options.legacyWorkflow) source = source.replace("workflow: { phase: 'meeting', participants: [], tasks: [], documents: [] }, questions: [],", 'workflow: null, questions: [],').replace("r.workflow = { phase: 'meeting', participants: [], tasks: [], documents: [] };", 'r.workflow = null;');
  vm.runInContext(source, context, { filename: 'server.js' });
  return {
    errors,
    request(route, body) {
      return new Promise((resolve, reject) => {
        const req = Readable.from(body === undefined ? [] : [Buffer.from(JSON.stringify(body))]);
        Object.assign(req, { url: route, method: body === undefined ? 'GET' : 'POST', headers: { host: '127.0.0.1:4777', 'x-office': '1', 'content-type': 'application/json' } });
        let status = 200;
        const res = { writeHead(code) { status = code; }, end(text) { try { resolve({ status, value: JSON.parse(text) }); } catch (error) { reject(error); } } };
        Promise.resolve(handler(req, res)).catch(reject);
      });
    },
    async close() {
      localProcess.emit('SIGTERM');
      for (const timer of timers) { clearTimeout(timer); clearInterval(timer); }
      await Promise.all([...children].map(child => new Promise(resolve => { child.once('close', resolve); child.kill('SIGTERM'); })));
    },
  };
};
