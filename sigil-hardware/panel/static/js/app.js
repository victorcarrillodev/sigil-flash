/* ============================================================
   app.js — Sigil Panel client logic
   Handles: BT scan SSE, BT actions, WiFi scan, WiFi connect modal,
            Music status polling, Diagnostics, System Status

   Audit fixes implemented:
   - CSRF token cache with one bounded refresh on rejection
   - Distinct error messages for 401, 403, 409, 422, 500
   - Scan stopped before Bluetooth mutations
   - Proper button state recovery after errors
   - No generic error translation to "device not in pairing mode"
   - Cache busting via versioned script URL
   ============================================================ */

'use strict';

// ── Configuration ─────────────────────────────────────────────────────────────

const CONFIG = {
  // Timing
  WIFI_POLL_INTERVAL: 3000,      // ms between WiFi status polls
  MUSIC_POLL_INTERVAL: 10000,    // ms between music status polls
  SYSTEM_POLL_INTERVAL: 15000,   // ms between system status polls
  BT_SCAN_DURATION: 18000,        // ms for Bluetooth scan

  // Timeouts
  CSRF_FETCH_TIMEOUT: 5000,      // ms to fetch CSRF token
  ACTION_TIMEOUT: 105000,        // aligned with the 100-second backend bound

  // Messages
  MSG_BLUETOOTH_SCAN_BUSY: 'Bluetooth ocupado; reintenta en breve',
  MSG_WIFI_SCAN_BUSY: 'Radio WiFi ocupado; reintenta en breve',
  MSG_CONNECTION_IN_PROGRESS: 'Ya hay una conexión en progreso',
  MSG_SESSION_EXPIRED: 'Sesión expirada. Recarga la página.',
  MSG_CSRF_FAILED: 'Error de seguridad. Recarga la página.',
  MSG_SERVER_ERROR: 'Error del servidor. Reintenta más tarde.',
  MSG_NETWORK_ERROR: 'Error de red. Verifica tu conexión.',
};

// ── State ─────────────────────────────────────────────────────────────────────

const state = {
  // Bluetooth scan
  btScanStream: null,
  btScanActive: false,

  // WiFi
  wifiPollInterval: null,
  wifiConnecting: false,

  // Music
  lastTrackName: '',
  lastSpeakerConnected: null,
};

// ── Utilities ─────────────────────────────────────────────────────────────────

function escapeHtml(str) {
  if (!str || typeof str !== 'string') return '';
  return str.replace(/[&<>"']/g, m => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;',
    '"': '&quot;', "'": '&#39;'
  })[m]);
}

/** Safe JSON parse */
function safeJsonParse(str) {
  try {
    return [null, JSON.parse(str)];
  } catch (e) {
    return [e, null];
  }
}

/** HTTP status code to error message */
function getHttpErrorMessage(status, responseBody) {
  // Try to extract backend message first
  if (responseBody && typeof responseBody === 'object' && responseBody.message) {
    return responseBody.message;
  }

  switch (status) {
    case 0:
      return CONFIG.MSG_NETWORK_ERROR;
    case 401:
      return CONFIG.MSG_SESSION_EXPIRED;
    case 403:
      return CONFIG.MSG_CSRF_FAILED;
    case 409:
      return 'Conflicto de estado. Intenta recargar.';
    case 422:
      return 'Datos inválidos. Verifica la información.';
    case 429:
      return 'Demasiadas solicitudes. Espera un momento.';
    case 500:
    case 502:
    case 503:
      return CONFIG.MSG_SERVER_ERROR;
    default:
      return `Error (${status}). Reintenta.`;
  }
}

/** Render WiFi signal icon based on percentage */
function signalIcon(pct) {
  const n = Math.round(parseFloat(pct) || 0);
  const on = 'var(--accent)';
  const off = 'rgba(255,255,255,0.15)';
  const c1 = n >= 25 ? on : off;
  const c2 = n >= 50 ? on : off;
  const c3 = n >= 75 ? on : off;

  return (
    `<svg width="18" height="18" viewBox="0 0 24 24" style="vertical-align:middle;margin-right:4px">
      <circle cx="12" cy="20" r="2" fill="${on}"/>
      <path d="M8.46 16.46A5 5 0 0 1 15.54 16.46" fill="none" stroke="${c1}" stroke-width="2" stroke-linecap="round"/>
      <path d="M4.93 12.93A10 10 0 0 1 19.07 12.93" fill="none" stroke="${c2}" stroke-width="2" stroke-linecap="round"/>
      <path d="M1.39 9.39A15 15 0 0 1 22.61 9.39" fill="none" stroke="${c3}" stroke-width="2" stroke-linecap="round"/>
    </svg>`
  );
}

// ── CSRF Token Management ─────────────────────────────────────────────────────

let _csrfPromise = null; // Deduplicate concurrent CSRF requests

function fetchWithTimeout(url, options = {}, timeoutMs = CONFIG.ACTION_TIMEOUT) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  return fetch(url, { ...options, signal: controller.signal })
    .finally(() => clearTimeout(timeout));
}

/**
 * Fetches a fresh CSRF token from the server.
 * Deduplicates concurrent requests to avoid race conditions.
 */
function fetchCsrfToken() {
  if (_csrfPromise) return _csrfPromise;

  _csrfPromise = fetchWithTimeout('/api/csrf-token', {
    method: 'GET',
    credentials: 'same-origin',
    cache: 'no-store',
  }, CONFIG.CSRF_FETCH_TIMEOUT)
  .then(response => {
    if (!response.ok) {
      throw new Error(`csrf-http-${response.status}`);
    }
    return response.json();
  })
  .then(data => {
    if (!data || !data.csrf_token) {
      throw new Error('csrf-token-unavailable');
    }
    // Update meta tag
    const meta = document.querySelector('meta[name="sigil-csrf-token"]');
    if (meta) {
      meta.setAttribute('content', data.csrf_token);
    }
    return data.csrf_token;
  })
  .catch(err => {
    _csrfPromise = null;
    throw err;
  });

  return _csrfPromise;
}

/**
 * Wraps fetch with automatic CSRF token injection for mutations.
 * Use this for POST/PUT/DELETE requests that need CSRF protection.
 */
function csrfFetch(url, options = {}, retry = true) {
  return fetchCsrfToken().then(token => {
      const { timeoutMs = CONFIG.ACTION_TIMEOUT, ...requestOptions } = options;
      const headers = { ...(requestOptions.headers || {}) };
      headers['X-Sigil-CSRF'] = token;
      if (!headers['Content-Type'] && requestOptions.body && typeof requestOptions.body === 'string' && !requestOptions.body.startsWith('{')) {
        headers['Content-Type'] = 'application/x-www-form-urlencoded';
      } else {
        headers['Content-Type'] = headers['Content-Type'] || 'application/json';
      }

      return fetchWithTimeout(url, {
        ...requestOptions,
        method: requestOptions.method || 'GET',
        headers,
        credentials: 'same-origin',
        cache: 'no-store',
      }, timeoutMs);
    })
    .then(response => {
      if (response.status === 403 && retry) {
        _csrfPromise = null;
        return csrfFetch(url, options, false);
      }
      return response;
    });
}

// ── UI Helpers ────────────────────────────────────────────────────────────────

function setResult(id, msg, type = 'info') {
  const el = document.getElementById(id);
  if (!el) return;

  el.textContent = msg;
  el.className = 'result-msg';

  switch (type) {
    case 'error':
      el.classList.add('error');
      break;
    case 'success':
      el.classList.add('success');
      break;
    case 'loading':
      el.classList.add('loading');
      break;
  }
}

function showToast(msg, type = 'info', duration = 4000) {
  // Simple toast notification
  let toast = document.getElementById('toast-notification');
  if (!toast) {
    toast = document.createElement('div');
    toast.id = 'toast-notification';
    toast.style.cssText = `
      position: fixed;
      bottom: 80px;
      left: 50%;
      transform: translateX(-50%);
      padding: 12px 20px;
      border-radius: 8px;
      font-size: 14px;
      font-weight: 500;
      z-index: 1000;
      transition: opacity 0.3s, transform 0.3s;
      max-width: 90vw;
      text-align: center;
    `;
    document.body.appendChild(toast);
  }

  // Apply styles based on type
  const styles = {
    info: { bg: 'var(--accent)', color: '#fff' },
    error: { bg: 'var(--danger)', color: '#fff' },
    success: { bg: 'var(--success)', color: '#fff' },
    warning: { bg: 'var(--warning)', color: '#000' },
  };
  const s = styles[type] || styles.info;
  toast.style.background = s.bg;
  toast.style.color = s.color;

  toast.textContent = msg;
  toast.style.opacity = '1';
  toast.style.transform = 'translateX(-50%) translateY(0)';

  setTimeout(() => {
    toast.style.opacity = '0';
    toast.style.transform = 'translateX(-50%) translateY(10px)';
  }, duration);
}

function setButtonLoading(btn, loading) {
  if (!btn) return;
  btn.disabled = loading;
  if (loading) {
    btn.dataset.originalText = btn.textContent;
    btn.innerHTML = '<span class="spinner"></span>';
  } else {
    btn.textContent = btn.dataset.originalText || btn.textContent;
  }
}

// ── Bluetooth: Scan ───────────────────────────────────────────────────────────

/**
 * Stops any active Bluetooth scan before performing a mutation.
 */
function stopBluetoothScan() {
  if (state.btScanStream) {
    state.btScanStream.close();
    state.btScanStream = null;
  }
  state.btScanActive = false;

  const scanBtn = document.getElementById('scanBtBtn');
  const statusEl = document.getElementById('bt-status');
  if (scanBtn) scanBtn.disabled = false;
  if (statusEl) statusEl.textContent = '';
}

/** Creates a Bluetooth device row element */
function makeBtRow(d) {
  const isConnected = !!d.connected;
  const isPreferred = !!d.preferred;
  const icon = isConnected ? '✅' : '🔊';
  const iconClass = isConnected ? 'active' : 'saved';

  let actionBtn = '';
  if (d.known) {
    actionBtn = isConnected
      ? `<button class="btn-disconnect disconnect-bt-btn" data-mac="${escapeHtml(d.mac)}">Desconectar</button>`
      : `<button class="btn-outline connect-bt-btn" data-mac="${escapeHtml(d.mac)}">Conectar</button>`;
  } else {
    actionBtn = `<button class="btn-outline pair-bt-btn" data-mac="${escapeHtml(d.mac)}" data-name="${escapeHtml(d.name || '')}">Emparejar</button>`;
  }

  const removeBtn = d.known
    ? `<button class="btn-danger remove-bt-btn" data-mac="${escapeHtml(d.mac)}" data-tooltip="Eliminar">🗑</button>`
    : '';

  const div = document.createElement('div');
  div.className = 'device-row';
  div.id = 'bt-row-' + d.mac.replace(/:/g, '');
  div.innerHTML = `
    <div class="device-info">
      <div class="device-icon ${iconClass}">${icon}</div>
      <div>
        <div class="device-name">${escapeHtml(d.name)}</div>
        <div class="device-status ${isConnected ? 'active' : ''}">
          ${isConnected ? 'Conectado ahora' : (isPreferred ? 'Preferida · Guardada' : 'Guardada')}
        </div>
      </div>
    </div>
    <div class="device-actions">${actionBtn}${removeBtn}</div>
  `;
  return div;
}

function renderBluetoothDevices(devices) {
  const container = document.getElementById('bt-table');
  if (!container) return;
  container.innerHTML = '';
  (devices || []).forEach(device => container.appendChild(makeBtRow(device)));
  if (!container.children.length) {
    container.innerHTML = '<div class="no-devices">No hay altavoces guardados.</div>';
  }
}

function refreshBluetoothState() {
  return fetchWithTimeout('/bt/status', { credentials: 'same-origin', cache: 'no-store' }, 10000)
    .then(response => {
      if (!response.ok) throw new Error(`http-${response.status}`);
      return response.json();
    })
    .then(data => renderBluetoothDevices(data.devices || []));
}

function setBluetoothRowProgress(button, message) {
  const row = button && button.closest('.device-row');
  const status = row && row.querySelector('.device-status');
  if (status) {
    status.textContent = message;
    status.classList.add('active');
  }
}

/** Handle Bluetooth scan button click */
document.getElementById('scanBtBtn').addEventListener('click', function() {
  const btn = this;
  const container = document.getElementById('bt-table');
  const statusEl = document.getElementById('bt-status');

  // Stop any existing scan
  stopBluetoothScan();

  btn.disabled = true;
  container.innerHTML = '<div class="no-devices">Buscando dispositivos… <span class="spinner"></span></div>';
  statusEl.textContent = `(${CONFIG.BT_SCAN_DURATION / 1000}s)`;
  state.btScanActive = true;
  let receivedDevice = false;

  const es = new EventSource('/scan/stream');
  state.btScanStream = es;

  es.onmessage = function(evt) {
    const [err, data] = safeJsonParse(evt.data);
    if (err) return;

    if (data.done) {
      es.close();
      stopBluetoothScan();
      refreshBluetoothState().catch(() => {});
      if (!receivedDevice) container.innerHTML = '<div class="no-devices">No se encontraron altavoces.<br>Asegúrate de que estén en modo emparejamiento.</div>';
      return;
    }

    if (data.error) {
      es.close();
      stopBluetoothScan();
      setResult('bt-result', data.error, 'error');
      return;
    }

    // Skip invalid entries
    if (!data.name || data.name.trim() === '' || /^([0-9A-Fa-f]{2}[:\-]){5}[0-9A-Fa-f]{2}$/.test(data.name)) {
      return;
    }

    if (!receivedDevice) {
      container.innerHTML = '';
      receivedDevice = true;
    }
    const existing = document.getElementById('bt-row-' + data.mac.replace(/:/g, ''));
    if (existing) {
      existing.replaceWith(makeBtRow(data));
    } else {
      container.appendChild(makeBtRow(data));
    }
  };

  es.onerror = function() {
    es.close();
    stopBluetoothScan();
    setResult('bt-result', CONFIG.MSG_NETWORK_ERROR, 'error');
  };

  // Auto-stop scan after duration
  setTimeout(() => {
    if (state.btScanActive) {
      es.close();
      stopBluetoothScan();
    }
  }, CONFIG.BT_SCAN_DURATION);
});

// ── Bluetooth: Actions ────────────────────────────────────────────────────────

document.getElementById('bt-table').addEventListener('click', function(e) {
  const target = e.target;
  const mac = target.dataset.mac;

  // Connect
  if (target.classList.contains('connect-bt-btn')) {
    e.preventDefault();
    stopBluetoothScan();
    setButtonLoading(target, true);
    setBluetoothRowProgress(target, 'Emparejando y conectando A2DP…');
    setResult('bt-result', 'Emparejando y conectando…', 'loading');

    // A freshly flashed device has no BlueZ pairing state.  The pair endpoint
    // is intentionally idempotent for an already-paired speaker and completes
    // the subsequent trusted-connect-A2DP sequence in one operation.
    csrfFetch('/pair', {
      method: 'POST',
      body: 'mac=' + encodeURIComponent(mac),
    })
      .then(r => r.json())
      .then(d => {
        setResult('bt-result', d.message || 'Conectado', d.success ? 'success' : 'error');
        if (d.success) {
          showToast('Conectado exitosamente', 'success');
          refreshBluetoothState().catch(() => {});
        } else {
          setButtonLoading(target, false);
          refreshBluetoothState().catch(() => {});
        }
      })
      .catch(err => {
        setResult('bt-result', getHttpErrorMessage(0, null), 'error');
        setButtonLoading(target, false);
        refreshBluetoothState().catch(() => {});
      });

  // Disconnect
  } else if (target.classList.contains('disconnect-bt-btn')) {
    e.preventDefault();
    stopBluetoothScan();
    setButtonLoading(target, true);
    setBluetoothRowProgress(target, 'Desconectando…');
    setResult('bt-result', 'Desconectando…', 'loading');

    csrfFetch('/disconnect_active', { method: 'POST' })
      .then(r => r.json())
      .then(d => {
        setResult('bt-result', d.message || 'Desconectado', d.success ? 'success' : 'error');
        if (d.success) {
          showToast('Desconectado', 'success');
          refreshBluetoothState().catch(() => {});
        } else {
          setButtonLoading(target, false);
          refreshBluetoothState().catch(() => {});
        }
      })
      .catch(() => {
        setResult('bt-result', getHttpErrorMessage(0, null), 'error');
        setButtonLoading(target, false);
        refreshBluetoothState().catch(() => {});
      });

  // Remove
  } else if (target.classList.contains('remove-bt-btn')) {
    e.preventDefault();
    if (!confirm('¿Eliminar este altavoz?')) return;

    stopBluetoothScan();
    const row = target.closest('.device-row');
    if (row) row.style.opacity = '0.5';

    setBluetoothRowProgress(target, 'Eliminando de BlueZ…');
    csrfFetch('/remove/' + encodeURIComponent(mac), { method: 'POST' })
      .then(r => r.json())
      .then(d => {
        if (d.success) {
          showToast('Altavoz eliminado', 'success');
          refreshBluetoothState().catch(() => {});
        } else {
          if (row) row.style.opacity = '1';
          setResult('bt-result', d.message || 'Error al eliminar', 'error');
          refreshBluetoothState().catch(() => {});
        }
      })
      .catch(() => {
        if (row) row.style.opacity = '1';
        setResult('bt-result', getHttpErrorMessage(0, null), 'error');
        refreshBluetoothState().catch(() => {});
      });

  // Pair
  } else if (target.classList.contains('pair-bt-btn')) {
    e.preventDefault();
    const name = target.dataset.name || '';
    stopBluetoothScan();
    setButtonLoading(target, true);
    setBluetoothRowProgress(target, 'Emparejando y verificando audio…');
    setResult('bt-result', 'Emparejando…', 'loading');

    csrfFetch('/pair', {
      method: 'POST',
      body: 'mac=' + encodeURIComponent(mac) + '&name=' + encodeURIComponent(name),
    })
      .then(r => r.json())
      .then(d => {
        setResult('bt-result', d.message || 'Emparejado', d.success ? 'success' : 'error');
        if (d.success) {
          showToast('Emparejado exitosamente', 'success');
          refreshBluetoothState().catch(() => {});
        } else {
          setButtonLoading(target, false);
          refreshBluetoothState().catch(() => {});
        }
      })
      .catch(() => {
        setResult('bt-result', getHttpErrorMessage(0, null), 'error');
        setButtonLoading(target, false);
        refreshBluetoothState().catch(() => {});
      });
  }
});

// ── Music Status ───────────────────────────────────────────────────────────────

const musicDisc = document.getElementById('music-disc');
const musicTrack = document.getElementById('music-track');
const speakerDot = document.getElementById('speaker-dot');
const speakerLabel = document.getElementById('speaker-label');

function updateMusicStatus() {
  fetch('/music/status')
    .then(r => {
      if (!r.ok) throw new Error(`http-${r.status}`);
      return r.json();
    })
    .then(data => {
      // Track
      const trackName = data.is_playing ? data.track_name : 'Sin reproducción';
      if (trackName !== state.lastTrackName) {
        state.lastTrackName = trackName;
        if (musicTrack) musicTrack.textContent = trackName;

        // Disc animation
        if (musicDisc) {
          if (data.is_playing) {
            musicDisc.classList.add('spinning');
          } else {
            musicDisc.classList.remove('spinning');
          }
        }
      }

      // Speaker status
      if (data.speaker_connected) {
        if (speakerDot) {
          speakerDot.classList.add('connected');
        }
        if (speakerLabel) {
          speakerLabel.textContent = 'Bocina conectada' + (data.speaker_mac ? ' — ' + data.speaker_mac : '');
        }
      } else {
        if (speakerDot) {
          speakerDot.classList.remove('connected');
        }
        if (speakerLabel) {
          speakerLabel.textContent = 'Bocina no conectada';
        }
      }
    })
    .catch(() => {
      // Silently ignore music status errors
    });
}

// Initial poll and interval
updateMusicStatus();
setInterval(updateMusicStatus, CONFIG.MUSIC_POLL_INTERVAL);

// ── WiFi: Scan ───────────────────────────────────────────────────────────────

document.getElementById('scanWifiBtn').addEventListener('click', function() {
  const btn = this;
  const scanEl = document.getElementById('wifi-scan-status');
  const tableEl = document.getElementById('wifi-table');

  btn.disabled = true;
  scanEl.textContent = 'Escaneando… ';

  fetch('/wifi/scan')
    .then(r => r.json())
    .then(data => {
      if (data.busy) {
        scanEl.textContent = data.message || CONFIG.MSG_WIFI_SCAN_BUSY;
        return;
      }

      if (!data.networks || data.networks.length === 0) {
        tableEl.innerHTML = '<div class="no-devices">No se encontraron redes.</div>';
      } else {
        let html = '';
        data.networks.forEach(n => {
          html += `
            <div class="wifi-row">
              <div class="wifi-info">
                <div>
                  <div class="wifi-name">${escapeHtml(n.ssid)}</div>
                  <div class="wifi-meta">
                    <span class="wifi-signal">${signalIcon(n.signal)}${n.signal}%</span>
                    ${n.security ? '<span title="Red protegida">🔒</span>' : ''}
                  </div>
                </div>
              </div>
              <button class="btn-outline connect-wifi-btn"
                data-ssid="${escapeHtml(n.ssid)}"
                data-security="${escapeHtml(n.security || '')}"
                data-saved="${n.saved ? '1' : '0'}">
                Conectar
              </button>
            </div>`;
        });
        tableEl.innerHTML = html;
      }
      scanEl.textContent = '';
      assignWifiEvents();
    })
    .catch(() => {
      scanEl.textContent = 'Error al escanear';
    })
    .finally(() => {
      btn.disabled = false;
    });
});

// ── WiFi: Connect ─────────────────────────────────────────────────────────────

let selectedSsid = '';
let selectedSecurity = '';

function assignWifiEvents() {
  document.querySelectorAll('.connect-wifi-btn').forEach(btn => {
    btn.addEventListener('click', function() {
      selectedSsid = this.dataset.ssid;
      const security = this.dataset.security;
      selectedSecurity = security || '';
      const saved = this.dataset.saved === '1';

      if (security && security !== '' && !saved) {
        // Show password modal
        document.getElementById('modal-ssid').textContent = 'Conectar a: ' + selectedSsid;
        document.getElementById('wifi-password').value = '';
        document.getElementById('wifi-modal').classList.add('active');
        setTimeout(() => document.getElementById('wifi-password').focus(), 100);
      } else {
        connectWifi(selectedSsid, '');
      }
    });
  });
}
assignWifiEvents();

function closeModal() {
  document.getElementById('wifi-modal').classList.remove('active');
}

function confirmWifiConnect() {
  const passwordInput = document.getElementById('wifi-password');
  const password = passwordInput.value;
  const validationError = validateWifiPassword(password, selectedSecurity);
  if (validationError) {
    setResult('wifi-modal-error', validationError, 'error');
    passwordInput.focus();
    return;
  }
  setResult('wifi-modal-error', '');
  closeModal();
  connectWifi(selectedSsid, password);
}

function validateWifiPassword(password, security) {
  if (!security) return '';
  if (!password) return 'Ingresa la contraseña de esta red protegida.';
  if (/[\0\r\n]/.test(password)) return 'La contraseña contiene caracteres no permitidos.';
  const byteLength = new TextEncoder().encode(password).length;
  const rawPsk = /^[0-9A-Fa-f]{64}$/.test(password);
  if (!rawPsk && (byteLength < 8 || byteLength > 63)) {
    return 'La contraseña debe tener entre 8 y 63 bytes, o ser una clave hexadecimal de 64 caracteres.';
  }
  return '';
}

// Modal interactions
document.getElementById('wifi-modal').addEventListener('click', function(e) {
  if (e.target === this) closeModal();
});

document.getElementById('wifi-password').addEventListener('keydown', function(e) {
  if (e.key === 'Enter') confirmWifiConnect();
});

// Expose functions for inline onclick handlers
window.confirmWifiConnect = confirmWifiConnect;
window.closeModal = closeModal;

function connectWifi(ssid, password) {
  if (state.wifiConnecting) return;
  state.wifiConnecting = true;

  setResult('wifi-result', `Preparando la conexión a ${ssid}…`, 'loading');

  csrfFetch('/wifi/connect', {
    method: 'POST',
    body: JSON.stringify({ ssid, password }),
  })
    .then(async response => {
      const data = await response.json().catch(() => ({}));
      if (!response.ok || !data.success || !data.accepted || !data.commit_url) {
        setResult('wifi-result', data.message || getHttpErrorMessage(response.status, data), 'error');
        state.wifiConnecting = false;
        return;
      }

      const acceptedMessage = data.message +
        ' Después, conecta este teléfono a esa red y abre http://sigil.local.';
      setResult('wifi-result', acceptedMessage, 'success');

      // This second request proves that the browser received the accepted
      // response. Its response is intentionally not required after AP teardown.
      csrfFetch(data.commit_url, { method: 'POST', timeoutMs: 15000 })
        .then(async commitResponse => {
          if (!commitResponse.ok) {
            const commitData = await commitResponse.json().catch(() => ({}));
            setResult('wifi-result', commitData.message || 'No se pudo iniciar la transición WiFi.', 'error');
            state.wifiConnecting = false;
          }
        })
        .catch(() => {
          // Expected when the accepted transition removes the SIGIL AP.
          setResult('wifi-result', acceptedMessage, 'success');
        });
      setTimeout(() => { state.wifiConnecting = false; }, 45000);
    })
    .catch(() => {
      setResult('wifi-result', CONFIG.MSG_NETWORK_ERROR, 'error');
      state.wifiConnecting = false;
    });
}

// ── System Status ─────────────────────────────────────────────────────────────

function formatUptime(seconds) {
  if (!seconds || seconds < 0) return '—';
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const parts = [];
  if (d > 0) parts.push(d + 'd');
  if (h > 0) parts.push(h + 'h');
  parts.push(m + 'm');
  return parts.join(' ') || '0m';
}

function updateSystemStatus() {
  fetch('/api/system-status')
    .then(r => r.json())
    .then(data => {
      // Uptime
      const uptimeEl = document.getElementById('sys-uptime');
      if (uptimeEl) uptimeEl.textContent = formatUptime(data.uptime_seconds);

      // Connection status
      const connEl = document.getElementById('sys-connection');
      if (connEl) {
        const connectedBar = document.querySelector('.status-bar.connected');
        if (connectedBar) {
          const ssidEl = connectedBar.querySelector('strong');
          connEl.textContent = ssidEl ? ssidEl.textContent.trim() : 'WiFi conectado';
          connEl.className = 'sys-value healthy';
        } else {
          connEl.textContent = 'Sin conexión';
          connEl.className = 'sys-value warning';
        }
      }
    })
    .catch(() => {
      // Silently ignore
    });
}

// Diagnostics toggle
(function() {
  const toggle = document.getElementById('diag-toggle');
  const diag = document.getElementById('diag-section');
  if (toggle && diag) {
    toggle.addEventListener('click', function(e) {
      e.preventDefault();
      const isOpen = diag.hasAttribute('open');
      if (isOpen) {
        diag.removeAttribute('open');
      } else {
        diag.setAttribute('open', '');
      }
      this.classList.toggle('open', !isOpen);
    });
  }
})();

// Initial and interval
setTimeout(updateSystemStatus, 500);
setInterval(updateSystemStatus, CONFIG.SYSTEM_POLL_INTERVAL);

// ── Cleanup on page unload ─────────────────────────────────────────────────────

window.addEventListener('beforeunload', function() {
  stopBluetoothScan();
  if (state.wifiPollInterval) {
    clearInterval(state.wifiPollInterval);
  }
});
