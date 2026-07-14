#!/bin/bash
# sigil-validate-state.sh — Validate Sigil JSON state files
#
# Usage:
#   sigil-validate-state.sh <json-file> [schema-file]
#
# If schema-file is provided, validates against JSON Schema (draft-07).
# If no schema-file, validates that JSON is parseable and has _schema_version.
#
# Returns 0 on success, 1 on failure with error message.
# =============================================================================
set -euo pipefail

JSON_FILE="${1:-}"
SCHEMA_FILE="${2:-}"

if [ -z "$JSON_FILE" ]; then
    echo "ERROR: Usage: sigil-validate-state.sh <json-file> [schema-file]" >&2
    exit 1
fi

if [ ! -f "$JSON_FILE" ]; then
    echo "ERROR: File not found: $JSON_FILE" >&2
    exit 1
fi

# Step 1: Validate JSON is parseable and check _schema_version
python3 - "$JSON_FILE" <<'PYEOF' 2>&1 || exit 1
import json, sys, os

json_file = sys.argv[1]
try:
    with open(json_file) as f:
        data = json.load(f)
except json.JSONDecodeError as e:
    print(f'ERROR: Invalid JSON in {json_file}: {e}', file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f'ERROR: Cannot read {json_file}: {e}', file=sys.stderr)
    sys.exit(1)

if '_schema_version' not in data:
    print(f'WARNING: {json_file} missing _schema_version field', file=sys.stderr)
else:
    print(f'OK: {json_file} is valid JSON (_schema_version={data["_schema_version"]})')
PYEOF

# Step 2: If schema file provided, validate against it
if [ -n "$SCHEMA_FILE" ]; then
    if [ ! -f "$SCHEMA_FILE" ]; then
        echo "ERROR: Schema file not found: $SCHEMA_FILE" >&2
        exit 1
    fi
    python3 - "$JSON_FILE" "$SCHEMA_FILE" <<'PYEOF' 2>&1 || exit 1
import json, sys, os

json_file   = sys.argv[1]
schema_file = sys.argv[2]

try:
    from jsonschema import validate, ValidationError
except ImportError:
    print('NOTE: jsonschema not installed, skipping schema validation', file=sys.stderr)
    sys.exit(0)

try:
    with open(json_file) as f:
        data = json.load(f)
    with open(schema_file) as f:
        schema = json.load(f)
    validate(instance=data, schema=schema)
    print(f'OK: {json_file} validates against {os.path.basename(schema_file)}')
except ValidationError as e:
    print(f'ERROR: {json_file} failed validation against {schema_file}:', file=sys.stderr)
    print(f'  Path: {" -> ".join(str(p) for p in e.absolute_path)}', file=sys.stderr)
    print(f'  Reason: {e.message}', file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f'ERROR: Schema validation failed: {e}', file=sys.stderr)
    sys.exit(1)
PYEOF
fi

exit 0
