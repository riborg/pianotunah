// UI strings. English is the default; the choice is stored per browser.

import en from './lang/en.js';
import sv from './lang/sv.js';

export const LANGS = { en, sv };
const KEY = 'pianotunah.lang';

let cur = 'en';
try {
  const saved = localStorage.getItem(KEY);
  if (saved in LANGS) cur = saved;
} catch { /* optional */ }

export const lang = () => cur;
export const locale = () => LANGS[cur].locale;
export const decimal = () => LANGS[cur].decimal;

export function setLang(l) {
  if (!(l in LANGS)) return;
  cur = l;
  try { localStorage.setItem(KEY, l); } catch { /* optional */ }
}

// tr('key', { n: 3 }) replaces {n}. Missing keys fall back to English.
export function tr(key, params) {
  const s = LANGS[cur][key] ?? en[key] ?? key;
  return params ? s.replace(/\{(\w+)\}/g, (m, p) => (p in params ? params[p] : m)) : s;
}

// Static markup. data-i18n-html is only used for markup from the language files.
export function translateDom(root = document) {
  document.documentElement.lang = cur;
  for (const el of root.querySelectorAll('[data-i18n]')) el.textContent = tr(el.dataset.i18n);
  for (const el of root.querySelectorAll('[data-i18n-html]')) el.innerHTML = tr(el.dataset.i18nHtml);
  for (const attr of ['title', 'aria-label', 'placeholder']) {
    for (const el of root.querySelectorAll(`[data-i18n-${attr}]`)) el.setAttribute(attr, tr(el.getAttribute(`data-i18n-${attr}`)));
  }
}
