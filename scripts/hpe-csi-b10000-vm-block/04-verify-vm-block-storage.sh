#!/usr/bin/env bash
set -euo pipefail

: "${HPE_VM_BLOCK_STORAGECLASS:=hpe-b10000-vm-block}"
: "${TEST_NAMESPACE:=hpe-csi-test}"
: "${TEST_PVC_NAME:=hpe-b10000-vm-block-test}"
: "${TEST_PVC_SIZE:=10Gi}"
: "${DELETE_TEST_RESOURCES:=false}"

if ! command -v oc >/dev/null 2>&1; then
  echo "ERROR: oc CLI not found in PATH" >&2
  exit 1
fi

oc get storageclass "${HPE_VM_BLOCK_STORAGECLASS}" >/dev/null

if ! oc get namespace "${TEST_NAMESPACE}" >/dev/null 2>&1; then
  oc create namespace "${TEST_NAMESPACE}"
fi

echo "Creating test RWX raw block PVC ${TEST_NAMESPACE}/${TEST_PVC_NAME}..."
oc apply -f - <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${TEST_PVC_NAME}
  namespace: ${TEST_NAMESPACE}
spec:
  accessModes:
  - ReadWriteMany
  volumeMode: Block
  storageClassName: ${HPE_VM_BLOCK_STORAGECLASS}
  resources:
    requests:
      storage: ${TEST_PVC_SIZE}
YAML

echo "Waiting for PVC to bind..."
for _ in $(seq 1 120); do
  PHASE="$(oc -n "${TEST_NAMESPACE}" get pvc "${TEST_PVC_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [[ "${PHASE}" == "Bound" ]]; then
    break
  fi
  sleep 5
done

PHASE="$(oc -n "${TEST_NAMESPACE}" get pvc "${TEST_PVC_NAME}" -o jsonpath='{.status.phase}')"
if [[ "${PHASE}" != "Bound" ]]; then
  echo "ERROR: PVC did not bind. Current PVC state:" >&2
  oc -n "${TEST_NAMESPACE}" describe pvc "${TEST_PVC_NAME}" >&2
  exit 1
fi

PV_NAME="$(oc -n "${TEST_NAMESPACE}" get pvc "${TEST_PVC_NAME}" -o jsonpath='{.spec.volumeName}')"
echo "PVC is Bound to PV ${PV_NAME}"
oc -n "${TEST_NAMESPACE}" get pvc "${TEST_PVC_NAME}" -o wide
oc get pv "${PV_NAME}" -o wide

if [[ "${DELETE_TEST_RESOURCES}" == "true" ]]; then
  echo "Deleting test PVC and namespace because DELETE_TEST_RESOURCES=true..."
  oc -n "${TEST_NAMESPACE}" delete pvc "${TEST_PVC_NAME}"
  oc delete namespace "${TEST_NAMESPACE}"
else
  echo "Leaving test resources in place. Delete them with:"
  echo "  oc -n ${TEST_NAMESPACE} delete pvc ${TEST_PVC_NAME}"
fi
