/// Adapted from harness/client. Only bounded, validated page evidence crosses the bridge.
const browserAnnotationScript = r'''
var __happenBrowserAnnotations = window.__happenBrowserAnnotations || (function () {
  const documentId = '__HAPPEN_DOCUMENT__';
  let enabled = false, suspended = false, dragging = null, frame = 0, pointer = null;
  let picked = [], current = null, saved = [], serial = 0;
  const pending = new Map();
  const host = document.createElement('div');
  host.style.cssText = 'all:initial!important;position:fixed!important;inset:0!important;pointer-events:none!important;z-index:2147483647!important;';
  const root = host.attachShadow({mode:'closed'});
  const style = document.createElement('style');
  style.textContent = '.box{position:fixed;box-sizing:border-box;border:2px solid #0088ff;background:#0088ff10;pointer-events:none;border-radius:3px}.label,.marker{position:absolute;background:#0088ff;color:white;font:12px/20px -apple-system,sans-serif;padding:0 6px;border-radius:4px;white-space:nowrap;max-width:260px;overflow:hidden;text-overflow:ellipsis}.label{left:-2px;bottom:100%}.marker{left:-11px;top:-11px;border:2px solid white;border-radius:20px;min-width:16px;text-align:center;padding:0 3px}.add{position:fixed;pointer-events:auto;border:1px solid #1a1c1f14;border-radius:10px;background:white;color:#1a1c1f;font:13px/28px -apple-system,sans-serif;box-shadow:0 2px 4px #0002;padding:0 10px;cursor:pointer}';
  root.append(style);
  const hover = document.createElement('div'); hover.className = 'box'; hover.hidden = true;
  const label = document.createElement('span'); label.className = 'label'; hover.append(label); root.append(hover);
  const add = document.createElement('button'); add.className = 'add'; add.textContent = 'Add to chat'; add.hidden = true; root.append(add);
  document.documentElement.append(host);

  function text(value, limit = 1600) { return String(value || '').replace(/\s+/g, ' ').trim().slice(0, limit); }
  function rectOf(r) { return {x:r.left, y:r.top, width:r.width, height:r.height}; }
  function paint(node, r) {
    node.style.left = r.x + 'px'; node.style.top = r.y + 'px';
    node.style.width = r.width + 'px'; node.style.height = r.height + 'px';
    node.hidden = r.width <= 0 || r.height <= 0;
  }
  function parent(node) { return node.parentElement || node.getRootNode().host || null; }
  function hit(x, y) {
    let element = document.elementFromPoint(x, y);
    for (let depth = 0; element && element.shadowRoot && depth < 20; depth++) {
      const child = element.shadowRoot.elementFromPoint(x, y);
      if (!child || child === element) break;
      element = child;
    }
    if (!element || element === host || element === document.documentElement) return null;
    return element;
  }
  function selector(element) {
    const result = [];
    for (let node = element, depth = 0; node && depth < 12; node = node.parentElement, depth++) {
      let part = node.localName;
      if (node.id) { result.unshift('#' + CSS.escape(node.id)); break; }
      const siblings = node.parentElement ? Array.from(node.parentElement.children).filter(function (other) { return other.localName === node.localName; }) : [];
      if (siblings.length > 1) part += ':nth-of-type(' + (siblings.indexOf(node) + 1) + ')';
      result.unshift(part);
    }
    return result.join(' > ');
  }
  function pathOf(element) {
    const result = [];
    for (let node = element, depth = 0; node && depth < 8; node = parent(node), depth++) {
      result.unshift(node.localName + (node.id ? '#' + CSS.escape(node.id) : Array.from(node.classList).slice(0, 2).map(function (value) { return '.' + CSS.escape(value); }).join('')));
    }
    return result.join(' > ');
  }
  function target(element, kind, rect, selectedText) {
    const role = element.getAttribute('role') || ({button:'button',a:'link',input:'textbox',img:'img',textarea:'textbox'})[element.localName] || element.localName;
    const name = text(element.getAttribute('aria-label') || element.getAttribute('alt') || element.getAttribute('title') || element.textContent, 240);
    return {kind:kind, pageUrl:location.href, framePath:[], title:document.title,
      selector:selector(element), elementPath:pathOf(element), role:role, name:name || element.localName,
      nearbyText:text(parent(element) ? parent(element).textContent : element.textContent),
      immediateText:text(element.textContent, 500), selectedText:selectedText || null,
      rect:rect, point:{x:Math.max(0, rect.x),y:Math.max(0, rect.y)},
      viewport:{width:innerWidth,height:innerHeight}, theme:matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'};
  }
  function drawHover() {
    frame = 0;
    if (!enabled || suspended || !pointer) { hover.hidden = true; return; }
    if (dragging && Math.hypot(pointer.x - dragging.x, pointer.y - dragging.y) > 6) {
      paint(hover, {x:Math.min(pointer.x, dragging.x),y:Math.min(pointer.y, dragging.y),width:Math.abs(pointer.x-dragging.x),height:Math.abs(pointer.y-dragging.y)});
      label.textContent = 'Selected area'; return;
    }
    const element = hit(pointer.x, pointer.y);
    if (!element) { hover.hidden = true; return; }
    paint(hover, rectOf(element.getBoundingClientRect())); label.textContent = element.localName + (element.id ? '#' + element.id : '');
  }
  function move(event) {
    if (!enabled || suspended) return;
    pointer = {x:event.clientX,y:event.clientY};
    if (!frame) frame = requestAnimationFrame(drawHover);
  }
  function emit(selection) {
    add.hidden = true;
    const selections = picked.map(function (entry) { return entry.target; });
    const additional = picked;
    picked = [];
    const value = {...selection.target, selectionSerial:++serial, ...(selections.length ? {additionalSelections:selections} : {})};
    current = {...selection,target:value,additional:additional}; pending.set(serial,current);
    if (pending.size > 8) pending.delete(pending.keys().next().value);
    HappenAnnotation.postMessage(JSON.stringify({type:'selection',document:documentId,serial:serial,target:value}));
  }
  function down(event) {
    if (!enabled || suspended || event.button !== 0 || event.composedPath().includes(host)) return;
    event.preventDefault(); event.stopImmediatePropagation();
    const element = hit(event.clientX,event.clientY);
    dragging = element ? {x:event.clientX,y:event.clientY,element:element,add:event.shiftKey} : null;
  }
  function up(event) {
    if (!enabled || suspended || event.button !== 0 || event.composedPath().includes(host)) return;
    event.preventDefault(); event.stopImmediatePropagation();
    const start = dragging; dragging = null;
    if (!start) return;
    const region = Math.hypot(event.clientX-start.x,event.clientY-start.y)>6;
    const rect = region ? {x:Math.min(start.x,event.clientX),y:Math.min(start.y,event.clientY),width:Math.abs(start.x-event.clientX),height:Math.abs(start.y-event.clientY)} : rectOf(start.element.getBoundingClientRect());
    const selection = {element:start.element,target:target(start.element,region?'region':'element',rect)};
    if (start.add || event.shiftKey) { if (picked.length < 20) picked.push(selection); render(); return; }
    emit(selection);
  }
  function blockClick(event) {
    if (enabled && !suspended && !event.composedPath().includes(host)) { event.preventDefault(); event.stopImmediatePropagation(); }
  }
  function textSelection() {
    if (enabled || suspended) return;
    setTimeout(function () {
      const selection = getSelection();
      if (!selection || selection.isCollapsed || !text(selection.toString())) { add.hidden = true; return; }
      const anchor = selection.anchorNode, element = anchor && (anchor.nodeType === 1 ? anchor : anchor.parentElement);
      if (!element || element === host || element.closest('input[type=password]')) return;
      const range = selection.getRangeAt(0), rect = range.getBoundingClientRect();
      current = {element:element,target:target(element,'text',rectOf(rect),selection.toString().slice(0,8000))};
      add.style.left = Math.max(8,Math.min(innerWidth-110,rect.left))+'px';
      add.style.top = Math.max(8,rect.top-36)+'px'; add.hidden = false;
    },0);
  }
  add.addEventListener('mousedown',function (event) { event.preventDefault(); event.stopPropagation(); });
  add.addEventListener('click',function (event) { event.preventDefault(); event.stopPropagation(); if (current) emit(current); });
  function keyboard(event) {
    if (event.code === 'Space' && enabled && !event.altKey && !event.ctrlKey && !event.metaKey && !event.shiftKey) {
      suspended = event.type === 'keydown'; dragging = null; hover.hidden = true;
      event.preventDefault(); return;
    }
    if (event.type === 'keydown' && event.key === 'Escape' && (enabled || picked.length || !add.hidden)) {
      picked = []; current = null; add.hidden = true; dragging = null; hover.hidden = true;
      setMode(false); HappenAnnotation.postMessage(JSON.stringify({type:'escape',document:documentId})); render();
    }
  }
  function render() {
    root.querySelectorAll('.saved').forEach(function (node) { node.remove(); });
    for (const selection of [...saved,...picked]) {
      let rect = selection.target.rect;
      if (selection.element && selection.target.kind === 'element' && selection.element.isConnected) rect = rectOf(selection.element.getBoundingClientRect());
      const box = document.createElement('div'); box.className = 'box saved'; paint(box,rect);
      if (selection.number) { const marker = document.createElement('span'); marker.className = 'marker'; marker.textContent = selection.number; box.append(marker); }
      root.append(box);
    }
  }
  function setMode(value) { enabled = value; suspended = false; dragging = null; picked = []; add.hidden = true; hover.hidden = true; render(); }
  function commit(id, number, selectionSerial) {
    const selection = pending.get(selectionSerial);
    if (!selection) return;
    pending.delete(selectionSerial); saved.push({...selection,id:id,number:number});
    for (const entry of selection.additional || []) saved.push({...entry,id:id,number:number});
    if (current === selection) current = null;
    hover.hidden = true; add.hidden = true; render();
  }
  function reconcile(ids) {
    saved = saved.filter(function (entry) { return ids.includes(entry.id); })
      .map(function (entry) { return {...entry,number:ids.indexOf(entry.id)+1}; }); render();
  }
  function refresh() { render(); if (enabled && pointer && !frame) frame = requestAnimationFrame(drawHover); add.hidden = true; }
  addEventListener('pointermove',move,true); addEventListener('pointerdown',down,true); addEventListener('pointerup',up,true);
  addEventListener('click',blockClick,true); addEventListener('mouseup',textSelection,true);
  addEventListener('keydown',keyboard,true); addEventListener('keyup',keyboard,true);
  addEventListener('scroll',refresh,true); addEventListener('resize',refresh);
  addEventListener('blur',function () { suspended = false; dragging = null; hover.hidden = true; });
  return {setMode:setMode,commit:commit,reconcile:reconcile};
})();
''';
