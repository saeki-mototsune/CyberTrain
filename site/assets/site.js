// CyberTrain: progressive enhancement only (copy buttons, file tabs, tutorial TOC).
(function () {
  'use strict';
  var d = document;
  // Copy buttons. Shell output lines (.out) are left out of the copied text.
  if (navigator.clipboard) d.querySelectorAll('figure.code').forEach(function (f) {
    var cap = f.querySelector('figcaption'), code = f.querySelector('code');
    if (!cap || !code) return;
    var b = d.createElement('button');
    b.type = 'button'; b.className = 'copy'; b.textContent = 'Copy';
    b.setAttribute('aria-label', 'Copy code: ' + (cap.querySelector('.code-path') || cap).textContent);
    b.addEventListener('click', function () {
      var ls = code.querySelectorAll('.ln'), t = ls.length ? [].filter.call(ls, function (l) { return !l.classList.contains('out'); }).map(function (l) { return l.textContent; }).join('\n') : code.textContent;
      navigator.clipboard.writeText(t).then(function () {
        b.textContent = 'Copied'; b.setAttribute('data-done', '');
        setTimeout(function () { b.textContent = 'Copy'; b.removeAttribute('data-done'); }, 1600);
      });
    });
    cap.appendChild(b);
  });
  // File tabs: without JS every panel is shown in turn.
  d.querySelectorAll('[data-tabs]').forEach(function (w) {
    var list = w.querySelector('[role=tablist]'), tabs = [].slice.call(list.querySelectorAll('[role=tab]'));
    list.hidden = false; w.classList.add('js');
    function sel(i, focus) {
      tabs.forEach(function (t, j) {
        t.setAttribute('aria-selected', i === j); t.tabIndex = i === j ? 0 : -1;
        d.getElementById(t.getAttribute('aria-controls')).hidden = i !== j;
      });
      w.parentNode.querySelectorAll('[data-note]').forEach(function (n) { n.classList.toggle('on', +n.getAttribute('data-note') === i); });
      if (focus) tabs[i].focus();
    }
    tabs.forEach(function (t, i) {
      t.addEventListener('click', function () { sel(i); });
      t.addEventListener('keydown', function (e) {
        var n = tabs.length, k = { ArrowRight: (i + 1) % n, ArrowLeft: (i + n - 1) % n, Home: 0, End: n - 1 }[e.key];
        if (k === undefined) return;
        e.preventDefault(); sel(k, 1);
      });
    });
    sel(0);
  });
  // Tutorial TOC: active step, "n / 14" counter, gold progress bar; collapsed below 900px.
  var toc = d.querySelector('.toc-d');
  if (!toc) return;
  var mq = matchMedia('(max-width: 899px)'), sum = toc.querySelector('summary');
  function mode() { toc.open = !mq.matches; if (mq.matches) sum.removeAttribute('tabindex'); else sum.tabIndex = -1; }
  sum.addEventListener('click', function (e) { if (!mq.matches) e.preventDefault(); });
  mq.addEventListener ? mq.addEventListener('change', mode) : mq.addListener(mode);
  mode();
  var links = [].slice.call(toc.querySelectorAll('a[href^="#"]'));
  var secs = links.map(function (a) { return d.getElementById(a.getAttribute('href').slice(1)); });
  var n = toc.querySelectorAll('li:not(.toc-x)').length, bar = toc.querySelector('[data-bar]'), cnt = toc.querySelector('[data-count]');
  links.forEach(function (a) { a.addEventListener('click', function () { if (mq.matches) toc.open = false; }); });
  var tick = 0;
  function upd() {
    tick = 0;
    var y = innerHeight * 0.3, cur = 0;
    secs.forEach(function (s, i) { if (s && s.getBoundingClientRect().top < y) cur = i; });
    links.forEach(function (a, i) { if (i === cur) a.setAttribute('aria-current', 'step'); else a.removeAttribute('aria-current'); });
    var k = Math.min(cur + 1, n);
    bar.style.width = (k / n * 100) + '%';
    cnt.textContent = k + ' / ' + n;
  }
  addEventListener('scroll', function () { if (!tick) { tick = 1; requestAnimationFrame(upd); } }, { passive: true });
  upd();
})();
