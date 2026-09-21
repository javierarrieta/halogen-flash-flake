#!/usr/bin/env bash
# Bump the pinned halogen-flash-server image tag in nixos/module.nix.
#
# The "halogen version" is not a flake input: it is a string literal in the
# `image` option default, so no Nix-aware bot (Dependabot's nix ecosystem
# included -- it only rewrites flake.lock / input URLs) can see it. This
# script is the missing hop:
#
#   1. resolve the newest semver tag published on GHCR (anonymous pull token)
#   2. compare it to the tag pinned in nixos/module.nix
#   3. patch the module in place and write a PR body carrying the upstream
#      contract diff (docker-compose.yml + FLAGS.md + CHANGELOG slice), so a
#      human can review what actually changed before merging
#
# The image is never pulled or run here: the module documents that the image
# is used as-is and must be `podman pull`ed on the host. This script only
# opens a PR; merging stays a human decision.
#
# Outputs (written to $GITHUB_OUTPUT when present):
#   current  tag pinned before the run
#   new      newest upstream tag
#   changed  "true" if module.nix was patched, else "false"
#   digest   manifest digest of the new tag ("" if unavailable)
#
# Environment overrides (all optional):
#   IMAGE, UPSTREAM_REPO, MODULE, BODY_FILE, TARGET
#   TARGET  pin to a specific tag instead of the newest on GHCR (used by
#           `workflow_dispatch`); must exist in the registry's tag list.
set -euo pipefail

IMAGE="${IMAGE:-ghcr.io/peonist-ai/halogen-flash-server}"
UPSTREAM_REPO="${UPSTREAM_REPO:-peonist-ai/halogen-flash-server}"
MODULE="${MODULE:-nixos/module.nix}"
BODY_FILE="${BODY_FILE:-${RUNNER_TEMP:-/tmp}/halogen-bump-body.md}"
TARGET="${TARGET:-}"

# Path within GHCR's API namespace (strip the registry host).
GHCR_PATH="${IMAGE#ghcr.io/}"

# `head -n` closes the pipe early and SIGPIPEs the producer, which `set -o
# pipefail` turns into a spurious 141. sed reads everything, so it is safe.
head_n() { sed -n "1,$1p"; }

out() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"
  fi
  printf '%s=%s\n' "$1" "$2"
}

# --- 1. newest semver tag on GHCR -------------------------------------------
# The tag list is paginated by `n`; 1000 covers us for years. `latest` is
# deliberately ignored -- it is not a version we can review a diff against.
pull_token="$(curl -fsSL --retry 3 \
  "https://ghcr.io/token?scope=repository:${GHCR_PATH}:pull" | jq -r '.token')"

tag_list="$(curl -fsSL --retry 3 \
  -H "Authorization: Bearer ${pull_token}" \
  "https://ghcr.io/v2/${GHCR_PATH}/tags/list?n=1000" \
  | jq -r '.tags[]?' \
  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$')"

if [ -n "${TARGET}" ]; then
  new="${TARGET}"
  if ! printf '%s\n' "${tag_list}" | grep -qxF "${new}"; then
    echo "::error::requested target ${new} is not a published tag for ${IMAGE}" >&2
    exit 1
  fi
else
  new="$(printf '%s\n' "${tag_list}" | sort -V | tail -n1)"
fi

if [ -z "${new}" ]; then
  echo "::error::no semver tags found for ${IMAGE} on GHCR" >&2
  exit 1
fi

# --- 2. current pin ---------------------------------------------------------
# Python rather than grep/sed: the image reference is a literal we must match
# exactly, and re.escape() beats hand-rolled BRE escaping. The existing pin
# may or may not carry a digest; capture both so a tag that moved upstream is
# detectable rather than silently ignored.
read -r cur cur_digest < <(python3 - "${MODULE}" "${IMAGE}" <<'PY'
import re, sys

path, image = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    text = fh.read()
match = re.search(
    re.escape(image) + r':(\d+\.\d+\.\d+)(?:@(sha256:[0-9a-f]{64}))?"', text
)
if match:
    print(match.group(1), match.group(2) or "")
else:
    print("")
PY
)

if [ -z "${cur}" ]; then
  echo "::error::could not find a pinned ${IMAGE}:<version> in ${MODULE}" >&2
  exit 1
fi

out current "${cur}"
out current_digest "${cur_digest}"
out new "${new}"

# --- 3. digest (best effort) ------------------------------------------------
# The release is an OCI image manifest; GHCR 404s unless the Accept header
# names that media type explicitly. Fetched BEFORE the up-to-date check: the
# comparison below reads it, and `set -u` would abort on an unset variable.
digest="$(curl -fsSL --retry 3 -o /dev/null -w '%header{docker-content-digest}' \
  -H "Authorization: Bearer ${pull_token}" \
  -H "Accept: application/vnd.oci.image.manifest.v1+json" \
  "https://ghcr.io/v2/${GHCR_PATH}/manifests/${new}" 2>/dev/null || true)"
out digest "${digest}"

# A tag that moved under us is a change worth a PR even when the version
# string is unchanged -- it means the reviewed artifact and the registry's
# current one are different bytes.
if [ "${cur}" = "${new}" ] && { [ -z "${digest}" ] || [ "${cur_digest}" = "${digest}" ]; }; then
  echo "${IMAGE} is already pinned to the newest upstream tag (${cur})."
  out changed "false"
  exit 0
fi

if [ "${cur}" = "${new}" ]; then
  reason="tag-moved"
else
  reason="bump"
fi
out reason "${reason}"

# --- 4. upstream contract diff ----------------------------------------------
# GitHub's compare API gives per-file patches without a clone. The git tags are
# `v`-prefixed while the image tags are not.
#
# `patch` is null when a file is too large for the API, and the whole compare
# 404s if a tag is missing (e.g. a pin that predates upstream tagging), so
# every fetch here is optional and degrades to "could not fetch".
compare_json="$(curl -fsSL --retry 3 \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/${UPSTREAM_REPO}/compare/v${cur}...v${new}" \
  2>/dev/null || true)"

file_patch() { # file_patch <filename> <max lines>
  printf '%s' "${compare_json}" | jq -r --arg f "$1" '
    (.files // [] | map(select(.filename == $f)) | .[0].patch // empty)
  ' 2>/dev/null | head_n "$2"
}

commit_list="$(printf '%s' "${compare_json}" | jq -r '
  (.commits // [])[] | "- \(.sha[0:7]) \(.commit.message | split("\n")[0])"
' 2>/dev/null | head_n 40 || true)"

compose_patch="$(file_patch docker-compose.yml 120)"
flags_patch="$(file_patch docs/FLAGS.md 80)"

# CHANGELOG slice: headings are `## <version>` (unprefixed). Take everything
# from the new version down to (not including) the currently pinned one.
changelog="$(curl -fsSL --retry 3 \
  "https://raw.githubusercontent.com/${UPSTREAM_REPO}/v${new}/CHANGELOG.md" \
  2>/dev/null | awk -v new="## ${new}" -v cur="## ${cur}" '
    index($0, new) == 1 { keep = 1 }
    keep && index($0, cur) == 1 { exit }
    keep { print }
  ' | head_n 200 || true)"

# --- 5. patch the module ----------------------------------------------------
# Rewrite the whole reference (version and any existing digest) so the pin
# never ends up with a stale digest glued onto a new tag.
python3 - "${MODULE}" "${IMAGE}" "${new}" "${digest}" <<'PY'
import re, sys

path, image, new, digest = sys.argv[1:5]
pattern = re.escape(image) + r':\d+\.\d+\.\d+(?:@sha256:[0-9a-f]{64})?'
replacement = f"{image}:{new}" + (f"@{digest}" if digest else "")

with open(path, encoding="utf-8") as fh:
    text = fh.read()

new_text, count = re.subn(pattern, replacement, text)
if count == 0:
    sys.exit(f"no pinned reference for {image!r} found in {path}; refusing to patch")

with open(path, "w", encoding="utf-8") as fh:
    fh.write(new_text)
print(f"patched {count} occurrence(s) -> {replacement}")
PY

out changed "true"

# --- 6. PR body -------------------------------------------------------------
# The weights live in a separate HuggingFace repo and float on its default
# branch unless the deployment pins download.revision. Report where upstream
# is so a weights move shows up in this PR instead of arriving silently on
# the next service start.
WEIGHTS_REPO="${WEIGHTS_REPO:-peonist-ai/halogen-qwen3.8-flash-next}"
hf_json="$(curl -fsSL --retry 2 "https://huggingface.co/api/models/${WEIGHTS_REPO}" 2>/dev/null || true)"
hf_sha="$(printf '%s' "${hf_json}" | jq -r '.sha // empty' 2>/dev/null || true)"
hf_modified="$(printf '%s' "${hf_json}" | jq -r '.lastModified // empty' 2>/dev/null || true)"
out hf_sha "${hf_sha}"

{
  echo "## ${IMAGE}"
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| Was pinned | \`${IMAGE}:${cur}${cur_digest:+@${cur_digest}}\` |"
  echo "| Now pinned | \`${IMAGE}:${new}${digest:+@${digest}}\` |"
  if [ "${reason}" = "tag-moved" ]; then
    echo
    echo "> **Upstream moved the \`${new}\` tag** -- same version string, different"
    echo "> bytes. Whatever is running was built from the old manifest, so this"
    echo "> diff is not the one that produced the current deployment."
  fi
  if [ -z "${digest}" ]; then
    echo
    echo "> **Digest unavailable** (registry fetch failed): the new pin is tag-only."
    echo "> That is not safe with \`pull.enable\` -- the module warns about it."
    echo "> Re-run once the registry is reachable to get a pinned reference."
  fi
  echo
  echo "### Weights (separate repo — this PR does not change them)"
  echo
  if [ -n "${hf_sha}" ]; then
    echo "Upstream \`${WEIGHTS_REPO}\` is at \`${hf_sha}\` (${hf_modified:-unknown})."
    echo
    echo "The image above is digest-pinned; the weights are only as reproducible as"
    echo "the deployment's \`services.halogenFlash.download.revision\`. Changing that"
    echo "sha is a **deliberate, separate** change: the next service start fetches"
    echo "~118 GiB, so the health-gate warmup window has to outlast it."
  else
    echo "Could not read \`${WEIGHTS_REPO}\` from the HuggingFace API."
  fi
  echo
  echo "Opened automatically by \`.github/workflows/bump-image.yml\`. **Nothing was"
  echo "pulled, deployed, or restarted by this PR.** With \`pull.enable\` off (the"
  echo "default) the image has to be pulled by hand before the next deploy; with"
  echo "\`pull.enable\` on, the host pulls the pinned digest itself at service"
  echo "start, so merging is what changes the running version on the next deploy."
  echo
  echo "### Review before merging"
  echo
  echo "This is a \`${cur}\` -> \`${new}\` jump. The runtime flags in"
  echo "\`nixos/module.nix\` encode the upstream container contract as of 0.6.x"
  echo "(seccomp escape, device passthrough, \`--ipc=host\`, memlock, the tokenizer"
  echo "mount, and which port is published). Check the diff below for changes to any"
  echo "of those, and update the module in the same PR if they moved."
  echo
  echo "- [ ] Contract diff below touches nothing the module hardcodes"
  echo "      (or the module was updated to match)"
  echo "- [ ] Env var names/semantics unchanged (\`docs/FLAGS.md\` diff)"
  echo "- [ ] Engine and API still run the **same** tag (upstream issue #26:"
  echo "      version skew silently mis-routes vision requests)"
  echo "- [ ] Pulled on llm01 before deploy (skip if \`pull.enable\` is set):"
  echo "      \`sudo -u ollama HOME=/opt/llm/halogen XDG_RUNTIME_DIR=/run/user/27002 podman pull ${IMAGE}:${new}${digest:+@${digest}}\`"
  echo "- [ ] GTT budget still fits: a restart reloads ~115 GiB, and the health"
  echo "      gate rolls the deploy back if \`/health\` misses warmup"
  if [ -n "${compose_patch}" ]; then
    echo
    echo "<details><summary>docker-compose.yml diff (upstream contract)</summary>"
    echo
    echo '```diff'
    printf '%s\n' "${compose_patch}"
    echo '```'
    echo
    echo "</details>"
  fi
  if [ -n "${flags_patch}" ]; then
    echo
    echo "<details><summary>docs/FLAGS.md diff</summary>"
    echo
    echo '```diff'
    printf '%s\n' "${flags_patch}"
    echo '```'
    echo
    echo "</details>"
  fi
  if [ -n "${changelog}" ]; then
    echo
    echo "<details><summary>upstream CHANGELOG ${cur} -> ${new}</summary>"
    echo
    printf '%s\n' "${changelog}"
    echo
    echo "</details>"
  fi
  if [ -n "${commit_list}" ]; then
    echo
    echo "<details><summary>upstream commits</summary>"
    echo
    printf '%s\n' "${commit_list}"
    echo
    echo "</details>"
  fi
  if [ -z "${compose_patch}${flags_patch}${changelog}${commit_list}" ]; then
    echo
    echo "> Could not fetch the upstream diff (missing \`v${cur}\`/\`v${new}\` git"
    echo "> tags, or the GitHub API was unavailable). Review upstream by hand."
  fi
} >"${BODY_FILE}"

echo "PR body written to ${BODY_FILE}"
