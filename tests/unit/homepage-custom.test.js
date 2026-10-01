// SPDX-License-Identifier: Apache-2.0
// Copyright 2022 Ivan Pinatti
//
// cspell:ignore noopener noreferrer
//
// Tests for configs/homepage/config/custom.js, the script Homepage loads into
// its page to show its own version as a badge beside the first widget.
// `make coverage` runs this file under node's test runner and fails below 100%
// of its lines, branches and functions.
//
// The script is plain browser JavaScript that reads `document`, `window`,
// `setInterval` and `clearInterval` as globals. Each test installs a small
// stand in for the parts of the DOM it touches, then loads the script afresh,
// so no browser is needed.

'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { test } = require('node:test');

const script = path.join(__dirname, '..', '..', 'configs', 'homepage', 'config', 'custom.js');

// A DOM element with only what custom.js uses.
function element(props = {}) {
  const el = {
    id: '',
    textContent: '',
    attributes: {},
    children: [],
    selectors: {},
    inserted: [],
    getAttribute(name) {
      return name in this.attributes ? this.attributes[name] : null;
    },
    querySelector(selector) {
      return this.selectors[selector] || null;
    },
    appendChild(child) {
      this.children.push(child);
      return child;
    },
    append(child) {
      this.children.push(child);
    },
    insertAdjacentElement(where, child) {
      this.inserted.push([where, child]);
      return child;
    },
    get firstElementChild() {
      return this.children[0] || null;
    },
  };
  return Object.assign(el, props);
}

// Installs a document whose getElementById answers from `ids`, a window, and
// timers that only record what they were given. Returns what the script did.
function load(ids) {
  const seen = { listeners: {}, intervals: [], cleared: [], created: [] };
  globalThis.document = {
    getElementById: (id) => ids[id] || null,
    createElement: (tag) => {
      const el = element({ tag });
      seen.created.push(el);
      return el;
    },
    addEventListener: (event, fn) => {
      seen.listeners[`document:${event}`] = fn;
    },
  };
  globalThis.window = {
    addEventListener: (event, fn) => {
      seen.listeners[`window:${event}`] = fn;
    },
  };
  globalThis.setInterval = (fn, ms) => {
    seen.intervals.push({ fn, ms });
    return 'iv';
  };
  globalThis.clearInterval = (id) => {
    seen.cleared.push(id);
  };
  delete require.cache[require.resolve(script)];
  require(script);
  return seen;
}

// A page with the widget row and a footer whose #version holds `version`.
function page(version, { first = true } = {}) {
  const footer = element();
  if (version) footer.selectors['#version'] = version;
  const widgetsWrap = element();
  if (first) widgetsWrap.children.push(element({ id: 'first-widget' }));
  return { ids: { 'widgets-wrap': widgetsWrap, footer }, widgetsWrap };
}

function badge(seen) {
  return seen.created.find((el) => el.id === 'header-version');
}

test('takes the version from the release link and places the badge after the first widget', () => {
  const link = element({ attributes: { href: 'https://github.com/gethomepage/homepage/releases/tag/v1.4.6' } });
  const { ids, widgetsWrap } = page(element({ selectors: { a: link } }));
  const seen = load(ids);
  const made = badge(seen);
  assert.ok(made);
  assert.equal(made.href, 'https://github.com/gethomepage/homepage');
  assert.equal(made.target, '_blank');
  assert.equal(made.rel, 'noopener noreferrer');
  assert.deepEqual(made.children.map((c) => c.textContent), ['Homepage', 'v1.4.6']);
  assert.deepEqual(widgetsWrap.firstElementChild.inserted, [['afterend', made]]);
});

test('falls back to the link text when its href names no tag', () => {
  const link = element({ attributes: { href: 'https://example.invalid/' }, textContent: '  v2.0.0 (abc)  ' });
  const seen = load(page(element({ selectors: { a: link } })).ids);
  assert.equal(badge(seen).children[1].textContent, 'v2.0.0');
});

test('reads the link text when the link has no href at all', () => {
  const link = element({ textContent: 'v3.1.0' });
  const seen = load(page(element({ selectors: { a: link } })).ids);
  assert.equal(badge(seen).children[1].textContent, 'v3.1.0');
});

test('reads a span when there is no link, and appends to an empty widget row', () => {
  const span = element({ textContent: ' v0.9.0 dev ' });
  const { ids, widgetsWrap } = page(element({ selectors: { span } }), { first: false });
  const seen = load(ids);
  assert.equal(badge(seen).children[1].textContent, 'v0.9.0');
  assert.deepEqual(widgetsWrap.children, [badge(seen)]);
});

test('reads the version element itself when it holds bare text', () => {
  const seen = load(page(element({ textContent: 'v5.0.0' })).ids);
  assert.equal(badge(seen).children[1].textContent, 'v5.0.0');
});

test('adds nothing when the version is empty', () => {
  const seen = load(page(element({ textContent: '   ' })).ids);
  assert.equal(badge(seen), undefined);
});

test('waits while the page has no #version yet', () => {
  const seen = load(page(null).ids);
  assert.equal(badge(seen), undefined);
});

test('waits while the widget row or footer is missing', () => {
  const seen = load({});
  assert.equal(seen.created.length, 0);
  assert.equal(typeof seen.listeners['document:DOMContentLoaded'], 'function');
  assert.equal(typeof seen.listeners['window:load'], 'function');
  assert.equal(seen.intervals[0].ms, 500);
});

test('the retry timer stops once the badge is in place', () => {
  const seen = load({ 'header-version': element() });
  assert.equal(seen.created.length, 0);
  seen.intervals[0].fn();
  assert.deepEqual(seen.cleared, ['iv']);
});

test('the retry timer gives up after sixty attempts', () => {
  const seen = load({});
  for (let i = 0; i < 59; i++) seen.intervals[0].fn();
  assert.deepEqual(seen.cleared, []);
  seen.intervals[0].fn();
  assert.deepEqual(seen.cleared, ['iv']);
});
