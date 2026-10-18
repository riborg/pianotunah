// Körs synkront i <head> så att valt färgläge gäller innan sidan ritas.
try {
  const t = localStorage.getItem('pianotunah.theme');
  if (t === 'light' || t === 'dark') document.documentElement.dataset.theme = t;
} catch { /* valfritt */ }
