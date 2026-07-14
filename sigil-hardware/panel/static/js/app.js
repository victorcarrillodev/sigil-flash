/* ============================================================
   app.js — Sigil Panel client logic
   Handles: BT scan SSE, BT actions, WiFi scan, WiFi connect modal,
            Music status polling, Diagnostics
   No external dependencies — runs fully offline
   ============================================================ */

'use strict';

// ── Utilities ──────────────────────────────────────────────────────────────

function escapeHtml(str) {
  if (!str) return '';
  return str.replace(/[&<>"]/g, function(m) {
    return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[m];
  });
}

/** Renders an SVG WiFi-signal icon based on signal percentage. */
function signalIcon(pct) {
  const n   = parseInt(pct) || 0;
  const on  = 'var(--accent)';
  const off = 'rgba(255,255,255,0.15)';
  const c1  = (n >= 25) ? on : off;
  const c2  = (n >= 50) ? on : off;
  const c3  = (n >= 75) ? on : off;
  return (
    '<svg width="18" height="18" viewBox="0 0 24 24" style="vertical-align:middle;margin-right:4px">' +
    '<circle cx="12" cy="20" r="2" fill="' + on + '"/>' +
    '<path d="M8.46 16.46A5 5 0 0 1 15.54 16.46" fill="none" stroke="' + c1 + '" stroke-width="2" stroke-linecap="round"/>' +
    '<path d="M4.93 12.93A10 10 0 0 1 19.07 12.93" fill="none" stroke="' + c2 + '" stroke-width="2" stroke-linecap="round"/>' +
    '<path d="M1.39 9.39A15 15 0 0 1 22.61 9.39" fill="none" stroke="' + c3 + '" stroke-width="2" stroke-linecap="round"/>' +
    '</svg>'
  );
}

function setResult(id, msg, isError) {
  var el = document.getElementById(id);
  if (!el) return;
  el.textContent = msg;
  el.className   = 'result-msg' + (isError ? ' error' : '');
}


// ── Bluetooth: build row ───────────────────────────────────────────────────

/**
 * Construye una fila de dispositivo BT.
 * IMPORTANTE: usa d.connected (estado real de BlueZ), NO d.preferred,
 * para determinar si mostrar "Conectado Ahora".
 */
function makeBtRow(d) {
  // d.connected = está físicamente conectado en BlueZ AHORA
  // d.preferred = está guardado como preferido en preferred_bt.txt
  var isConnected = !!d.connected;
  var icon        = isConnected ? '✅' : '🔊';
  var iconClass   = isConnected ? 'active' : 'saved';
  var statusHtml  = isConnected
    ? '<div class="device-status active">Conectado Ahora</div>'
    : '<div class="device-status">Guardado</div>';

  var actionBtn = '';
  if (d.known) {
    actionBtn = isConnected
      ? '<button class="btn-disconnect disconnect-bt-btn" data-mac="' + escapeHtml(d.mac) + '">Desconectar</button>'
      : '<button class="btn-outline connect-bt-btn" data-mac="' + escapeHtml(d.mac) + '">Conectar</button>';
  } else {
    actionBtn = '<button class="btn-outline pair-bt-btn" data-mac="' + escapeHtml(d.mac) + '" data-name="' + escapeHtml(d.name) + '">Emparejar</button>';
  }
  var removeBtn = d.known
    ? '<button class="btn-danger remove-bt-btn" data-mac="' + escapeHtml(d.mac) + '" title="Eliminar">🗑</button>'
    : '';

  var div = document.createElement('div');
  div.className = 'device-row';
  div.id        = 'bt-row-' + d.mac.replace(/:/g, '');
  div.innerHTML =
    '<div class="device-info">' +
      '<div class="device-icon ' + iconClass + '">' + icon + '</div>' +
      '<div>' +
        '<div class="device-name">' + escapeHtml(d.name) + '</div>' +
        statusHtml +
      '</div>' +
    '</div>' +
    '<div class="device-actions">' + actionBtn + removeBtn + '</div>';
  return div;
}


// ── Bluetooth: scan (SSE) ──────────────────────────────────────────────────

var _btScanCount = 0;

document.getElementById('scanBtBtn').addEventListener('click', function() {
  var btn       = this;
  var container = document.getElementById('bt-table');
  var statusEl  = document.getElementById('bt-status');

  btn.disabled = true;
  _btScanCount = 0;
  container.innerHTML = '<div class="no-devices">Buscando dispositivos… <span class="spinner"></span></div>';
  statusEl.textContent = '(18 seg)';

  var es = new EventSource('/scan/stream');
  container.innerHTML = '';

  es.onmessage = function(evt) {
    var data;
    try { data = JSON.parse(evt.data); } catch(e) { return; }

    if (data.done) {
      es.close();
      btn.disabled     = false;
      statusEl.textContent = '';
      if (_btScanCount === 0 && container.children.length === 0) {
        container.innerHTML = '<div class="no-devices">No se encontraron altavoces.<br>Asegúrate de que estén en modo emparejamiento.</div>';
      }
      return;
    }
    if (data.error) { es.close(); btn.disabled = false; return; }
    if (!data.name || data.name.trim() === '' || data.name === data.mac) return;

    var existing = document.getElementById('bt-row-' + data.mac.replace(/:/g, ''));
    if (data.update && existing) {
      var nameEl = existing.querySelector('.device-name');
      if (nameEl) nameEl.textContent = data.name;
    } else if (!existing) {
      _btScanCount++;
      container.appendChild(makeBtRow(data));
    }
  };

  es.onerror = function() {
    es.close();
    btn.disabled     = false;
    statusEl.textContent = '';
  };
});


// ── Bluetooth: action delegation ───────────────────────────────────────────

document.getElementById('bt-table').addEventListener('click', function(e) {
  var target = e.target;

  if (target.classList.contains('connect-bt-btn')) {
    var mac = target.getAttribute('data-mac');
    target.disabled = true;
    setResult('bt-result', 'Conectando…');
    fetch('/connect/' + encodeURIComponent(mac))
      .then(function(r) { return r.json(); })
      .then(function(d) {
        setResult('bt-result', d.message, !d.success);
        if (d.success) setTimeout(function() { location.reload(); }, 1500);
        else target.disabled = false;
      });

  } else if (target.classList.contains('disconnect-bt-btn')) {
    target.disabled = true;
    setResult('bt-result', 'Desconectando…');
    fetch('/disconnect_active')
      .then(function(r) { return r.json(); })
      .then(function(d) {
        setResult('bt-result', d.message, !d.success);
        if (d.success) setTimeout(function() { location.reload(); }, 1500);
        else target.disabled = false;
      });

  } else if (target.classList.contains('remove-bt-btn')) {
    if (!confirm('¿Seguro que deseas eliminar este altavoz?')) return;
    var mac = target.getAttribute('data-mac');
    target.disabled = true;
    fetch('/remove/' + encodeURIComponent(mac))
      .then(function(r) { return r.json(); })
      .then(function(d) {
        if (d.success) setTimeout(function() { location.reload(); }, 800);
        else target.disabled = false;
      });

  } else if (target.classList.contains('pair-bt-btn')) {
    var mac  = target.getAttribute('data-mac');
    var name = target.getAttribute('data-name');
    target.disabled = true;
    setResult('bt-result', 'Emparejando…');
    fetch('/pair', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: 'mac=' + encodeURIComponent(mac) + '&name=' + encodeURIComponent(name)
    })
    .then(function(r) { return r.json(); })
    .then(function(d) {
      setResult('bt-result', d.message, !d.success);
      if (d.success) setTimeout(function() { location.reload(); }, 1500);
      else target.disabled = false;
    });
  }
});


// ── Música: estado y control ───────────────────────────────────────────────

var _musicDisc      = document.getElementById('music-disc');
var _musicTrack     = document.getElementById('music-track');
var _speakerDot     = document.getElementById('speaker-dot');
var _speakerLabel   = document.getElementById('speaker-label');
var _musicNextBtn   = document.getElementById('music-next-btn');
var _lastTrackName  = '';

function updateMusicStatus() {
  fetch('/music/status')
    .then(function(r) { return r.json(); })
    .then(function(data) {
      // Actualizar pista
      var trackName = data.is_playing ? data.track_name : 'Sin reproducción';
      if (trackName !== _lastTrackName) {
        _lastTrackName = trackName;
        _musicTrack.textContent = trackName;

        // Animación de la rueda: rotar si está reproduciendo
        if (data.is_playing) {
          _musicDisc.style.animation = 'disc-spin 4s linear infinite';
        } else {
          _musicDisc.style.animation = '';
        }
      }

      // Estado de la bocina
      if (data.speaker_connected) {
        _speakerDot.className  = 'speaker-dot connected';
        _speakerLabel.textContent = 'Bocina conectada' + (data.speaker_mac ? ' — ' + data.speaker_mac : '');
        _musicNextBtn.disabled = false;
      } else {
        _speakerDot.className  = 'speaker-dot';
        _speakerLabel.textContent = 'Bocina no conectada';
        _musicNextBtn.disabled = true;
      }
    })
    .catch(function() { /* ignorar silenciosamente */ });
}

// Botón siguiente pista
if (_musicNextBtn) {
  _musicNextBtn.addEventListener('click', function() {
    this.disabled = true;
    var self = this;
    fetch('/music/next', { method: 'POST' })
      .then(function(r) { return r.json(); })
      .then(function(d) {
        // Actualizar status después de 2s para que mpg123 avance
        setTimeout(function() {
          updateMusicStatus();
          self.disabled = false;
        }, 2000);
      })
      .catch(function() { self.disabled = false; });
  });
}

// Polling inicial y cada 10s
updateMusicStatus();
setInterval(updateMusicStatus, 10000);


// ── WiFi: scan ─────────────────────────────────────────────────────────────

document.getElementById('scanWifiBtn').addEventListener('click', function() {
  var btn     = this;
  var scanEl  = document.getElementById('wifi-scan-status');
  var tableEl = document.getElementById('wifi-table');

  btn.disabled        = true;
  scanEl.textContent  = 'Escaneando… ';
  scanEl.innerHTML   += '<span class="spinner"></span>';

  fetch('/wifi/scan')
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (data.networks.length === 0) {
        tableEl.innerHTML = '<div class="no-devices">No se encontraron redes.</div>';
      } else {
        var html = '';
        data.networks.forEach(function(n) {
          html +=
            '<div class="wifi-row">' +
              '<div class="wifi-info"><div>' +
                '<div class="wifi-name">' + escapeHtml(n.ssid) + '</div>' +
                '<div class="wifi-meta">' +
                  '<span class="wifi-signal">' + signalIcon(n.signal) + n.signal + '%</span>' +
                  (n.security ? ' <span title="Red protegida">🔒</span>' : '') +
                '</div>' +
              '</div></div>' +
              '<button class="btn-outline connect-wifi-btn"' +
                ' data-ssid="'     + escapeHtml(n.ssid)     + '"' +
                ' data-security="' + escapeHtml(n.security) + '"' +
                ' data-saved="'    + (n.saved ? '1' : '0')  + '"' +
              '>Conectar</button>' +
            '</div>';
        });
        tableEl.innerHTML = html;
      }
      scanEl.textContent = '';
      assignWifiEvents();
    })
    .catch(function() { scanEl.textContent = 'Error al escanear'; })
    .finally(function() { btn.disabled = false; });
});


// ── WiFi: connect flow ─────────────────────────────────────────────────────

var _selectedSsid = '';

function assignWifiEvents() {
  document.querySelectorAll('.connect-wifi-btn').forEach(function(btn) {
    btn.addEventListener('click', function() {
      _selectedSsid = this.getAttribute('data-ssid');
      var security  = this.getAttribute('data-security');
      var saved     = this.getAttribute('data-saved') === '1';

      if (security && security !== '' && !saved) {
        document.getElementById('modal-ssid').textContent = 'Conectar a: ' + _selectedSsid;
        document.getElementById('wifi-password').value   = '';
        document.getElementById('wifi-modal').style.display = 'block';
        // Autofocus en mobile
        setTimeout(function() { document.getElementById('wifi-password').focus(); }, 100);
      } else {
        connectWifi(_selectedSsid, '');
      }
    });
  });
}
assignWifiEvents();

function closeModal() {
  document.getElementById('wifi-modal').style.display = 'none';
}

function confirmWifiConnect() {
  var password = document.getElementById('wifi-password').value;
  closeModal();
  connectWifi(_selectedSsid, password);
}

// Cerrar modal al presionar fuera de la caja
document.getElementById('wifi-modal').addEventListener('click', function(e) {
  if (e.target === this) closeModal();
});

// Confirmar con Enter en el campo de contraseña
document.getElementById('wifi-password').addEventListener('keydown', function(e) {
  if (e.key === 'Enter') confirmWifiConnect();
});

function connectWifi(ssid, password) {
  setResult('wifi-result', 'Conectando a ' + escapeHtml(ssid) + '… (puede tardar 30-40 s)');

  fetch('/wifi/connect', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ ssid: ssid, password: password })
  })
  .then(function(r) { return r.json(); })
  .then(function(startData) {
    if (!startData.success) {
      setResult('wifi-result', startData.message, true);
      return;
    }
    // Polling cada 3 s hasta que termine
    var poll = setInterval(function() {
      fetch('/wifi/status')
        .then(function(r) { return r.json(); })
        .then(function(status) {
          setResult('wifi-result', status.message, !status.success && status.success !== null);
          if (!status.running) {
            clearInterval(poll);
            if (status.success) {
              var el = document.getElementById('current-wifi-div');
              if (el) {
                el.className = 'status-bar connected';
                el.innerHTML = '✅ Conectado a <strong>&nbsp;' + escapeHtml(ssid) + '</strong>';
              }
            }
            setTimeout(function() { setResult('wifi-result', ''); }, 8000);
          }
        })
        .catch(function() { clearInterval(poll); });
    }, 3000);
  })
  .catch(function(err) {
    setResult('wifi-result', 'Error: ' + err, true);
  });
}

// Exponer funciones al HTML inline onclick
window.confirmWifiConnect = confirmWifiConnect;
window.closeModal         = closeModal;

// ── System Status (Diagnostics) ───────────────────────────────────────────

function formatUptime(seconds) {
  var d = Math.floor(seconds / 86400);
  var h = Math.floor((seconds % 86400) / 3600);
  var m = Math.floor((seconds % 3600) / 60);
  var parts = [];
  if (d > 0) parts.push(d + "d");
  if (h > 0) parts.push(h + "h");
  parts.push(m + "m");
  return parts.join(" ");
}

function updateSystemStatus() {
  fetch("/api/system-status")
    .then(function(r) { return r.json(); })
    .then(function(data) {
      // Uptime
      var uptimeEl = document.getElementById("sys-uptime");
      if (uptimeEl) uptimeEl.textContent = formatUptime(data.uptime_seconds);

      // Connection
      var connEl = document.getElementById("sys-connection");
      if (connEl) {
        var connectedBar = document.querySelector(".status-bar.connected");
        if (connectedBar) {
          var ssidEl = connectedBar.querySelector("strong");
          connEl.textContent = ssidEl ? ssidEl.textContent.trim() : "WiFi conectado";
          connEl.className = "sys-value healthy";
        } else {
          connEl.textContent = "Sin conexión";
          connEl.className = "sys-value warning";
        }
      }
    })
    .catch(function() { /* ignore */ });
}

// Diagnostics toggle
(function() {
  var toggle = document.getElementById('diag-toggle');
  var diag   = document.getElementById('diag-section');
  if (toggle && diag) {
    toggle.addEventListener('click', function(e) {
      e.preventDefault();
      var isOpen = diag.open;
      diag.open = !isOpen;
      this.classList.toggle('open', !isOpen);
    });
  }
})();

// Initial update and poll every 15s
setTimeout(updateSystemStatus, 500);
setInterval(updateSystemStatus, 15000);
