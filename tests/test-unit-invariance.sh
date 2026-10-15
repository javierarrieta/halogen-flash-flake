#!/usr/bin/env bash
# Assert the weights unit is revision-independent (must be identical) and that
# the declared-intent file does change with the revision (must differ).
#
# Run from the repo root: ./tests/test-unit-invariance.sh
set -uo pipefail
cd "$(dirname "$0")/.."

REV_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
REV_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

render() {
  nix-instantiate --eval --raw \
    --expr "import ./tests/unit-invariance.nix { rev = \"$1\"; }" 2>/dev/null
}

A="$(render "$REV_A")"
B="$(render "$REV_B")"

if [ -z "$A" ] || [ -z "$B" ]; then
  echo "FAIL: harness failed to evaluate" >&2
  nix-instantiate --eval --raw \
    --expr "import ./tests/unit-invariance.nix { rev = \"$REV_A\"; }"
  exit 1
fi

status=0

# Must be identical: anything switch-to-configuration would notice.
for prefix in WEIGHTS_ PATH_; do
  a="$(printf '%s\n' "$A" | grep "^$prefix")"
  b="$(printf '%s\n' "$B" | grep "^$prefix")"
  if [ "$a" = "$b" ]; then
    echo "ok: ${prefix%_} unit text identical across revisions"
  else
    echo "FAIL: ${prefix%_} unit text changes with the revision"
    diff <(printf '%s\n' "$a") <(printf '%s\n' "$b")
    status=1
  fi
done

# Must exist and be wired: otherwise the invariance checks above pass vacuously
# on a module that simply has no path unit.
if printf '%s\n' "$A" | grep -qx 'PATH_CHANGED=/etc/halogen-flash/target-revision' \
   && printf '%s\n' "$A" | grep -qx 'PATH_UNIT=halogen-flash-weights.service'; then
  echo "ok: path unit watches the intent file and activates the weights service"
else
  echo "FAIL: path unit missing or not wired to the intent file"
  printf '%s\n' "$A" | grep '^PATH_'
  status=1
fi

# Must be identical: the role unit must not be ordered behind the fetch.
a="$(printf '%s\n' "$A" | grep '^ROLE_')"
b="$(printf '%s\n' "$B" | grep '^ROLE_')"
if [ "$a" = "$b" ]; then
  echo "ok: role unit text identical across revisions"
else
  echo "FAIL: role unit text changes with the revision"
  diff <(printf '%s\n' "$a") <(printf '%s\n' "$b")
  status=1
fi

if printf '%s\n' "$A" | grep -q 'halogen-flash-weights.service' <<<"$(printf '%s\n' "$A" | grep '^ROLE_AFTER')"; then
  echo "FAIL: role unit is still ordered after halogen-flash-weights.service"
  status=1
else
  echo "ok: role unit has no ordering edge on the weights unit"
fi

# Must differ: this is the trigger, so it has to change on a bump.
a="$(printf '%s\n' "$A" | grep '^ETC_TARGET')"
b="$(printf '%s\n' "$B" | grep '^ETC_TARGET')"
if [ "$a" != "$b" ]; then
  echo "ok: target-revision content changes with the revision"
else
  echo "FAIL: target-revision content does not change with the revision"
  status=1
fi

exit "$status"
