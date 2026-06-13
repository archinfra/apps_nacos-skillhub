#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"
bash -n build.sh install.sh
python3 -m json.tool images/image.json >/dev/null
grep -q '^__PAYLOAD_BELOW__$' install.sh
printf '[OK] static verification passed\n'
