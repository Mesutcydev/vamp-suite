import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const testDirectory = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(testDirectory, '..', 'linux-host', 'index.html'), 'utf8');
const classStart = source.indexOf('class SemanticStream');
const classEnd = source.indexOf('\n    const $=', classStart);
assert.ok(classStart >= 0 && classEnd > classStart, 'Linux browser Chat semantic stream is present');

const SemanticStream = Function(`${source.slice(classStart, classEnd)}; return SemanticStream;`)();
const encoder = new TextEncoder();
const stream = new SemanticStream();

stream.feedBytes(encoder.encode('prompt$ echo hello\r'));
stream.feedBytes(encoder.encode('\n\u001b[32mhello\u001b[0m\r\nprompt$ '));
assert.equal(stream.text.includes('\u001b'), false, 'Chat never exposes ANSI controls');
assert.match(stream.text, /prompt\$ echo hello\nhello\nprompt\$ /, 'packet-split CRLF preserves readable command output');

const progress = new SemanticStream();
progress.feedBytes(encoder.encode('Downloading 10%\rDownloading 50%'));
assert.equal(progress.text, 'Downloading 50%', 'standalone carriage returns rewrite the current semantic line');

const bounded = new SemanticStream();
bounded.feedBytes(encoder.encode('x'.repeat(30_000)));
assert.equal(bounded.text.length, 24_000, 'Chat response memory stays bounded');

assert.match(source, /node\.responseSemantic=new SemanticStream\(\)/, 'each Chat submission starts a new response boundary');
assert.match(source, /if\(node\.responseSemantic&&node\.turns\.length\)/, 'startup output remains outside Chat turns');
assert.match(source, /looksLikeShellPrompt\(turn\.response\)/, 'returned shell prompts complete the current Chat turn');
assert.match(source, /agentProviders=\{opencode:.*pi:.*commandcode:.*chatgpt:.*claude:.*kimi:.*qwen:.*codex:.*aider:.*grok:.*gemini:/, 'all structured providers are selectable');
assert.match(source, /type:'agentPrompt'.*provider:node\.agent/, 'Agent Chat uses the selected semantic provider runner');
assert.match(source, /message\.type==='agentEvent'/, 'provider-native events populate Chat');
assert.match(source, /node\.responseSemantic=null/, 'Agent Chat never consumes interactive TUI bytes');
assert.match(source, /maxlength="12"/, 'pairing field is twelve digits');
assert.match(source, /\\d\{12\}/, 'pairing client validates twelve digits');
assert.match(source, /localStorage\.setItem\(pairingStorageKey/, 'pairing survives a browser refresh');
assert.match(source, /let token=loadStoredPairing\(\)/, 'a refreshed page restores its paired token');
assert.doesNotMatch(source, /event\.code===1008\|\|event\.code===1006/, 'a transient disconnect does not erase pairing');

const storageStart = source.indexOf("const pairingStorageKey=");
const storageEnd = source.indexOf("\n    const $=", storageStart);
const values = new Map();
const localStorage = {
  getItem: (key) => values.get(key) ?? null,
  setItem: (key, value) => values.set(key, value),
  removeItem: (key) => values.delete(key),
};
const pairing = Function('localStorage', `${source.slice(storageStart, storageEnd)}; return {loadStoredPairing,rememberPairing};`)(localStorage);
pairing.rememberPairing('paired-token', Date.now() / 1000 + 60);
assert.equal(pairing.loadStoredPairing(), 'paired-token', 'a valid paired token is restored after refresh');
pairing.rememberPairing('expired-token', Date.now() / 1000 - 1);
assert.equal(pairing.loadStoredPairing(), null, 'an expired paired token is discarded');

console.log('Linux browser Chat regression tests passed');
