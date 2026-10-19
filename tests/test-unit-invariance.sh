#!/usr/bin/env bash
# Assert that no generated unit text depends on the pinned weights revision, and
# that the declared-intent file does.
#
# The first half is what makes a weights bump a non-event for the running
# inference server: switch-to-configuration restarts any unit whose text
# changed, so a single leaked `${targetRevision}` anywhere in a unit costs a
# full weights reload. The second half is the trigger: if the intent file did not
# change, nothing would ever fetch the new weights.
#
# Run from the repo root: ./tests/test-unit-invariance.sh
set -uo pipefail
cd "$(dirname "$0")/.."

REV_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
REV_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

status=0
fail() {
  echo "FAIL: $*"
  status=1
}
ok() { echo "ok: $*"; }

render() {
  nix-instantiate --eval --raw \
    --expr "import ./tests/unit-invariance.nix { rev = \"$1\"; mode = \"$2\"; }" 2>/dev/null
}

for mode in all split; do
  echo "--- mode=$mode ---"
  A="$(render "$REV_A" "$mode")"
  B="$(render "$REV_B" "$mode")"

  if [ -z "$A" ] || [ -z "$B" ]; then
    fail "harness failed to evaluate (mode=$mode)"
    nix-instantiate --eval --raw \
      --expr "import ./tests/unit-invariance.nix { rev = \"$REV_A\"; mode = \"$mode\"; }"
    continue
  fi

  # 1. Everything switch-to-configuration could notice must be identical.
  #    Compared as a whole render, not field by field, so a leak through a field
  #    nobody thought to list here still fails.
  a="$(printf '%s\n' "$A" | grep -v '^ETC_TARGET=')"
  b="$(printf '%s\n' "$B" | grep -v '^ETC_TARGET=')"
  if [ "$a" = "$b" ]; then
    ok "all unit text identical across revisions"
  else
    fail "some unit text changes with the revision"
    diff <(printf '%s\n' "$a") <(printf '%s\n' "$b")
  fi

  # 2. Belt for the belt: the revision string may appear on exactly one line.
  #    Catches a leak that happens to be identical at both test revisions.
  hits="$(printf '%s\n' "$A" | grep -F "$REV_A" | grep -v '^ETC_TARGET=' || true)"
  hits2="$(printf '%s\n' "$B" | grep -F "$REV_B" | grep -v '^ETC_TARGET=' || true)"
  if [ -z "$hits" ] && [ -z "$hits2" ]; then
    ok "revision string appears nowhere but the intent file"
  else
    fail "revision string leaked into unit text"
    printf '%s\n' "$hits$hits2"
  fi

  # 3. The intent file is the trigger, so it must change on a bump.
  ea="$(printf '%s\n' "$A" | grep '^ETC_TARGET')"
  eb="$(printf '%s\n' "$B" | grep '^ETC_TARGET')"
  if [ "$ea" != "$eb" ]; then
    ok "target-revision content changes with the revision"
  else
    fail "target-revision content does not change with the revision"
  fi

  # 4. The path unit must exist and be wired, or every check above passes
  #    vacuously on a module that has no trigger at all.
  if printf '%s\n' "$A" | grep -qx 'PATH_CFG_PathChanged=/etc/halogen-flash/target-revision' \
     && printf '%s\n' "$A" | grep -qx 'PATH_CFG_Unit=halogen-flash-weights.service'; then
    ok "path unit watches the intent file and activates the weights service"
  else
    fail "path unit missing or not wired to the intent file"
    printf '%s\n' "$A" | grep '^PATH_' || true
  fi

  # 5. StartLimit* is a [Unit] directive. NixOS renders serviceConfig into
  #    [Service], where systemd ignores these keys with a warning, so putting
  #    them there silently loses the bounded-retry guarantee.
  if printf '%s\n' "$A" | grep -q '^halogen_flash_weights_UNIT_StartLimitBurst=' \
     && printf '%s\n' "$A" | grep -q '^halogen_flash_weights_UNIT_StartLimitIntervalSec=' \
     && ! printf '%s\n' "$A" | grep -q '^halogen_flash_weights_CFG_StartLimit'; then
    ok "start-limit keys are in [Unit], where systemd reads them"
  else
    fail "start-limit keys are not in [Unit]; systemd would ignore them"
    printf '%s\n' "$A" | grep -i 'StartLimit' || true
  fi

  # 6. The role unit must not be ordered behind the fetch, or a bump still
  #    blocks the server.
  if printf '%s\n' "$A" | grep -E '^[a-z_]+_after=' | grep -q 'halogen-flash-weights.service'; then
    fail "a role unit is still ordered after halogen-flash-weights.service"
  else
    ok "role units have no ordering edge on the weights unit"
  fi

  # 7. The role units must mount the constant `current` symlink, not a path that
  #    names the revision.
  if printf '%s\n' "$A" | grep -E '^[a-z_]+_(CFG|UNIT)_' | grep -q '/current'; then
    ok "role units mount the constant current path"
  else
    fail "role units do not reference the constant current mount path"
  fi

  # 8. `podman run` must be able to take over a container left by a crashed or
  #    detached previous run. Without --replace the fixed `--name` makes every
  #    start fail with "container name already in use" and the unit crash-loops
  #    on it forever (llm01 was down ~19 min this way on 2026-10-19).
  if printf '%s\n' "$A" | grep -E '^[a-z_]+_CFG_ExecStart=' | grep -q -- '--replace'; then
    ok "role units pass --replace to podman run"
  else
    fail "role units would fail to start if a previous container survived"
    printf '%s\n' "$A" | grep -E '^[a-z_]+_CFG_ExecStart=' || true
  fi
done

exit "$status"
