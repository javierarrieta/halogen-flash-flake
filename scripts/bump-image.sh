#!/usr/bin/env bash
# Bump the pinned halogen-flash-server image and weights revision in
# nixos/module.nix.
#
# Neither is a flake input: both are string literals in nixos/module.nix --
# the `image` option default, and `defaultWeightsRevision` for the ~118 GiB
# HuggingFace checkpoint. So no Nix-aware bot (Dependabot's nix ecosystem
# included -- it only rewrites flake.lock / input URLs) can see them. This
# script is the missing hop:
#
#   1. resolve the newest semver tag published on GHCR (anonymous pull token)
#   2. read the upstream HEAD sha of the weights repo on HuggingFace
#   3. compare BOTH against what nixos/module.nix pins, independently
#   4. patch whichever moved and write a PR body carrying the upstream
#      contract diff, so a human can review before merging
#
# Why the weights are checked separately: they move on their own schedule.
# A new checkpoint with no new image tag would otherwise go unnoticed until
# some later image bump happened to surface the sha.
#
# Nothing is pulled or run here. This script only opens a PR; merging stays
# a human decision, and the image is pulled on the host at service start.
#
# Outputs (written to $GITHUB_OUTPUT when present):
#   current          image tag pinned before the run
#   current_digest   image digest pinned before the run
#   new              newest upstream image tag
#   digest           manifest digest of the new tag ("" if unavailable)
#   current_weights  weights revision pinned before the run
#   new_weights      upstream weights HEAD sha ("" if the API was unreachable)
#   hf_modified      upstream weights lastModified timestamp
#   image_changed    "true" if the image reference needs patching
#   weights_changed  "true" if defaultWeightsRevision needs patching
#   weights_content  "same" | "different" | "unknown": did the bytes the engine
#                        reads actually move between the two revisions
#   weights_noop     "true" if the revision moved but no downloaded byte did
#   changed          "true" if either does (module.nix was patched)
#   reason           "bump" | "tag-moved" | "none" (image-side only)
#   exclude_changed  "true" if the download.exclude default was re-patched
#   download_gib     projected download (GiB) with the final exclude list
#   excluded_gib     projected skipped size (GiB)
#   exclude_added    count of brand-new large files auto-excluded
#   exclude_dropped  count of stale patterns removed
#   exclude_over_budget "true" if projected download exceeds the budget
#   exclude_review   "true" if a human must confirm the exclude changes
#   branch           branch name to commit the patch to
#   pr_title         commit message / PR title
#
# Environment overrides (all optional):
#   IMAGE, UPSTREAM_REPO, WEIGHTS_REPO, MODULE, BODY_FILE, TARGET
#   TARGET  pin to a specific tag instead of the newest on GHCR (used by
#           `workflow_dispatch`); must exist in the registry's tag list.
#   EXCLUDE_MIN_GIB      min size (GiB) for a brand-new file to be auto-excluded
#                        on a weights bump (default 2)
#   DOWNLOAD_BUDGET_GIB  projected-download budget (GiB) above which the PR is
#                        flagged for review (default 200)
set -euo pipefail

IMAGE="${IMAGE:-ghcr.io/peonist-ai/halogen-flash-server}"
UPSTREAM_REPO="${UPSTREAM_REPO:-peonist-ai/halogen-flash-server}"
WEIGHTS_REPO="${WEIGHTS_REPO:-peonist-ai/halogen-qwen3.8-flash-next}"
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

# --- 2. current image pin ---------------------------------------------------
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

# --- 3. image digest (best effort) ------------------------------------------
# The release is an OCI image manifest; GHCR 404s unless the Accept header
# names that media type explicitly. Fetched BEFORE the up-to-date check: the
# comparison below reads it, and `set -u` would abort on an unset variable.
digest="$(curl -fsSL --retry 3 -o /dev/null -w '%header{docker-content-digest}' \
  -H "Authorization: Bearer ${pull_token}" \
  -H "Accept: application/vnd.oci.image.manifest.v1+json" \
  "https://ghcr.io/v2/${GHCR_PATH}/manifests/${new}" 2>/dev/null || true)"
out digest "${digest}"

# --- 4. weights: current pin and upstream HEAD ------------------------------
# Read and queried BEFORE any up-to-date decision, so a weights-only release
# is never short-circuited by an unchanged image.
cur_weights="$(python3 - "${MODULE}" <<'PY'
import re, sys

with open(sys.argv[1], encoding="utf-8") as fh:
    text = fh.read()
match = re.search(r'defaultWeightsRevision\s*=\s*"([0-9a-f]{40})"', text)
print(match.group(1) if match else "")
PY
)"
out current_weights "${cur_weights}"

hf_json="$(curl -fsSL --retry 2 \
  "https://huggingface.co/api/models/${WEIGHTS_REPO}" 2>/dev/null || true)"
new_weights="$(printf '%s' "${hf_json}" \
  | jq -r '.sha // empty' 2>/dev/null || true)"
hf_modified="$(printf '%s' "${hf_json}" \
  | jq -r '.lastModified // empty' 2>/dev/null || true)"
out new_weights "${new_weights}"
out hf_modified "${hf_modified}"

# An unreachable API must be loud even when nothing else changed: without
# this, a run that could not check the weights looks identical to a run
# that checked them and found them current. The PR-body note only exists
# when a PR is opened, so the annotation is what covers the quiet case.
weights_probe="ok"
if [ -z "${new_weights}" ]; then
  weights_probe="failed"
  echo "::warning::could not read ${WEIGHTS_REPO} from the HuggingFace API; the weights revision was NOT verified this run." >&2
fi
out weights_probe "${weights_probe}"

# --- 4b. did the weights commit move any byte the engine reads? -------------
# A commit id is not a content hash. Upstream commits the weights repo with
# huggingface_hub on its own schedule and most of those commits re-upload
# README.md only: every .hgn and every tokenizer file is untouched and carries
# the same sha256. Judging the pin on the commit id alone therefore opens a bump
# PR for a change that downloads nothing new -- and taking such a commit is not
# free. The module keys its version dir and its fetch-completion marker on the
# commit id rather than the content, so a new id re-fetches the whole 112.1 GiB
# set into a second tree (peak ~224 GiB on the volume) to end up with bytes the
# running server already has, then restarts to load them.
#
# So the revision counts as moved only when the bytes that would actually be
# fetched moved. "Fetched" means the files the engine reads -- *.hgn plus
# tokenizer/ -- minus what download.exclude skips. Repo documentation
# (README.md, halogen.jpg, .gitattributes) is left out of the fingerprint: the
# container never reads it and the server never validates it.
#
# "unknown" is deliberately NOT treated as unchanged. If either tree cannot be
# read the run falls back to the old behaviour and opens the PR: a missed real
# weights bump is far worse than a spurious one.
weights_content="unknown"
if [ -n "${new_weights}" ] && [ "${new_weights}" != "${cur_weights}" ]; then
  wt_old="$(mktemp)"; wt_new="$(mktemp)"
  curl -fsSL --retry 2 "https://huggingface.co/api/models/${WEIGHTS_REPO}/tree/${cur_weights}?recursive=true" -o "${wt_old}" 2>/dev/null || true
  curl -fsSL --retry 2 "https://huggingface.co/api/models/${WEIGHTS_REPO}/tree/${new_weights}?recursive=true" -o "${wt_new}" 2>/dev/null || true
  weights_content="$(python3 - "${MODULE}" "${wt_old}" "${wt_new}" <<'PY' 2>/dev/null || true
import json, re, sys, fnmatch, hashlib

module_path, old_p, new_p = sys.argv[1:4]


def load(p):
    try:
        with open(p) as fh:
            data = json.load(fh)
    except Exception:
        return None
    if not isinstance(data, list):
        return None
    out = {}
    for e in data:
        if e.get("type") != "file":
            continue
        path = e.get("path", "")
        # Only what the engine reads. Repo docs are not part of what the pin
        # means, so a docs-only commit must not move it.
        if not (path.endswith(".hgn") or path.startswith("tokenizer/")):
            continue
        oid = (e.get("lfs") or {}).get("oid") or e.get("blobId") or ""
        size = (e.get("lfs") or {}).get("size") or e.get("size") or 0
        out[path] = f"{oid}:{size}"
    return out


with open(module_path, encoding="utf-8") as fh:
    text = fh.read()
m = re.search(r'options\.exclude\s*=\s*lib\.mkOption\s*\{.*?default\s*=\s*\[(.*?)\];', text, re.S)
pats = re.findall(r'"([^"]*)"', m.group(1)) if m else []


def fingerprint(files):
    items = sorted(
        f"{p}={v}"
        for p, v in files.items()
        if not any(fnmatch.fnmatch(p, pat) for pat in pats)
    )
    return hashlib.sha256("\n".join(items).encode()).hexdigest(), len(items)


old, new = load(old_p), load(new_p)
if old is None or new is None or not old or not new:
    print("unknown")
    sys.exit(0)
print("same" if fingerprint(old)[0] == fingerprint(new)[0] else "different")
PY
)"
  rm -f "${wt_old}" "${wt_new}"
fi
[ -n "${weights_content}" ] || weights_content="unknown"
out weights_content "${weights_content}"

# --- 5. what actually changed -----------------------------------------------
# Each artifact is judged on its own, so a weights-only release still opens
# a PR. An unreachable HuggingFace API is NOT counted as a change: we
# cannot claim a sha we could not read, and a false positive would open a PR
# that patches nothing. It is surfaced in the body instead.
image_changed="false"
if [ "${cur}" != "${new}" ] || { [ -n "${digest}" ] && [ "${cur_digest}" != "${digest}" ]; }; then
  image_changed="true"
fi

weights_changed="false"
weights_noop="false"
if [ -n "${new_weights}" ] && [ "${new_weights}" != "${cur_weights}" ]; then
  if [ "${weights_content}" = "same" ]; then
    # The commit moved; nothing the engine loads did. Say so loudly in the log,
    # because the alternative reading of "no PR opened" is "the bot is broken".
    weights_noop="true"
    echo "weights ${cur_weights} -> ${new_weights} moves no byte the engine reads (docs-only upstream commit); leaving the pin at ${cur_weights}."
  else
    weights_changed="true"
  fi
fi

out image_changed "${image_changed}"
out weights_changed "${weights_changed}"
out weights_noop "${weights_noop}"

if [ "${image_changed}" = "false" ] && [ "${weights_changed}" = "false" ]; then
  echo "already current: image ${cur}, weights ${cur_weights:-unpinned}."
  out changed "false"
  exit 0
fi

reason="none"
if [ "${image_changed}" = "true" ]; then
  # A tag that moved under us is a change worth a PR even when the version
  # string is unchanged -- the reviewed artifact and the registry's current
  # one are different bytes.
  if [ "${cur}" = "${new}" ]; then
    reason="tag-moved"
  else
    reason="bump"
  fi
fi
out reason "${reason}"

# --- 6. upstream contract diff (image only) ---------------------------------
# GitHub's compare API gives per-file patches without a clone. The git tags
# are `v`-prefixed while the image tags are not.
#
# `patch` is null when a file is too large for the API, and the whole
# compare 404s if a tag is missing (e.g. a pin that predates upstream
# tagging), so every fetch here is optional and degrades to "could not
# fetch". Skipped entirely on a weights-only bump: there is no image diff.
compose_patch=""
flags_patch=""
changelog=""
commit_list=""

if [ "${image_changed}" = "true" ]; then
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

  # CHANGELOG slice: headings are `## <version>` (unprefixed). Take
  # everything from the new version down to (not including) the currently
  # pinned one.
  changelog="$(curl -fsSL --retry 3 \
    "https://raw.githubusercontent.com/${UPSTREAM_REPO}/v${new}/CHANGELOG.md" \
    2>/dev/null | awk -v new="## ${new}" -v cur="## ${cur}" '
      index($0, new) == 1 { keep = 1 }
      keep && index($0, cur) == 1 { exit }
      keep { print }
    ' | head_n 200 || true)"
fi

# --- 7. patch the module ----------------------------------------------------
# Each artifact is patched only if it moved, so a weights-only PR carries no
# image change and vice versa.

# Rewrite the whole reference (version and any existing digest) so the pin
# never ends up with a stale digest glued onto a new tag.
if [ "${image_changed}" = "true" ]; then
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
fi

# Rewrite defaultWeightsRevision to the upstream sha we just read. Same
# all-or-nothing discipline: refuse to patch if the pin is not where we
# expect it, rather than silently writing a partial change.
if [ "${weights_changed}" = "true" ]; then
python3 - "${MODULE}" "${new_weights}" <<'PY'
import re, sys

path, rev = sys.argv[1], sys.argv[2]
pattern = r'(defaultWeightsRevision\s*=\s*)"[0-9a-f]{40}"'
replacement = rf'\1"{rev}"'

with open(path, encoding="utf-8") as fh:
    text = fh.read()

new_text, count = re.subn(pattern, replacement, text)
if count == 0:
    sys.exit(f"no defaultWeightsRevision pin found in {path}; refusing to patch")

with open(path, "w", encoding="utf-8") as fh:
    fh.write(new_text)
print(f"patched {count} occurrence(s) -> defaultWeightsRevision = {rev}")
PY
fi

out changed "true"

short_weights="${new_weights:0:7}"
if [ "${image_changed}" = "true" ] && [ "${weights_changed}" = "true" ]; then
  out branch "bump/halogen-image-${new}-weights-${short_weights}"
  out pr_title "bump: halogen-flash-server ${cur} -> ${new}, weights -> ${short_weights}"
elif [ "${image_changed}" = "true" ]; then
  out branch "bump/halogen-image-${new}"
  out pr_title "bump: halogen-flash-server ${cur} -> ${new}"
else
  out branch "bump/halogen-weights-${short_weights}"
  out pr_title "bump: halogen weights -> ${short_weights}"
fi

# --- 7b. re-derive download exclusions on a weights bump --------------------
# The exclude list is a curated denylist of large unused checkpoints; it must
# be revisited whenever the weights revision moves, or a bump silently pulls
# the whole repo (286 GiB) and overflows the volume. This automates that hop:
# it projects the download against the new tree, drops patterns that match
# nothing, and auto-excludes brand-new large files. It never auto-excludes a
# file already downloaded at the previous revision (v2/ngram are huge but
# needed) -- only files absent from the old tree, which a human confirms the
# engine does not need before merging. Runs only when the revision moved: on an
# image-only bump the tree is unchanged and re-patching would open a no-op PR.
exclude_changed="false"
exclude_report=""
if [ "${weights_changed}" = "true" ] && [ -n "${new_weights}" ]; then
  EXCLUDE_MIN_GIB="${EXCLUDE_MIN_GIB:-2}"
  DOWNLOAD_BUDGET_GIB="${DOWNLOAD_BUDGET_GIB:-200}"
  old_tree="$(mktemp)"; new_tree="$(mktemp)"; excl_report="$(mktemp)"; excl_vars="$(mktemp)"
  curl -fsSL --retry 2 "https://huggingface.co/api/models/${WEIGHTS_REPO}/tree/${cur_weights}?recursive=true" -o "${old_tree}" 2>/dev/null || true
  curl -fsSL --retry 2 "https://huggingface.co/api/models/${WEIGHTS_REPO}/tree/${new_weights}?recursive=true" -o "${new_tree}" 2>/dev/null || true

  if python3 - "${MODULE}" "${old_tree}" "${new_tree}" "${EXCLUDE_MIN_GIB}" "${DOWNLOAD_BUDGET_GIB}" "${excl_report}" > "${excl_vars}" 2>"${excl_vars}.err" <<'PY'
import json, re, sys, fnmatch

# argv: module old_tree new_tree min_gib budget report_path
module_path, old_tree_p, new_tree_p, min_gib, budget, report_p = sys.argv[1:7]
min_gib = float(min_gib); budget = float(budget)
GIB = 1024 ** 3


def load(p):
    try:
        with open(p) as fh:
            data = json.load(fh)
    except Exception:
        return None
    if not isinstance(data, list):
        return None
    out = []
    for e in data:
        if e.get("type") != "file":
            continue
        size = (e.get("lfs") or {}).get("size") or e.get("size") or 0
        out.append((e.get("path", ""), int(size)))
    return out


def matched(path, pats):
    return any(fnmatch.fnmatch(path, p) for p in pats)


def gib(s):
    return f"{s / GIB:.1f} GiB"


new_files = load(new_tree_p)
old_files = load(old_tree_p)

with open(module_path, encoding="utf-8") as fh:
    text = fh.read()
m = re.search(r'options\.exclude\s*=\s*lib\.mkOption\s*\{.*?default\s*=\s*\[(.*?)\];', text, re.S)
cur_patterns = re.findall(r'"([^"]*)"', m.group(1)) if m else []

if new_files is None:
    print("exclude_changed=false")
    open(report_p, "w").write("")
    sys.exit(0)

# stale: current patterns matching nothing in the new tree
stale = [p for p in cur_patterns if not any(fnmatch.fnmatch(fp, p) for fp, _ in new_files)]

# previously-downloaded names: old tree minus current excludes. If the old tree
# is unavailable, treat every new file as known so nothing is auto-added.
if old_files is not None:
    old_all = {p for p, _ in old_files}
else:
    old_all = {p for p, _ in new_files}

min_bytes = min_gib * GIB
added = [p for p, s in new_files
         if not matched(p, cur_patterns) and s >= min_bytes and p not in old_all]

kept = [p for p in cur_patterns if p not in stale]
final = kept + sorted(set(added))
exclude_changed = "true" if sorted(final) != sorted(cur_patterns) else "false"

dl = [(p, s) for p, s in new_files if not matched(p, final)]
ex = [(p, s) for p, s in new_files if matched(p, final)]
dl_gib = sum(s for _, s in dl) / GIB
ex_gib = sum(s for _, s in ex) / GIB
over = dl_gib > budget
review = "true" if (added or over or stale) else "false"

if exclude_changed == "true":
    # Reuse the anchored regex (NOT a bare find("default")): the option's
    # comment mentions "defaultRepo"/"set [ ]", which a naive find matches and
    # then corrupts. This matches the real `default = [ ... ];` only.
    m2 = re.search(r'(options\.exclude\s*=\s*lib\.mkOption\s*\{.*?default\s*=\s*)(\[.*?\];)', text, re.S)
    if not m2:
        sys.exit("could not locate options.exclude default to patch")
    g1 = m2.group(1)
    dpos = g1.rfind("default")
    indent = g1[g1.rfind("\n", 0, dpos) + 1:dpos]
    if final:
        inner = "[\n" + "".join(f'{indent}  "{p}"\n' for p in final) + f"{indent}];"
    else:
        inner = "[ ];"
    text = text[:m2.start(2)] + inner + text[m2.end(2):]
    with open(module_path, "w", encoding="utf-8") as fh:
        fh.write(text)

print(f"exclude_changed={exclude_changed}")
print(f"download_gib={dl_gib:.1f}")
print(f"excluded_gib={ex_gib:.1f}")
print(f"exclude_added={len(added)}")
print(f"exclude_dropped={len(stale)}")
print(f"exclude_over_budget={'true' if over else 'false'}")
print(f"exclude_review={review}")

lines = ["### Download exclusions (re-derived for the new tree)", "",
         f"Projected download with the final exclude list: **{dl_gib:.1f} GiB** "
         f"(skipped {ex_gib:.1f} GiB). Budget {budget:.0f} GiB."]
if over:
    lines += ["", f"> **Over budget**: projected download {dl_gib:.1f} GiB exceeds "
                  f"{budget:.0f} GiB. Largest non-excluded files are candidates to exclude."]
lines += ["", f"- exclude list: `{', '.join(cur_patterns) or '(empty)'}` -> "
              f"`{', '.join(final) or '(empty)'}`"]
if added:
    lines += ["", f"- **auto-excluded {len(added)} new large file(s)** (in the new tree, "
                  f"absent from the previous one, >= {min_gib:g} GiB). Confirm the engine "
                  f"does NOT need these before merging:"]
    for p, s in sorted([(p, s) for p, s in new_files if p in added], key=lambda x: -x[1]):
        lines.append(f"    - `{p}` ({gib(s)})")
if stale:
    lines += ["", f"- dropped stale pattern(s) matching nothing in the new tree: `{', '.join(stale)}`"]
lines += ["", "<details><summary>per-file projection</summary>", "",
          "| file | size | action |", "|---|---|---|"]
for p, s in sorted(new_files, key=lambda x: -x[1]):
    lines.append(f"| `{p}` | {gib(s)} | {'skip' if matched(p, final) else 'fetch'} |")
lines += ["", "</details>"]
open(report_p, "w").write("\n".join(lines) + "\n")
PY
  then
    while IFS='=' read -r k v; do
      case "${k}" in
        exclude_changed) exclude_changed="${v}" ;;
        download_gib) download_gib="${v}" ;;
        excluded_gib) excluded_gib="${v}" ;;
        exclude_added) exclude_added="${v}" ;;
        exclude_dropped) exclude_dropped="${v}" ;;
        exclude_over_budget) exclude_over_budget="${v}" ;;
        exclude_review) exclude_review="${v}" ;;
      esac
    done < "${excl_vars}"
    [ -s "${excl_report}" ] && exclude_report="$(cat "${excl_report}")"
  else
    echo "::warning::could not re-derive download exclusions: $(cat "${excl_vars}.err")" >&2
  fi
  rm -f "${old_tree}" "${new_tree}" "${excl_report}" "${excl_vars}" "${excl_vars}.err"

  out exclude_changed "${exclude_changed}"
  out download_gib "${download_gib:-}"
  out excluded_gib "${excluded_gib:-}"
  out exclude_added "${exclude_added:-0}"
  out exclude_dropped "${exclude_dropped:-0}"
  out exclude_over_budget "${exclude_over_budget:-false}"
  out exclude_review "${exclude_review:-false}"
fi

# --- 8. PR body -------------------------------------------------------------
{
  echo "## What moved"
  echo
  echo "| artifact | pinned before | upstream now |"
  echo "|---|---|---|"
  if [ "${image_changed}" = "true" ]; then
    echo "| image | \`${IMAGE}:${cur}${cur_digest:+@${cur_digest}}\` | \`${IMAGE}:${new}${digest:+@${digest}}\` |"
  else
    echo "| image | \`${IMAGE}:${cur}${cur_digest:+@${cur_digest}}\` | *unchanged* |"
  fi
  if [ "${weights_changed}" = "true" ]; then
    echo "| weights | \`${cur_weights:-unpinned}\` | \`${new_weights}\` (${hf_modified:-unknown}) |"
  else
    echo "| weights | \`${cur_weights:-unpinned}\` | *unchanged* |"
  fi

  if [ "${reason}" = "tag-moved" ]; then
    echo
    echo "> **Upstream moved the \`${new}\` tag** -- same version string, different"
    echo "> bytes. Whatever is running was built from the old manifest, so this"
    echo "> diff is not the one that produced the current deployment."
  fi
  if [ "${image_changed}" = "true" ] && [ -z "${digest}" ]; then
    echo
    echo "> **Digest unavailable** (registry fetch failed): the new pin is tag-only."
    echo "> That is not safe with \`pull.enable\` -- the module warns about it."
    echo "> Re-run once the registry is reachable to get a pinned reference."
  fi
  if [ -z "${new_weights}" ]; then
    echo
    echo "> **Weights probe failed**: the HuggingFace API was unreachable, so the"
    echo "> weights were NOT checked. This PR only covers the image. Re-run to"
    echo "> verify the weights revision."
  fi
  if [ "${weights_noop}" = "true" ]; then
    echo
    echo "> **Weights commit seen and deliberately not taken**: \`${WEIGHTS_REPO}\`"
    echo "> moved to \`${new_weights}\`, but every \`.hgn\` and every tokenizer file"
    echo "> carries the same sha256 as the pinned \`${cur_weights}\` -- the commit is"
    echo "> documentation only. Patching the pin would re-fetch the full 112.1 GiB"
    echo "> into a second version dir to end up with bytes the running server"
    echo "> already has, so this PR covers the image alone."
  fi

  if [ "${weights_changed}" = "true" ]; then
    echo
    echo "### Weights"
    echo
    echo "Upstream \`${WEIGHTS_REPO}\` moved to \`${new_weights}\`"
    echo "(\`${hf_modified:-unknown}\`); the module pinned \`${cur_weights:-nothing}\`."
    echo
    echo "Merging this changes the model, not just the server. The next service"
    echo "start on a host that has not seen this revision fetches **~118 GiB** in"
    echo "\`ExecStartPre\`, which can run for hours while the unit sits in"
    echo "\"activating\". The deploy needs a health-gate warmup window that outlasts"
    echo "it (\`cominGitOps.healthGate.halogenWarmupSec\`; llm01 sets 4h) or the"
    echo "gate rolls the deploy back mid-download."
    echo
    echo "- [ ] New checkpoint is compatible with the pinned image"
    echo "      \`${IMAGE}:${new}\`"
    echo "- [ ] Target host's warmup window covers a full fetch"
    if [ -n "${exclude_report}" ]; then
      echo
      printf '%s\n' "${exclude_report}"
    fi
  fi

  if [ "${image_changed}" = "true" ]; then
    echo
    echo "### Image"
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
  fi

  echo
  echo "Opened automatically by \`.github/workflows/bump-image.yml\`. **Nothing was"
  echo "pulled, deployed, or restarted by this PR** -- merging is the human gate,"
  echo "and with \`pull.enable\` on the host pulls the pinned digest itself at"
  echo "service start."

  if [ "${image_changed}" = "true" ]; then
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
  fi
} >"${BODY_FILE}"

echo "PR body written to ${BODY_FILE}"
