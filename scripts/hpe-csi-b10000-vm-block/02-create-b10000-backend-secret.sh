#!/usr/bin/env bash
set -euo pipefail

: "${HPE_CSI_NAMESPACE:=hpe-storage}"
: "${B10000_BACKEND_SECRET:=hpe-b10000-backend}"
: "${B10000_MGMT_ENDPOINT:?Set B10000_MGMT_ENDPOINT, for example 192.0.2.110:443}"
: "${B10000_USERNAME:?Set B10000_USERNAME}"
: "${B10000_PASSWORD:?Set B10000_PASSWORD}"

if ! command -v oc >/dev/null 2>&1; then
  echo "ERROR: oc CLI not found in PATH" >&2
  exit 1
fi

oc get namespace "${HPE_CSI_NAMESPACE}" >/dev/null

echo "Creating/updating backend Secret ${B10000_BACKEND_SECRET} in ${HPE_CSI_NAMESPACE}..."
oc -n "${HPE_CSI_NAMESPACE}" create secret generic "${B10000_BACKEND_SECRET}" \
  --from-literal=serviceName="alletrastoragemp-csp-svc" \
  --from-literal=servicePort="8080" \
  --from-literal=backend="${B10000_MGMT_ENDPOINT}" \
  --from-literal=username="${B10000_USERNAME}" \
  --from-literal=password="${B10000_PASSWORD}" \
  --dry-run=client -o yaml | oc apply -f -

oc -n "${HPE_CSI_NAMESPACE}" get secret "${B10000_BACKEND_SECRET}"
