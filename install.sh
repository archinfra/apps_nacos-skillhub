#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="nacos-skillhub"
DEFAULT_NAMESPACE="nacos-system"
DEFAULT_REGISTRY="sealos.hub:5000/kube4"
DEFAULT_WAIT_TIMEOUT="300s"
DEFAULT_SERVICE_TYPE="ClusterIP"
DEFAULT_AUTH_TOKEN="NacosStandaloneOfflineTokenChangeMe1234567890"
DEFAULT_IDENTITY_KEY="serverIdentity"
DEFAULT_IDENTITY_VALUE="security"

WORKDIR="${TMPDIR:-/tmp}/${APP_NAME}-installer-$$"
IMAGE_INDEX="${WORKDIR}/images/image-index.tsv"
TARGET_IMAGE_FILE="${WORKDIR}/.target-images.env"

ACTION="help"
NAMESPACE="${DEFAULT_NAMESPACE}"
REGISTRY="${DEFAULT_REGISTRY}"
REGISTRY_USER=""
REGISTRY_PASS=""
SKIP_IMAGE_PREPARE="false"
YES="false"
WAIT_TIMEOUT="${DEFAULT_WAIT_TIMEOUT}"
SERVICE_TYPE="${DEFAULT_SERVICE_TYPE}"
NODEPORT_CONSOLE=""
NODEPORT_CLIENT=""
NODEPORT_GRPC=""
AUTH_TOKEN="${DEFAULT_AUTH_TOKEN}"
IDENTITY_KEY="${DEFAULT_IDENTITY_KEY}"
IDENTITY_VALUE="${DEFAULT_IDENTITY_VALUE}"
STORAGE_CLASS=""
DATA_STORAGE_SIZE="5Gi"
LOGS_STORAGE_SIZE="2Gi"
DELETE_PVC="false"

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

usage() {
  cat <<EOF
${APP_NAME} offline installer

Usage:
  ./nacos-skillhub-installer-amd64.run install [options]
  ./nacos-skillhub-installer-amd64.run uninstall [options]
  ./nacos-skillhub-installer-amd64.run status [options]
  ./nacos-skillhub-installer-amd64.run help

Actions:
  install      Extract payload, load/tag/push image, render manifests, kubectl apply
  uninstall    Delete StatefulSet/Service/Secret. PVC is kept unless --delete-pvc is set
  status       Show key Kubernetes resources
  help         Show this help

Install options:
  -n, --namespace <ns>              Namespace. Default: ${DEFAULT_NAMESPACE}
  --registry <repo-prefix>          Target internal registry prefix. Default: ${DEFAULT_REGISTRY}
  --registry-user <user>            Target registry username
  --registry-pass <pass>            Target registry password
  --skip-image-prepare              Skip docker load/tag/push, but still render image address
  --auth-token <token>              NACOS_AUTH_TOKEN. Default is demo-only; change in production
  --identity-key <key>              NACOS_AUTH_IDENTITY_KEY. Default: ${DEFAULT_IDENTITY_KEY}
  --identity-value <value>          NACOS_AUTH_IDENTITY_VALUE. Default: ${DEFAULT_IDENTITY_VALUE}
  --service-type ClusterIP|NodePort Service type. Default: ClusterIP
  --nodeport-console <port>         Optional NodePort for 8080
  --nodeport-client <port>          Optional NodePort for 8848
  --nodeport-grpc <port>            Optional NodePort for 9848
  --storage-class <name>            Optional PVC storageClassName
  --data-storage-size <size>        PVC size for /home/nacos/data. Default: 5Gi
  --logs-storage-size <size>        PVC size for /home/nacos/logs. Default: 2Gi
  --wait-timeout <duration>         kubectl rollout wait timeout. Default: 300s
  -y, --yes                         Non-interactive confirmation

Uninstall options:
  -n, --namespace <ns>
  --delete-pvc                      Also delete PVC data/logs. Dangerous
  -y, --yes

Examples:
  ./nacos-skillhub-installer-amd64.run install \\
    --registry sealos.hub:5000/kube4 \\
    --registry-user admin \\
    --registry-pass '<password>' \\
    -n nacos-system \\
    --auth-token '<at-least-32-chars-secret-token>' \\
    --identity-key serverIdentity \\
    --identity-value security \\
    -y

  ./nacos-skillhub-installer-amd64.run status -n nacos-system
EOF
}

parse_args() {
  if [[ $# -gt 0 ]]; then
    ACTION="$1"; shift
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--namespace) NAMESPACE="${2:-}"; shift 2 ;;
      --registry) REGISTRY="${2:-}"; shift 2 ;;
      --registry-user) REGISTRY_USER="${2:-}"; shift 2 ;;
      --registry-pass) REGISTRY_PASS="${2:-}"; shift 2 ;;
      --skip-image-prepare) SKIP_IMAGE_PREPARE="true"; shift ;;
      --auth-token) AUTH_TOKEN="${2:-}"; shift 2 ;;
      --identity-key) IDENTITY_KEY="${2:-}"; shift 2 ;;
      --identity-value) IDENTITY_VALUE="${2:-}"; shift 2 ;;
      --service-type) SERVICE_TYPE="${2:-}"; shift 2 ;;
      --nodeport-console) NODEPORT_CONSOLE="${2:-}"; shift 2 ;;
      --nodeport-client) NODEPORT_CLIENT="${2:-}"; shift 2 ;;
      --nodeport-grpc) NODEPORT_GRPC="${2:-}"; shift 2 ;;
      --storage-class) STORAGE_CLASS="${2:-}"; shift 2 ;;
      --data-storage-size) DATA_STORAGE_SIZE="${2:-}"; shift 2 ;;
      --logs-storage-size) LOGS_STORAGE_SIZE="${2:-}"; shift 2 ;;
      --wait-timeout) WAIT_TIMEOUT="${2:-}"; shift 2 ;;
      --delete-pvc) DELETE_PVC="true"; shift ;;
      -y|--yes) YES="true"; shift ;;
      -h|--help|help) ACTION="help"; shift ;;
      *) die "Unknown argument: $1" ;;
    esac
  done

  [[ -n "${NAMESPACE}" ]] || die "namespace cannot be empty"
  [[ -n "${REGISTRY}" ]] || die "registry cannot be empty"
  [[ "${SERVICE_TYPE}" =~ ^(ClusterIP|NodePort)$ ]] || die "--service-type must be ClusterIP or NodePort"
}

confirm_or_die() {
  [[ "${YES}" == "true" ]] && return 0
  read -r -p "$1 [y/N] " ans
  [[ "${ans}" == "y" || "${ans}" == "Y" ]] || die "Cancelled"
}

payload_start_offset() {
  local marker_line payload_offset skip_bytes byte_hex
  marker_line="$(awk '/^__PAYLOAD_BELOW__$/ { print NR; exit }' "$0")"
  [[ -n "${marker_line}" ]] || die "Payload marker not found"
  payload_offset="$(( $(head -n "${marker_line}" "$0" | wc -c | tr -d ' ') + 1 ))"
  skip_bytes=0
  while :; do
    byte_hex="$(dd if="$0" bs=1 skip="$((payload_offset + skip_bytes - 1))" count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')"
    case "${byte_hex}" in
      0a|0d) skip_bytes=$((skip_bytes + 1)) ;;
      "") die "Payload is empty" ;;
      *) break ;;
    esac
  done
  printf '%s\n' "$((payload_offset + skip_bytes))"
}

extract_payload() {
  rm -rf "${WORKDIR}"
  mkdir -p "${WORKDIR}"
  tail -c +"$(payload_start_offset)" "$0" | tar -xzf - -C "${WORKDIR}" || die "Failed to extract payload"
  [[ -f "${IMAGE_INDEX}" ]] || die "Payload is missing images/image-index.tsv"
}

registry_host() {
  local r="${REGISTRY#http://}"
  r="${r#https://}"
  printf '%s\n' "${r%%/*}"
}

image_tail_from_default_ref() {
  local ref="$1"
  printf '%s\n' "${ref##*/}"
}

target_ref_for() {
  local default_ref="$1"
  printf '%s/%s\n' "${REGISTRY%/}" "$(image_tail_from_default_ref "${default_ref}")"
}

prepare_images() {
  need_cmd docker
  : > "${TARGET_IMAGE_FILE}"

  if [[ -n "${REGISTRY_USER}" || -n "${REGISTRY_PASS}" ]]; then
    [[ -n "${REGISTRY_USER}" && -n "${REGISTRY_PASS}" ]] || die "--registry-user and --registry-pass must be provided together"
    log "Docker login: $(registry_host)"
    printf '%s' "${REGISTRY_PASS}" | docker login "$(registry_host)" -u "${REGISTRY_USER}" --password-stdin
  fi

  tail -n +2 "${IMAGE_INDEX}" | while IFS='|' read -r name tar_name load_ref default_target_ref platform pull dockerfile; do
    [[ -n "${tar_name}" ]] || continue
    local target_ref
    target_ref="$(target_ref_for "${default_target_ref}")"
    echo "${name}=${target_ref}" >> "${TARGET_IMAGE_FILE}"

    if [[ "${SKIP_IMAGE_PREPARE}" == "true" ]]; then
      log "Skip image prepare: ${name} -> ${target_ref}"
      continue
    fi

    log "docker load: ${tar_name}"
    docker load -i "${WORKDIR}/images/${tar_name}"
    if [[ "${load_ref}" != "${target_ref}" ]]; then
      log "docker tag: ${load_ref} -> ${target_ref}"
      docker tag "${load_ref}" "${target_ref}"
    fi
    log "docker push: ${target_ref}"
    docker push "${target_ref}"
  done
}

get_target_image() {
  local name="$1"
  awk -F= -v k="${name}" '$1 == k { print $2; exit }' "${TARGET_IMAGE_FILE}"
}

indent_nodeport_line() {
  local port="$1"
  if [[ -n "${port}" ]]; then
    printf '      nodePort: %s\n' "${port}"
  fi
}

storage_class_line() {
  if [[ -n "${STORAGE_CLASS}" ]]; then
    printf '        storageClassName: "%s"\n' "${STORAGE_CLASS}"
  fi
}

render_manifest() {
  local tmpl="${WORKDIR}/manifests/nacos-standalone.yaml.tmpl"
  local out="${WORKDIR}/rendered-nacos.yaml"
  local nacos_image
  nacos_image="$(get_target_image nacos-server)"
  [[ -n "${nacos_image}" ]] || die "Cannot resolve target image for nacos-server"

  python3 - "${tmpl}" "${out}" \
    "${NAMESPACE}" \
    "${nacos_image}" \
    "${AUTH_TOKEN}" \
    "${IDENTITY_KEY}" \
    "${IDENTITY_VALUE}" \
    "${SERVICE_TYPE}" \
    "$(indent_nodeport_line "${NODEPORT_CONSOLE}")" \
    "$(indent_nodeport_line "${NODEPORT_CLIENT}")" \
    "$(indent_nodeport_line "${NODEPORT_GRPC}")" \
    "$(storage_class_line)" \
    "${DATA_STORAGE_SIZE}" \
    "${LOGS_STORAGE_SIZE}" <<'PY'
import sys
from pathlib import Path
(
    tmpl, out, namespace, image, token, identity_key, identity_value,
    service_type, np_console, np_client, np_grpc, storage_line,
    data_size, logs_size
) = sys.argv[1:]
text = Path(tmpl).read_text(encoding='utf-8')
repls = {
    '__NAMESPACE__': namespace,
    '__NACOS_IMAGE__': image,
    '__NACOS_AUTH_TOKEN__': token,
    '__NACOS_AUTH_IDENTITY_KEY__': identity_key,
    '__NACOS_AUTH_IDENTITY_VALUE__': identity_value,
    '__SERVICE_TYPE__': service_type,
    '__NODEPORT_CONSOLE__': np_console.rstrip('\n'),
    '__NODEPORT_CLIENT__': np_client.rstrip('\n'),
    '__NODEPORT_GRPC__': np_grpc.rstrip('\n'),
    '__STORAGE_CLASS_LINE_DATA__': storage_line.rstrip('\n'),
    '__STORAGE_CLASS_LINE_LOGS__': storage_line.rstrip('\n'),
    '__DATA_STORAGE_SIZE__': data_size,
    '__LOGS_STORAGE_SIZE__': logs_size,
}
for k, v in repls.items():
    text = text.replace(k, v)
Path(out).write_text(text, encoding='utf-8')
PY
  printf '%s\n' "${out}"
}

install_action() {
  need_cmd kubectl
  need_cmd python3
  extract_payload
  prepare_images
  local rendered
  rendered="$(render_manifest)"
  log "kubectl apply: ${rendered}"
  kubectl apply -f "${rendered}"
  log "Waiting for StatefulSet rollout"
  kubectl -n "${NAMESPACE}" rollout status statefulset/nacos --timeout="${WAIT_TIMEOUT}"
  status_action_no_extract
  log "Nacos installed. Service: nacos.${NAMESPACE}.svc.cluster.local ports 8080, 8848, 9848"
}

status_action_no_extract() {
  kubectl -n "${NAMESPACE}" get statefulset,pod,svc,pvc -l app.kubernetes.io/instance=nacos-standalone -o wide || true
  kubectl -n "${NAMESPACE}" get secret nacos-auth >/dev/null 2>&1 && echo "[INFO] Secret nacos-auth exists" || true
}

status_action() {
  need_cmd kubectl
  status_action_no_extract
}

uninstall_action() {
  need_cmd kubectl
  confirm_or_die "Uninstall Nacos resources from namespace ${NAMESPACE}? PVC delete=${DELETE_PVC}"
  kubectl -n "${NAMESPACE}" delete statefulset nacos --ignore-not-found=true
  kubectl -n "${NAMESPACE}" delete svc nacos --ignore-not-found=true
  kubectl -n "${NAMESPACE}" delete secret nacos-auth --ignore-not-found=true
  if [[ "${DELETE_PVC}" == "true" ]]; then
    kubectl -n "${NAMESPACE}" delete pvc -l app.kubernetes.io/instance=nacos-standalone --ignore-not-found=true
    kubectl -n "${NAMESPACE}" delete pvc data-nacos-0 logs-nacos-0 --ignore-not-found=true
  else
    warn "PVC kept. Use --delete-pvc if you really want to delete data/logs."
  fi
}

cleanup() {
  rm -rf "${WORKDIR}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

main() {
  parse_args "$@"
  case "${ACTION}" in
    install) install_action ;;
    uninstall) uninstall_action ;;
    status) status_action ;;
    help|-h|--help) usage ;;
    *) die "Unknown action: ${ACTION}" ;;
  esac
}

main "$@"
exit $?

__PAYLOAD_BELOW__
