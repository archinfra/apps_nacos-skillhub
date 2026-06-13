#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="nacos-skillhub"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(cat "${ROOT_DIR}/VERSION" 2>/dev/null || echo "0.1.0")"
DIST_DIR="${ROOT_DIR}/dist"
BUILD_DIR="${ROOT_DIR}/.build-payload"
PAYLOAD_TGZ="${ROOT_DIR}/payload.tar.gz"
IMAGE_JSON="${ROOT_DIR}/images/image.json"
INSTALL_SH="${ROOT_DIR}/install.sh"

usage() {
  cat <<'EOF'
Usage:
  bash build.sh --arch amd64|arm64|all [--no-pull]

Examples:
  bash build.sh --arch amd64
  bash build.sh --arch arm64
  bash build.sh --arch all

What it does:
  - reads images/image.json
  - pulls or builds images for the selected arch
  - saves images to payload/images/*.tar
  - writes payload/images/image-index.tsv
  - embeds payload into install.sh and emits dist/*.run + *.sha256
EOF
}

die() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

ARCH=""
NO_PULL="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCH="${2:-}"; shift 2 ;;
    --no-pull) NO_PULL="true"; shift ;;
    -h|--help|help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -n "${ARCH}" ]] || die "--arch is required"
[[ "${ARCH}" =~ ^(amd64|arm64|all)$ ]] || die "--arch must be amd64, arm64, or all"

need_cmd docker
need_cmd tar
need_cmd sha256sum
need_cmd python3

[[ -f "${INSTALL_SH}" ]] || die "install.sh not found"
[[ -f "${IMAGE_JSON}" ]] || die "images/image.json not found"
python3 -m json.tool "${IMAGE_JSON}" >/dev/null || die "images/image.json is invalid JSON"
[[ "$(grep -c '^__PAYLOAD_BELOW__$' "${INSTALL_SH}" || true)" == "1" ]] || die "install.sh must contain exactly one standalone __PAYLOAD_BELOW__ marker"

select_arches() {
  if [[ "${ARCH}" == "all" ]]; then
    printf '%s\n' amd64 arm64
  else
    printf '%s\n' "${ARCH}"
  fi
}

json_query() {
  local arch="$1"
  python3 - "$IMAGE_JSON" "$arch" <<'PY'
import json, sys
path, arch = sys.argv[1], sys.argv[2]
with open(path, 'r', encoding='utf-8') as f:
    data = json.load(f)
items = [x for x in data if x.get('arch') == arch]
if not items:
    print(f'No images found for arch={arch}', file=sys.stderr)
    sys.exit(2)
for x in items:
    name = x.get('name', '')
    platform = x.get('platform', f'linux/{arch}')
    pull = x.get('pull', '')
    dockerfile = x.get('dockerfile', '')
    tag = x.get('tag', '')
    tar_name = x.get('tar', '')
    if not tag or not tar_name:
        print(f'Missing tag/tar in entry: {x}', file=sys.stderr)
        sys.exit(3)
    if bool(pull) == bool(dockerfile):
        print(f'Exactly one of pull/dockerfile is required: {x}', file=sys.stderr)
        sys.exit(4)
    print('|'.join([name, tar_name, pull or tag, tag, platform, pull, dockerfile]))
PY
}

build_one_arch() {
  local arch="$1"
  local payload="${BUILD_DIR}/${arch}"
  local image_dir="${payload}/images"
  local out_run="${DIST_DIR}/${APP_NAME}-installer-${arch}.run"

  info "Building ${APP_NAME} ${VERSION} for arch=${arch}"
  rm -rf "${payload}" "${PAYLOAD_TGZ}"
  mkdir -p "${image_dir}" "${payload}/manifests" "${DIST_DIR}"

  cp "${IMAGE_JSON}" "${image_dir}/image.json"
  cp -a "${ROOT_DIR}/manifests/." "${payload}/manifests/"
  cp "${ROOT_DIR}/VERSION" "${payload}/VERSION"
  [[ -f "${ROOT_DIR}/README.md" ]] && cp "${ROOT_DIR}/README.md" "${payload}/README.md"

  : > "${image_dir}/image-index.tsv"
  echo 'name|tar_name|load_ref|default_target_ref|platform|pull|dockerfile' > "${image_dir}/image-index.tsv"

  while IFS='|' read -r name tar_name load_ref default_target_ref platform pull dockerfile; do
    [[ -n "${tar_name}" ]] || continue
    info "Image: name=${name} platform=${platform} tar=${tar_name}"
    if [[ -n "${dockerfile}" ]]; then
      docker buildx build --load --platform "${platform}" -t "${default_target_ref}" -f "${ROOT_DIR}/${dockerfile}" "${ROOT_DIR}"
      load_ref="${default_target_ref}"
    else
      if [[ "${NO_PULL}" != "true" ]]; then
        docker pull --platform "${platform}" "${pull}"
      fi
      load_ref="${pull}"
    fi
    docker save -o "${image_dir}/${tar_name}" "${load_ref}"
    echo "${name}|${tar_name}|${load_ref}|${default_target_ref}|${platform}|${pull}|${dockerfile}" >> "${image_dir}/image-index.tsv"
  done < <(json_query "${arch}")

  (cd "${payload}" && tar -czf "${PAYLOAD_TGZ}" .)
  tar -tzf "${PAYLOAD_TGZ}" >/dev/null

  cat "${INSTALL_SH}" "${PAYLOAD_TGZ}" > "${out_run}"
  chmod +x "${out_run}"
  sha256sum "${out_run}" > "${out_run}.sha256"

  info "Generated: ${out_run}"
  info "Checksum:  ${out_run}.sha256"
}

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}" "${DIST_DIR}"

while read -r a; do
  build_one_arch "$a"
done < <(select_arches)

info "Done. Files in ${DIST_DIR}:"
ls -lh "${DIST_DIR}"
