import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const model = vm.createContext({});
vm.runInContext(readFileSync(new URL('../Model.js', import.meta.url), 'utf8'), model);
const first = { serverSocket: '/tmp/first.sock', serverPid: 42, stateFile: '/tmp/first.json' };
const second = { serverSocket: '/tmp/second.sock', serverPid: 43, stateFile: '/tmp/second.json' };
const restarted = { ...first, serverPid: 44 };
const document = { serverSocket: first.serverSocket, serverPid: first.serverPid, panes: [{ agent: 'pi', paneId: '%1', sessionId: '$1', sessionName: 'agent-test' }] };
const row = model.normalize(document, first)[0];
assert.equal(row.serverSocket, first.serverSocket);
assert.equal(row.serverPid, first.serverPid);
assert.notEqual(row.key, model.normalize(document, second)[0].key);
assert.notEqual(row.key, model.normalize(document, restarted)[0].key);
assert.equal(model.sameServer(row, first), true);
assert.equal(model.sameServer(row, restarted), false);
assert.equal(model.sameServer(row, {}), false);
for (const socket of ['/tmp/first.sock', '/tmp/tmux-1000/default', '/tmp/中文.sock']) {
  let expected = 0xcbf29ce484222325n;
  for (const byte of Buffer.from(socket)) expected = BigInt.asUintN(64, (expected ^ BigInt(byte)) * 0x100000001b3n);
  assert.equal(model.socketHash(socket), expected.toString(16).padStart(16, '0'));
}
console.log('ok - file locator matches UTF-8 FNV-1a64 and rows bind socket/PID');

// Execute the QML display controller's actual functions without a GUI. FileView
// readers are represented by inert objects; any display process would be a bug.
const qml = readFileSync(new URL('../Main.qml', import.meta.url), 'utf8');
function functions(source) {
  const result = [];
  for (const match of source.matchAll(/    function (\w+)\([^)]*\) \{/g)) {
    const start = match.index + 4;
    let position = source.indexOf('{', start) + 1;
    let depth = 1;
    let quote = '';
    let escaped = false;
    for (; depth > 0; position++) {
      const char = source[position];
      if (quote) {
        if (escaped) escaped = false;
        else if (char === '\\') escaped = true;
        else if (char === quote) quote = '';
      } else if (char === '"' || char === "'") quote = char;
      else if (char === '{') depth++;
      else if (char === '}') depth--;
    }
    result.push(source.slice(start, position));
  }
  return result.join('\n');
}
const controller = vm.createContext({
  Model: model, settings: {}, home: '/home/test', configuredSocket: first.serverSocket,
  source: null, agents: [], previousStates: {}, notificationQueue: [], initialized: false,
  generatedAt: 0, dataSignature: '', revision: 0, errorText: '', notificationsEnabled: false,
  stateReader: null, root: {}, sourceFile: { reload() {} },
  stateReaderComponent: { createObject(_root, properties) { return { ...properties, reload() {}, destroy() { this.destroyed = true; } }; } },
});
vm.runInContext(functions(qml), controller);
controller.applySource(JSON.stringify(first), first.serverSocket);
controller.applyDocument(JSON.stringify(document), first);
assert.equal(controller.agents.length, 1);
const oldReader = controller.stateReader;
controller.applySource(JSON.stringify(restarted), first.serverSocket);
assert.equal(controller.agents.length, 0);
assert.equal(oldReader.destroyed, true);
controller.applyDocument(JSON.stringify(document), first);
assert.equal(controller.agents.length, 0, 'pending old snapshot cannot populate a replacement server');
controller.applyDocument(JSON.stringify(document), restarted);
assert.equal(controller.agents.length, 0, 'old snapshot at a reused custom path must not acquire a new PID');
controller.applyDocument(JSON.stringify({ ...document, serverPid: 44 }), restarted);
assert.equal(controller.agents[0].serverPid, 44);
controller.applySource(JSON.stringify({ ...restarted, stateFile: '/tmp/changed.json' }), first.serverSocket);
assert.equal(controller.agents.length, 0, 'path changes must clear rows before reloading');
controller.applySource(JSON.stringify({ ...restarted, stateFile: null }), first.serverSocket);
assert.equal(controller.agents.length, 0);
controller.applySource(JSON.stringify(second), first.serverSocket);
assert.equal(controller.source, null, 'wrong socket descriptor must be rejected');
controller.applySource('{', first.serverSocket);
assert.equal(controller.agents.length, 0);
assert.equal(controller.source, null);
assert.doesNotMatch(qml, /sourceProcess|state-source\.sh|server\.sh/);
assert.equal((qml.match(/    Process \{/g) || []).length, 1, 'display may only spawn the notification helper');
console.log('ok - source/PID/path invalidation clears rows and rejects pending old snapshots without command discovery');
