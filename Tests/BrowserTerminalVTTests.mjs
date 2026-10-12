import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const testDirectory = dirname(fileURLToPath(import.meta.url));
const sourcePath = join(testDirectory, '..', 'Sources', 'HostApp', 'HostBrowserControlService.swift');
const source = await readFile(sourcePath, 'utf8');
assert.match(source, /vampResponsePresentation[\s\S]*?Shell ready\. Type a command here or open Terminal for direct control\./, 'ready shells render an explicit usable state');
assert.match(source, /value\.type === 'ready'[\s\S]*?vampRefreshTerminalCard/, 'terminalReady synchronously refreshes the stable response card');

// CSS is embedded inside JavaScript template literals. A backtick in a CSS
// comment closes the template and aborts the final Chat/Terminal enhancement
// script, silently falling back to legacy shell-style browser behavior.
const browserEnhancementStart = source.indexOf('// The browser client is a task stream');
assert.ok(browserEnhancementStart >= 0, 'browser enhancement script is present');
const browserEnhancement = source.slice(browserEnhancementStart);
const styleAssignments = [...browserEnhancement.matchAll(/\.textContent = `([\s\S]*?)`;\n/g)];
assert.ok(styleAssignments.length >= 3, 'browser enhancement style templates are intact');
for (const match of styleAssignments) {
  assert.equal(match[1].includes('`'), false, 'embedded CSS must not contain a template-closing backtick');
}
assert.match(source, /sendInput\(tabID, value \+ '\\r'\)/, 'browser composer submits PTY Enter as carriage return');
assert.doesNotMatch(source, /sendInput\(tabID, value \+ '\\n'\)/, 'browser composer must not use LF for interactive Enter');
assert.match(source, /globalThis\.crypto\.randomUUID\(\)\.toLowerCase\(\)/, 'Safari UUIDs are canonicalized when tabs are created');
assert.match(source, /const id = vampTerminalKey\(vampNewUUID\(\)\)/, 'terminal Map keys use the wire identity canonicalizer');
assert.match(source, /const sessionAgent = agent \|\| knownAgentTitles\[title\] \|\| null;/, 'known launcher titles preserve semantic agent identity across workspace presentation');
assert.match(source, /agent: sessionAgent,/, 'tabs store the recovered semantic agent identity');
assert.match(source, /setVampPresentation\(tab\?\.agent \? 'chat' : 'terminal'\)/, 'presentation follows canonical tab agent identity');
assert.match(source, /The shell did not acknowledge startup/, 'a missing terminal-ready event becomes an actionable error instead of infinite Opening');
const classStart = source.indexOf('class VampBrowserVT');
const classEnd = source.indexOf('\n\nconst vampNextTerminalTitle', classStart);
assert.ok(classStart >= 0, 'VampBrowserVT class is present');
assert.ok(classEnd > classStart, 'VampBrowserVT class boundary is present');

// Task plans must have their own authenticated/session-routed projection. Keep
// this guard close to the browser VT tests so a future UI refactor cannot
// silently route plan state through terminal output or screen rows.
assert.match(source, /BrowserTaskPlanEvent\(sessionID: message\.sessionID, terminalID: message\.terminalID/);
assert.match(source, /value\.sessionID && value\.sessionID !== sessionId/);
assert.match(source, /window\.vampApplyTaskPlanEvent\(terminalID, value\.event\)/);
assert.match(source, /window\.vampInferTaskPlan = \(tabID, semanticText\)/);
assert.match(source, /vampTaskPlanEventIsBound\(value\.event, sessionId, terminalID\)/);
assert.match(source, /task-plan-resume/);
assert.equal(source.includes('vampInferTaskPlan(tabID, tab.terminal'), false, 'task inference is not fed VT screen state');
assert.match(source, /let semanticSnapshot = tab\.responseText \|\| '';/, 'Chat renders the command-scoped byte-stream semantic projection');
assert.doesNotMatch(source, /const semanticSnapshot = tab\.terminal\.render\(\)/, 'Chat never renders the mutable VT screen as prose');

// A successful pairing must replace a stale browser socket before the new
// page upgrades to WebSocket. Otherwise the one-browser capacity guard closes
// the freshly paired page and QR/manual pairing looks like a bad code.
assert.match(source, /revokeWebSocketSessions\(reason: "browser-replaced"\)/);
assert.match(source, /private func revokeWebSocketSessions\(reason: String\)/);
assert.match(source, /\/\\p\{Cf\}\/u\.test\(character\)/, 'browser pairing ignores invisible iOS direction marks');
assert.match(source, /\$\('pair-button'\)\.onclick = \(\) => pair\(\);/, 'manual pairing does not pass MouseEvent as the code');
assert.match(source, /\$\('input'\)\?\.blur\(\);[\s\S]*?composerHasFocus = false;[\s\S]*?keyboardViewportUpdate\(\);/, 'approval cards release the mobile keyboard');

// Terminal mode is a real flex viewport, not the compact Chat preview with a
// fixed control overlay. Keep the iPhone keyboard layout in normal flow and
// make project chrome yield while the software keyboard is present.
assert.match(source, /body\.vamp-terminal-mode \.content \{[\s\S]*?display: flex !important;[\s\S]*?overflow: hidden !important;/);
assert.match(source, /body\.vamp-terminal-mode \.chat \{[\s\S]*?flex: 1 1 auto !important;[\s\S]*?min-height: 0 !important;/);
assert.match(source, /\.shell\.vamp-keyboard-open \.composer \{[\s\S]*?position: absolute !important;/);
assert.match(source, /\.shell\.vamp-keyboard-open \.task-context \{ display: flex !important; \}/);
assert.match(source, /\.shell\.vamp-keyboard-open \.tabs \{ display: flex !important; \}/);
assert.match(source, /\.shell\.vamp-keyboard-open \.content \{[\s\S]*?overflow-x: hidden !important;[\s\S]*?overflow-y: auto !important;/);
assert.doesNotMatch(source, /body:not\(\.vamp-terminal-mode\) \.shell\.vamp-keyboard-open \.stream-card\.output-message \.rich-body \{[\s\S]*?max-height: 132px !important;/, 'keyboard focus does not independently resize the active response card');
assert.doesNotMatch(source, /\.shell:has\(\.composer input:focus\) \.task-context,[\s\S]*?\.shell:has\(\.composer input:focus\) \.tabs \{[\s\S]*?display: none !important;/, 'focus does not replace the task hierarchy while Safari animates the keyboard');
assert.match(source, /if \(!terminalMode && !tab\.lastSubmittedCommand\) semanticSnapshot = '';/, 'unsolicited PTY startup output stays out of Chat');
assert.match(source, /body\.vamp-terminal-mode \.stream-card-head,[\s\S]*?body\.vamp-terminal-mode \.open-terminal-preview \{[\s\S]*?display: none !important;/);
assert.match(source, /const selected = navigation\.querySelector\('\.tab\.active'\)/);
assert.match(source, /navigation\.scrollLeft = Math\.min\(/);
assert.match(source, /const keyboardOpen = composerHasFocus \|\| viewportContracted/);
assert.match(source, /event\.target === \$\('input'\)[\s\S]*?composerHasFocus = true;[\s\S]*?keyboardViewportUpdate\(\)/);
assert.match(source, /const pageTop = Number\.isFinite\(viewport\?\.pageTop\)[\s\S]*?setProperty\('--vamp-vv-top', Math\.round\(pageTop\) \+ 'px'\)/, 'the workspace canvas follows WebKit visual viewport page coordinates');
assert.doesNotMatch(source, /keyboardAnchorTimers|restoreKeyboardScrollAnchor/, 'keyboard transitions do not run delayed scroll corrections');
assert.match(source, /html \{[\s\S]*?position: fixed !important;[\s\S]*?overflow: hidden !important;[\s\S]*?body \{[\s\S]*?position: fixed !important;[\s\S]*?overflow: hidden !important;/, 'the Safari layout document is fixed and cannot be panned by input focus');
assert.match(source, /\.content \{[\s\S]*?min-height: 0 !important;[\s\S]*?overflow-x: hidden !important;[\s\S]*?overflow-y: auto !important;/, 'the bounded conversation remains the sole vertical scroll owner');
assert.match(source, /window\.addEventListener\('scroll', lockLayoutViewport/, 'Safari layout scrolling is corrected at the document boundary');
assert.match(source, /window\.visualViewport\?\.addEventListener\('scroll',[\s\S]*?lockLayoutViewport\(\);[\s\S]*?keyboardViewportUpdate\(\);/, 'visual viewport panning is corrected before keyboard geometry is applied');
assert.match(source, /@media \(min-width: 900px\) \{[\s\S]*?width: min\(calc\(100vw - 80px\), 1120px\) !important;[\s\S]*?margin-inline: auto !important;[\s\S]*?transform: none !important;/, 'desktop workspace uses layout-viewport geometry and normal-flow centering');
assert.doesNotMatch(source, /@media \(min-width: 900px\) \{[\s\S]{0,1200}?height: calc\(var\(--vamp-visual-height/, 'desktop workspace height does not inherit a stale mobile VisualViewport value');
assert.doesNotMatch(source, /if \(tab\.readyNotified\) return;/, 'duplicate ready events must repair a missing browser projection');
assert.match(source, /const firstReady = !tab\.readyNotified;/, 'ready handling distinguishes one-shot queued input from idempotent UI repair');
assert.match(source, /\$\('input'\)\.addEventListener\('pointerdown',[\s\S]*?event\.preventDefault\(\);[\s\S]*?focus\(\{ preventScroll: true \}\)/, 'composer uses trusted prevent-scroll focus on iOS Safari');
assert.doesNotMatch(source, /focusin[\s\S]{0,500}scrollLatest\(true\)/, 'focusing the composer preserves the current conversation position');
const appendCommandStart = source.indexOf('appendCommand = (value, status, tabID = active) =>');
const reviewCommandStart = source.indexOf('\nreviewCommand = () =>', appendCommandStart);
assert.ok(appendCommandStart >= 0 && reviewCommandStart > appendCommandStart, 'appendCommand boundary is present');
const appendCommandSource = source.slice(appendCommandStart, reviewCommandStart);
assert.equal(appendCommandSource.includes('tab.outputCard = null'), false, 'submitting a command preserves the tab stream card');
const activeAppendCommandStart = source.lastIndexOf('appendCommand = (value, status, tabID = active) =>');
const activeReviewCommandStart = source.indexOf('\n  reviewCommand = () =>', activeAppendCommandStart);
assert.ok(activeAppendCommandStart >= 0 && activeReviewCommandStart > activeAppendCommandStart, 'active appendCommand override boundary is present');
assert.equal(source.slice(activeAppendCommandStart, activeReviewCommandStart).includes('tab.outputCard = null'), false, 'active browser handler preserves the stable stream card');
assert.match(source.slice(activeAppendCommandStart, activeReviewCommandStart), /tab\.responseSemantic = new VampSemanticStream\(\);[\s\S]*?tab\.responseText = '';/, 'each Chat submission starts a fresh semantic response segment');
assert.match(source, /structuredAgent = Boolean\(tab\.agent && vampStructuredProviders\.has\(tab\.agent\)\)[\s\S]*?if \(tab\.responseSemantic && !structuredAgent\)/, 'structured agent Chat must never consume PTY\/TUI bytes');
assert.match(source.slice(activeAppendCommandStart, activeReviewCommandStart), /chat\.appendChild\(tab\.outputCard\)/, 'the stable response card moves after its user request');

const escapeHTML = (value) => String(value)
  .replaceAll('&', '&amp;')
  .replaceAll('<', '&lt;')
  .replaceAll('>', '&gt;')
  .replaceAll('"', '&quot;')
  .replaceAll("'", '&#39;');

const browserModels = new Function('esc', `${source.slice(classStart, classEnd)}\nreturn {VampBrowserVT, VampSemanticStream};`)(escapeHTML);
const { VampBrowserVT, VampSemanticStream } = browserModels;
const textEncoder = new TextEncoder();
const terminal = (cols = 80, rows = 24) => new VampBrowserVT(cols, rows);

{
  const vt = terminal();
  vt.feed('\u001b[38;5;');
  vt.feed('255mHello');
  vt.feed('\u001b[0m');
  assert.equal(vt.render().includes('38;5;255m'), false, 'fragmented SGR is not rendered as text');
  assert.equal(vt.render().includes('Hello'), true, 'text after fragmented SGR is rendered');
  assert.match(vt.renderHTML(), /rgb\(238,238,238\)/, '256-color SGR reaches the cell renderer');
}

{
  const semantic = new VampSemanticStream();
  const bytes = textEncoder.encode('\u001b[38;5;255mPlan:\n1. Audit terminal\n2. Fix layout\n3. Run tests\u001b[0m');
  let rendered = '';
  for (const byte of bytes) rendered = semantic.feedBytes(Uint8Array.of(byte));
  assert.equal(rendered.includes('38;5;255m'), false, 'semantic Chat output consumes fragmented ANSI');
  assert.match(rendered, /Plan:\n1\. Audit terminal\n2\. Fix layout\n3\. Run tests/, 'semantic Chat output preserves task prose');
}

{
  const semantic = new VampSemanticStream();
  const encoder = new TextEncoder();
  let rendered = semantic.feedBytes(encoder.encode('prompt% echo hello\r'));
  rendered = semantic.feedBytes(encoder.encode('\nhello\r\n'));
  assert.match(rendered, /prompt% echo hello\nhello/, 'packet-split CRLF preserves completed Chat lines');
  rendered = semantic.feedBytes(encoder.encode('Downloading 10%\rDownloading 50%'));
  assert.match(rendered, /Downloading 50%$/, 'standalone carriage return rewrites only the active semantic line');
}

{
  const vt = terminal(40, 8);
  vt.feed('Downloading 10%\rDownloading 50%\rDownloading 100%');
  assert.equal(vt.render().split('\n')[0], 'Downloading 100%', 'carriage return rewrites the current line');
}

{
  const vt = terminal(40, 8);
  vt.feed('hello\u001b[2D!!');
  assert.equal(vt.render().split('\n')[0], 'hel!!', 'cursor movement overwrites existing cells');
}

{
  const vt = terminal(40, 8);
  vt.feed('abc\u001b[2K');
  assert.equal(vt.render().trim(), '', 'erase-line clears the active row');
}

{
  const vt = terminal(40, 8);
  const bytes = textEncoder.encode('café');
  for (const byte of bytes) vt.feedBytes(Uint8Array.of(byte));
  assert.equal(vt.render().split('\n')[0], 'café', 'UTF-8 characters survive byte fragmentation');
}

{
  const vt = terminal(40, 8);
  vt.feed('a\tb');
  assert.equal(vt.render().split('\n')[0].indexOf('b'), 8, 'tab stops use terminal columns');
}

{
  const vt = terminal(40, 8);
  vt.feed('\u001b[38;2;100;200;255mTRUECOLOR\u001b[0m');
  assert.match(vt.renderHTML(), /rgb\(100,200,255\)/, 'truecolor SGR reaches the cell renderer');
}

{
  const vt = terminal(40, 8);
  vt.feed('main buffer');
  vt.feed('\u001b[?1049halt buffer');
  assert.equal(vt.render().includes('alt buffer'), true, 'alternate screen is isolated while active');
  vt.feed('\u001b[?1049l');
  assert.equal(vt.render().includes('main buffer'), true, 'alternate screen restores the main buffer');
  assert.equal(vt.render().includes('alt buffer'), false, 'alternate screen content is not leaked after restore');
}

{
  const vt = terminal(40, 8);
  vt.feed('stable');
  vt.resize(80, 16);
  assert.equal(vt.cols, 80, 'resize updates terminal columns');
  assert.equal(vt.rows, 16, 'resize updates terminal rows');
  assert.equal(vt.render().split('\n')[0], 'stable', 'resize preserves visible terminal state');
}

console.log('browser VT regression checks passed');
