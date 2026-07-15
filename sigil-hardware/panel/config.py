"""
config.py — Constantes globales, locks y estado compartido de Sigil.
Importado por bluetooth.py, wifi.py y app.py para evitar dependencias circulares.
"""
import threading

# ── Rutas de archivos del sistema ─────────────────────────────────────────────
PREFERRED_BT_FILE = '/home/sigil/preferred_bt.txt'

# ── Estado WiFi compartido (escrito por hilo de conexión, leído por /wifi/status) ──
wifi_status = {'running': False, 'success': None, 'message': ''}

# ── Locks de concurrencia ──────────────────────────────────────────────────────
scan_lock = threading.Lock()   # Un solo scan BT a la vez
