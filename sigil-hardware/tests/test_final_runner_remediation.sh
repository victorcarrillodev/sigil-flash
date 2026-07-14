#!/bin/bash
# Behavioral verification for the aggregate test runner.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
tmp_dir=$(mktemp -d /tmp/sigil-runner-test.XXXXXX)
cleanup() { rm -rf "$tmp_dir"; }
trap cleanup EXIT

cat > "$tmp_dir/fail.sh" <<'EOF'
#!/bin/bash
exit 7
EOF
cat > "$tmp_dir/later.sh" <<EOF
#!/bin/bash
touch "$tmp_dir/later-ran"
exit 0
EOF
chmod +x "$tmp_dir/fail.sh" "$tmp_dir/later.sh"

rc=0
SIGIL_TEST_SUITES="$tmp_dir/fail.sh:$tmp_dir/later.sh" \
    bash "$HERE/run.sh" > "$tmp_dir/output" 2>&1 || rc=$?

failures=0
if [ "$rc" -eq 0 ]; then
    echo "FAIL: aggregate runner returned success after a failing suite"
    failures=$((failures + 1))
else
    echo "ok: aggregate runner returned nonzero after a failing suite"
fi
if [ ! -f "$tmp_dir/later-ran" ]; then
    echo "FAIL: aggregate runner did not execute the later suite"
    failures=$((failures + 1))
else
    echo "ok: aggregate runner executed the later suite"
fi
if ! grep -q '1 suite(s) passed, 1 suite(s) failed' "$tmp_dir/output"; then
    echo "FAIL: aggregate summary did not include both suite results"
    failures=$((failures + 1))
else
    echo "ok: aggregate summary includes both suite results"
fi

echo "Results: $((3 - failures)) passed, ${failures} failed"
[ "$failures" -eq 0 ]
