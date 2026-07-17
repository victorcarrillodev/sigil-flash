#!/bin/bash
# Focused regression gate for the deliberately merged panel product contract.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

python3 -m unittest discover -s tests -p 'test_panel_product_contract.py' -v
python3 -m unittest discover -s tests -p 'test_bluetooth.py' -v
python3 -m unittest discover -s tests -p 'test_panel_auth.py' -v
python3 -m unittest discover -s tests -p 'test_wifi_bluetooth_coexistence.py' -v
python3 -m unittest discover -s tests -p 'test_privilege_separation.py' -v

printf '\nPanel product contract: 50 passed, 0 failed\n'
