// Loaded only into the app's ephemeral WKWebView. Google's renderer owns tiles and attribution.
window.earth3D = (() => {
  let map = null, library = null, markerLibrary = null, wanted = false, generation = 0, failed = false;
  let state = null, layers = null, camera = '', geometry = '', layerSignature = '';
  let shapes = [], layerShapes = [], cameraTimer = null, loadTimer = null;
  const send = (type, data = {}) => window.webkit.messageHandlers.earth.postMessage({type, ...data});
  const host = () => document.getElementById('map3d');
  const notice = text => { document.getElementById('three-notice').textContent = text; };
  function report(active, message = '', error = false) { send('threeD', {active, message, error}); }
  function removeMap() {
    clearTimeout(cameraTimer); clearTimeout(loadTimer);
    map?.remove(); map = null; shapes = []; layerShapes = []; camera = ''; geometry = ''; layerSignature = '';
    document.getElementById('map').style.visibility = '';  host().style.display = 'none';
    document.getElementById('layer-credit').style.bottom = '28px';
  }
  function unavailable() {
    ++generation; failed = true; removeMap();
    const message = 'Google photorealistic 3D could not load. Check Maps JavaScript API, billing, quotas, WebGL support, and regional coverage. Showing the regular Google map; switch 3D Buildings off and on to retry.';
    notice(message); report(false, message, true); window.earthRestore2D?.();
  }
  function publishCamera() {
    clearTimeout(cameraTimer);
    const current = map, request = state?.camera;
    cameraTimer = setTimeout(() => {
      if (!current || map !== current || !wanted || state.camera !== request) return;
      const p = map.center;
      if (p && Number.isFinite(p.lat) && Number.isFinite(p.lng) && Number.isFinite(map.range)) {
        send('camera3D', {lat:p.lat, lng:p.lng, altitude:p.altitude || 0, distance:map.range,
          heading:map.heading || 0, pitch:map.tilt || 0, request});
      }
    }, 60);
  }
  function applyCamera() {
    if (!map || camera === state.camera) return;
    camera = state.camera;
    // Preserve the terrain target altitude while orbiting/zooming. Swift supplies a new
    // ground estimate when flying to a different center (the map target is above MSL).
    const p = map.center;
    const sameTarget = p && Math.abs(p.lat - state.lat) < 1e-7 && Math.abs(p.lng - state.lng) < 1e-7;
    map.center = {lat:state.lat, lng:state.lng, altitude:sameTarget ? p.altitude || 0 : Math.max(0, state.groundAltitude || 0)};
    map.range = Math.max(100, Math.min(45000000, state.distance));
    map.heading = state.heading; map.tilt = state.pitch;
  }
  function line(path, color, polygon = false, interactive = false) {
    const Type = polygon ? (interactive ? library.Polygon3DInteractiveElement : library.Polygon3DElement)
      : (interactive ? library.Polyline3DInteractiveElement : library.Polyline3DElement);
    const element = new Type({altitudeMode:'CLAMP_TO_GROUND', geodesic:true, strokeColor:color,
      strokeWidth:polygon ? 3 : 2, ...(polygon ? {fillColor:color + '38'} : {})});
    element.path = path; map.append(element); return element;
  }
  function marker(position, title, action, pinImage) {
    const element = new library.Marker3DInteractiveElement({position, altitudeMode:'CLAMP_TO_GROUND', title});
    if (pinImage) {
      // Interactive 3D markers accept PinElement children, rather than raw images.
      const pin = new markerLibrary.PinElement({background:'transparent', borderColor:'transparent',
        glyphSrc:new URL(pinImage), scale:1.5});
      element.append(pin);
      element.drawsWhenOccluded = true; element.sizePreserved = true; element.zIndex = 1000;
    }
    if (action) element.addEventListener('gmp-click', event => { event.stopPropagation(); action(); });
    map.append(element); return element;
  }
  function drawGeometry() {
    const signature = JSON.stringify([state.features, state.vertices, state.tool]);
    if (signature === geometry) return;
    geometry = signature; shapes.forEach(x => x.remove()); shapes = [];
    for (const f of state.features) {
      const path = f.points.map(p => ({lat:p.latitude, lng:p.longitude}));
      if (!path.length) continue;
      let element;
      if (f.kind === 'point') element = marker(path[0], f.name, () => {
        if (state.drawing) send('pick', path[0]); else send('select', {id:f.id});
      }, f.pinImage);
      else {
        element = line(path, f.color, f.kind === 'polygon', true);
        element.addEventListener('gmp-click', event => {
          event.stopPropagation();
          if (state.drawing && event.position) send('pick', {lat:event.position.lat, lng:event.position.lng});
          else send('select', {id:f.id});
        });
      }
      shapes.push(element);
    }
    const path = state.vertices.map(p => ({lat:p.latitude, lng:p.longitude}));
    if (path.length >= 2) shapes.push(line(path, '#ffcc33', state.tool === 'polygon' && path.length >= 3));
    for (const p of path) shapes.push(marker(p, 'Drawing point', () => send('pick', p)));
  }
  function drawLayers() {
    if (!layers) return;
    const signature = JSON.stringify(layers);
    if (signature === layerSignature) return;
    layerSignature = signature; layerShapes.forEach(x => x.remove()); layerShapes = [];
    const e = layers.enabled;
    if (e.borders) {
      for (const country of layers.countries || []) for (const path of country.outlines) layerShapes.push(line(path, '#f5d45b'));
      for (const path of layers.regions || []) layerShapes.push(line(path, '#cccccc'));
    }
    if (e.parks) for (const path of layers.parks || []) layerShapes.push(line(path, '#59f580'));
    if (e.water) for (const path of layers.water || []) layerShapes.push(line(path, '#4dccff'));
    for (const item of layers.items || []) layerShapes.push(marker({lat:item.lat,lng:item.lng}, item.title, () => send('layerSelect', {id:item.id})));
  }
  function render() {
    if (!map) return;
    // Google provides labels/roads together in HYBRID; SATELLITE is imagery only.
    map.mode = state.style === 'satellite' && !layers?.enabled.labels && !layers?.enabled.roads ? 'SATELLITE' : 'HYBRID';
    applyCamera(); drawGeometry(); drawLayers();
  }
  async function start(epoch) {
    notice('Loading Google photorealistic buildings and terrain…'); report(false, 'Loading Google photorealistic 3D…');
    loadTimer = setTimeout(() => { if (epoch === generation && wanted) unavailable(); }, 45000);
    try {
      [library, markerLibrary] = await Promise.all([google.maps.importLibrary('maps3d'), google.maps.importLibrary('marker')]);
      if (epoch !== generation || !wanted) return;
      map = new library.Map3DElement({center:{lat:state.lat,lng:state.lng,altitude:Math.max(0,state.groundAltitude || 0)},
        range:state.distance, heading:state.heading, tilt:state.pitch, mode:'HYBRID', defaultUIHidden:true,
        minAltitude:10, maxTilt:80, gestureHandling:'GREEDY', description:'Google photorealistic 3D buildings and terrain'});
      const current = map;
      map.addEventListener('gmp-error', () => { if (map === current) unavailable(); });
      map.addEventListener('gmp-steadychange', event => {
        if (map !== current || !event.isSteady) return;
        clearTimeout(loadTimer); notice(''); report(true, 'Google photorealistic 3D · Coverage varies by location'); publishCamera();
      });
      for (const event of ['gmp-centerchange','gmp-rangechange','gmp-headingchange','gmp-tiltchange']) map.addEventListener(event, publishCamera);
      map.addEventListener('gmp-click', event => {
        const p = event.position;
        if (p && Number.isFinite(p.lat) && Number.isFinite(p.lng)) send('pick', {lat:p.lat,lng:p.lng});
      });
      host().append(map); host().style.display = 'block'; document.getElementById('layer-credit').style.bottom = '86px'; document.getElementById('map').style.visibility = 'hidden';
      render();
    } catch { if (epoch === generation && wanted) unavailable(); }
  }
  return {
    get active() { return !!map; },
    update(s, l) {
      state = s; layers = l;
      const next = !!s.buildings && !s.archive && !s.street && !s.images;
      if (next !== wanted) {
        wanted = next; ++generation; failed = false; removeMap(); notice('');
        if (wanted) start(generation);
        else { window.earthRestore2D?.(); report(false, s.buildings ? 'Photorealistic 3D paused for image overlays, historical imagery or Street View' : ''); }
      }
      if (wanted && !failed) render();
    },
    stop() { if (map) map.stopCameraAnimation().catch(() => {}); },
    dispose() { wanted = false; ++generation; removeMap(); }
  };
})();
