#!/usr/bin/env bash
set -euo pipefail

: "${HPE_CSI_NAMESPACE:=hpe-storage}"
: "${B10000_BACKEND_SECRET:=hpe-b10000-backend}"
: "${B10000_CPG:?Set B10000_CPG}"
: "${B10000_SNAP_CPG:=${B10000_CPG}}"
: "${B10000_ACCESS_PROTOCOL:=iscsi}"
: "${B10000_PROVISIONING_TYPE:=tpvv}"
: "${B10000_HOST_SEES_VLUN:=true}"
: "${HPE_VM_BLOCK_STORAGECLASS:=hpe-b10000-vm-block}"
: "${MAKE_DEFAULT_STORAGECLASS:=false}"

if ! command -v oc >/dev/null 2>&1; then
  echo "ERROR: oc CLI not found in PATH" >&2
  exit 1
fi

oc -n "${HPE_CSI_NAMESPACE}" get secret "${B10000_BACKEND_SECRET}" >/dev/null

echo "Creating/updating StorageClass ${HPE_VM_BLOCK_STORAGECLASS}..."
oc apply -f - <<YAML
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${HPE_VM_BLOCK_STORAGECLASS}
  annotations:
    storageclass.kubernetes.io/is-default-class: "${MAKE_DEFAULT_STORAGECLASS}"
provisioner: csi.hpe.com
parameters:
  csi.storage.k8s.io/controller-expand-secret-name: ${B10000_BACKEND_SECRET}
  csi.storage.k8s.io/controller-expand-secret-namespace: ${HPE_CSI_NAMESPACE}
  csi.storage.k8s.io/controller-publish-secret-name: ${B10000_BACKEND_SECRET}
  csi.storage.k8s.io/controller-publish-secret-namespace: ${HPE_CSI_NAMESPACE}
  csi.storage.k8s.io/node-publish-secret-name: ${B10000_BACKEND_SECRET}
  csi.storage.k8s.io/node-publish-secret-namespace: ${HPE_CSI_NAMESPACE}
  csi.storage.k8s.io/node-stage-secret-name: ${B10000_BACKEND_SECRET}
  csi.storage.k8s.io/node-stage-secret-namespace: ${HPE_CSI_NAMESPACE}
  csi.storage.k8s.io/provisioner-secret-name: ${B10000_BACKEND_SECRET}
  csi.storage.k8s.io/provisioner-secret-namespace: ${HPE_CSI_NAMESPACE}
  csi.storage.k8s.io/fstype: xfs
  accessProtocol: ${B10000_ACCESS_PROTOCOL}
  description: HPE B10000 raw block StorageClass for OpenShift Virtualization VM disks
  cpg: ${B10000_CPG}
  snapCpg: ${B10000_SNAP_CPG}
  hostSeesVLUN: "${B10000_HOST_SEES_VLUN}"
  provisioningType: ${B10000_PROVISIONING_TYPE}
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
YAML

if oc get crd storageprofiles.cdi.kubevirt.io >/dev/null 2>&1; then
  echo "Waiting for CDI StorageProfile ${HPE_VM_BLOCK_STORAGECLASS} to exist..."
  for _ in $(seq 1 60); do
    if oc get storageprofile "${HPE_VM_BLOCK_STORAGECLASS}" >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done

  echo "Creating/updating StorageProfile ${HPE_VM_BLOCK_STORAGECLASS}..."
  oc apply -f - <<YAML
apiVersion: cdi.kubevirt.io/v1beta1
kind: StorageProfile
metadata:
  name: ${HPE_VM_BLOCK_STORAGECLASS}
spec:
  claimPropertySets:
  - accessModes:
    - ReadWriteMany
    volumeMode: Block
  - accessModes:
    - ReadWriteOnce
    volumeMode: Block
  cloneStrategy: csi-clone
YAML
else
  echo "WARNING: storageprofiles.cdi.kubevirt.io CRD not found."
  echo "Install OpenShift Virtualization/CDI, then rerun this script to configure the StorageProfile."
fi

echo "StorageClass:"
oc get storageclass "${HPE_VM_BLOCK_STORAGECLASS}"

if oc get crd storageprofiles.cdi.kubevirt.io >/dev/null 2>&1; then
  echo "StorageProfile:"
  oc get storageprofile "${HPE_VM_BLOCK_STORAGECLASS}" -o yaml
fi
