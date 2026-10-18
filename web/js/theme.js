// Runs synchronously in <head> so the chosen color mode applies before the page is drawn.
try {
  const t = localStorage.getItem('pianotunah.theme');
  if (t === 'light' || t === 'dark') document.documentElement.dataset.theme = t;
} catch { /* optional */ }
