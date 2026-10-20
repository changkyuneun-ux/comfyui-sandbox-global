// ComfyUI UI 로딩 측정 (A/B 비교용, 대기 없음 — 화면이 다 뜬 뒤 브라우저 콘솔에 붙여넣기)
// 같은 스크립트를 두 서버에서 실행해 표로 비교한다.
(() => {
  const e = performance.getEntriesByType('resource');
  const nav = performance.getEntriesByType('navigation')[0];
  const d = e.map(x => x.duration).sort((a, b) => a - b);
  const q = p => Math.round(d[Math.min(d.length - 1, Math.floor(d.length * p))] || 0);
  const oi = e.filter(x => x.name.includes('object_info')).map(o => ({ start_s: +(o.startTime / 1000).toFixed(1), ms: Math.round(o.duration), transfer: o.transferSize, decoded: o.decodedBodySize }));
  const r = {
    host: location.host,
    ready: !!(window.app && window.app.graph) && !document.querySelector('[class*=splash]'),
    all_resources_done_s: +(Math.max(...e.map(x => x.responseEnd)) / 1000).toFixed(1),
    html_ms: Math.round(nav.responseEnd),
    resources: e.length, from_cache: e.filter(x => x.transferSize === 0).length,
    p50_ms: q(0.5), p90_ms: q(0.9), max_ms: q(0.999),
    object_info: oi,
    node_types: Object.keys((window.LiteGraph && window.LiteGraph.registered_node_types) || {}).length,
    extensions: window.app && window.app.extensions ? window.app.extensions.length : null,
  };
  console.table(r); return r;
})();
