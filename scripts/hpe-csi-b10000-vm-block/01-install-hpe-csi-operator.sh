#!/usr/bin/env bash
set -euo pipefail

: "${HPE_CSI_NAMESPACE:=hpe-storage}"
: "${HPE_OPERATOR_VERSION:=3.1.0}"

echo "Using namespace: ${HPE_CSI_NAMESPACE}"
echo "Required HPE CSI Operator version: ${HPE_OPERATOR_VERSION}"

if ! command -v oc >/dev/null 2>&1; then
  echo "ERROR: oc CLI not found in PATH" >&2
  exit 1
fi

oc whoami >/dev/null

if ! oc get namespace "${HPE_CSI_NAMESPACE}" >/dev/null 2>&1; then
  oc new-project "${HPE_CSI_NAMESPACE}" --display-name="HPE CSI Operator for OpenShift"
else
  oc project "${HPE_CSI_NAMESPACE}" >/dev/null
fi

echo "Applying HPE CSI OpenShift SCCs..."
oc apply -f https://scod.hpedev.io/csi_driver/partners/redhat_openshift/examples/scc/hpe-csi-scc.yaml

echo "Creating OperatorGroup..."
oc apply -f - <<YAML
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: hpe-csi-driver-for-kubernetes
  namespace: ${HPE_CSI_NAMESPACE}
spec:
  targetNamespaces:
  - ${HPE_CSI_NAMESPACE}
YAML

echo "Creating Subscription with manual approval..."
oc apply -f - <<YAML
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: hpe-csi-operator
  namespace: ${HPE_CSI_NAMESPACE}
spec:
  channel: stable
  installPlanApproval: Manual
  name: hpe-csi-operator
  source: certified-operators
  sourceNamespace: openshift-marketplace
YAML

echo "Waiting for an InstallPlan that resolves to ${HPE_OPERATOR_VERSION}..."
INSTALL_PLAN=""
for _ in $(seq 1 90); do
  while IFS='|' read -r plan csvs; do
    if [[ -n "${plan}" && "${csvs}" == *"${HPE_OPERATOR_VERSION}"* ]]; then
      INSTALL_PLAN="${plan}"
      break
    fi
  done < <(oc -n "${HPE_CSI_NAMESPACE}" get installplan -o jsonpath='{range .items[?(@.spec.approved==false)]}{.metadata.name}{"|"}{.spec.clusterServiceVersionNames}{"\n"}{end}' 2>/dev/null || true)

  if [[ -n "${INSTALL_PLAN}" ]]; then
    break
  fi
  sleep 5
done

if [[ -z "${INSTALL_PLAN}" ]]; then
  echo "ERROR: no unapproved InstallPlan for HPE CSI Operator ${HPE_OPERATOR_VERSION} was found." >&2
  echo "Current InstallPlans:" >&2
  oc -n "${HPE_CSI_NAMESPACE}" get installplan || true
  echo "Do not approve a different version unless it is certified for your target OpenShift release." >&2
  exit 1
fi

echo "Approving InstallPlan: ${INSTALL_PLAN}"
oc -n "${HPE_CSI_NAMESPACE}" patch installplan "${INSTALL_PLAN}" --type merge -p '{"spec":{"approved":true}}'

echo "Waiting for the HPE CSI Operator deployment..."
oc rollout status deploy/hpe-csi-driver-operator -n "${HPE_CSI_NAMESPACE}" --timeout=10m

echo "Waiting for HPECSIDriver CRD..."
for _ in $(seq 1 60); do
  if oc get crd hpecsidrivers.storage.hpe.com >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
oc get crd hpecsidrivers.storage.hpe.com >/dev/null

echo "Creating HPECSIDriver ${HPE_OPERATOR_VERSION} from the official HPE sample..."
oc apply -n "${HPE_CSI_NAMESPACE}" -f "https://scod.hpedev.io/csi_driver/examples/deployment/hpecsidriver-v${HPE_OPERATOR_VERSION}-sample.yaml"

echo "Patching HPECSIDriver for B10000 block-only use..."
oc -n "${HPE_CSI_NAMESPACE}" patch hpecsidriver hpecsidriver-sample --type merge -p '{
  "spec": {
    "disable": {
      "alletra6000": true,
      "alletra9000": true,
      "alletraStorageMP": false,
      "b10000FileService": true,
      "nimble": true,
      "primera": true
    }
  }
}'

echo "Operator install requested. Check pods with:"
echo "  oc get pods -n ${HPE_CSI_NAMESPACE}"
