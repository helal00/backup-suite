"use strict";

// V19: every text and UI colour pair meets WCAG AA in the light and the dark theme
// (4.5:1 for text, 3:1 for UI parts such as borders, focus rings and chart lines).

const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const path = require("path");

const css = fs.readFileSync(path.join(__dirname, "..", "public", "styles.css"), "utf8");

function tokenBlock(selectorStart) {
  const index = css.indexOf(selectorStart);
  assert.ok(index >= 0, `missing block ${selectorStart}`);
  const open = css.indexOf("{", index);
  const close = css.indexOf("}", open);
  const tokens = {};
  for (const match of css.slice(open + 1, close).matchAll(/--([a-z0-9-]+):\s*(#[0-9a-fA-F]{6})\s*;/g)) tokens[match[1]] = match[2];
  return tokens;
}

function luminance(hex) {
  const channels = [1, 3, 5].map((offset) => parseInt(hex.slice(offset, offset + 2), 16) / 255)
    .map((value) => (value <= 0.03928 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4));
  return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2];
}

function ratio(a, b) {
  const [light, dark] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (light + 0.05) / (dark + 0.05);
}

const TEXT_PAIRS = [
  ["text", "bg"], ["text", "panel"], ["text", "panel-strong"], ["text", "panel-sunken"],
  ["muted", "panel"], ["muted", "panel-strong"], ["muted", "panel-sunken"],
  ["accent", "panel"], ["accent", "panel-strong"], ["accent", "accent-soft"],
  ["accent-text", "accent"], ["accent-text", "accent-strong"], ["danger-text", "danger"],
  ["danger", "danger-soft"], ["danger", "panel-strong"], ["warn", "warn-soft"], ["ok", "ok-soft"],
  ["text", "accent-soft"], ["text", "warn-soft"], ["text", "danger-soft"], ["text", "ok-soft"]
];
const UI_PAIRS = [
  ["control-border", "panel"], ["control-border", "panel-strong"], ["focus", "panel"], ["focus", "panel-strong"],
  ["gauge-ok", "gauge-track"], ["gauge-warn", "gauge-track"], ["gauge-bad", "gauge-track"],
  ["chart-memory", "panel-strong"], ["chart-cpu", "panel-strong"], ["chart-available", "panel-strong"],
  ["accent", "panel-strong"], ["warn", "panel-strong"], ["danger", "panel-strong"]
];

const light = tokenBlock(":root {");
const darkMedia = tokenBlock(':root:not([data-theme="light"]) {');
const darkForced = tokenBlock(':root[data-theme="dark"] {');

test("the dark theme is defined twice with the same values", () => {
  assert.deepStrictEqual(darkMedia, darkForced);
});

test("every colour token has a dark value", () => {
  for (const token of Object.keys(light)) assert.ok(darkForced[token], `--${token} has no dark value`);
});

for (const [name, tokens] of [["light", light], ["dark", darkForced]]) {
  test(`${name} theme text contrast is at least 4.5:1`, () => {
    for (const [foreground, background] of TEXT_PAIRS) {
      const value = ratio(tokens[foreground], tokens[background]);
      assert.ok(value >= 4.5, `${name}: --${foreground} on --${background} is ${value.toFixed(2)}:1`);
    }
  });
  test(`${name} theme UI contrast is at least 3:1`, () => {
    for (const [foreground, background] of UI_PAIRS) {
      const value = ratio(tokens[foreground], tokens[background]);
      assert.ok(value >= 3, `${name}: --${foreground} on --${background} is ${value.toFixed(2)}:1`);
    }
  });
}
