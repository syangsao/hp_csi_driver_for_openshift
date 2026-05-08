# HP CSI Driver Deployment on OpenShift — Complete Guide

## Table of Contents
1. [Prerequisites](#prerequisites)
2. [Enable multipathd for iSCSI on OpenShift Nodes](#enable-multipathd-for-iscsi-on-openshift-nodes)
3. [Create the hpe-storage Namespace](#create-the-hpe-storage-namespace)
4. [Apply SecurityContextConstraints (SCC)](#apply-securitycontextconstraints-scc)
5. [Install the HPE CSI Operator](#install-the-hpe-csi-operator)
6. [Create the HPECSIDriver Instance](#create-the-hpecsidriver-instance)
7. [Add an HPE Storage Backend](#add-an-hpe-storage-backend)
8. [Configuring HPE Alletra Storage MP B10000](#configuring-hpe-alletra-storage-mp-b10000)
9. [Create a StorageClass](#create-a-storageclass)
10. [Troubleshooting](#troubleshooting)

---

## Prerequisites

- OpenShift 4.12+ (EUS versions recommended)
- `oc` CLI installed with `kube:admin` privileges
- Network connectivity from worker nodes to your HPE storage array
- iSCSI initiated volumes require **multipathd** installed and configured on all worker nodes

### Certified Combinations

| Status | OpenShift | CSI Operator | CSPs |
|--------|-----------|--------------|------|
| Certified | 4.21 | 3.1.0 | All |
| Certified | 4.20 EUS | 3.0.2 → 3.1.0 | All |
| Certified | 4.19 | 3.0.1 → 3.1.0 | All |
| Certified | 4.18 EUS | 2.5.2 → 3.1.0 | All |
| Certified | 4.17 | 2.5.2 → 3.1.0 | All |
| Certified | 4.16 EUS | 2.5.1 → 3.1.0 | All |
| Certified | 4.14 EUS | 2.4.0 → 3.1.0 | All |
| Certified | 4.12 EUS | 2.3.0 → 2.4.2 | All |

---

## Enable multipathd for iSCSI on OpenShift Nodes

**This step is critical for iSCSI-based storage.** The HPE CSI Driver relies on `multipathd` for proper iSCSI volume management on worker nodes. OpenShift RHCOS nodes do not have multipathd enabled by default.

### Step 1: Create a MachineConfig for multipathd

Create a file `99-worker-multipathd.yaml`:

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 99-worker-iscsi-multipathd
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - path: /etc/multipath.conf
        mode: 0644
        contents:
          source: data:text/plain;base64,<<BASE64_ENCODED_MULTIPATH_CONF>>
    systemd:
      units:
      - name: multipathd.service
        enabled: true
      - name: iscsid.service
        enabled: true
      - name: iscsi.service
        enabled: true
```

### Step 2: Prepare the multipath.conf

The HPE CSI Driver includes a recommended multipath configuration. Create `/etc/multipath.conf` content:

```conf
defaults {
    user_friendly_names yes
    find_bars yes
    fast_io_fail_tmo 5
}

devices {
    device {
        vendor "3PARdata"
        product "VV"
        path_grouping_policy multibus
        path_checker tur
        failback immediate
        no_path_retry fail
        fast_io_fail_tmo 5
    }
    device {
        vendor "Hewlett Packard"
        product "MSA"
        path_grouping_policy multibus
        path_checker tur
        failback immediate
        no_path_retry fail
        fast_io_fail_tmo 5
    }
    device {
        vendor "Hewlett Packard"
        product "P3000"
        path_grouping_policy multibus
        path_checker tur
        failback immediate
        no_path_retry fail
        fast_io_fail_tmo 5
    }
    device {
        vendor "HP"
        product "Open-V"
        path_grouping_policy multibus
        path_checker tur
        failback immediate
        no_path_retry fail
        fast_io_fail_tmo 5
    }
    device {
        vendor "LEFTHAND"
        product "VIRTUAL-OLUME"
        path_grouping_policy multibus
        path_checker tur
        failback immediate
        no_path_retry fail
        fast_io_fail_tmo 5
    }
    device {
        vendor "HPE"
        product "Alletra"
        path_grouping_policy multibus
        path_checker tur
        failback immediate
        no_path_retry fail
        fast_io_fail_tmo 5
    }
}
```

### Step 3: Base64 encode the multipath.conf

```bash
base64 -w0 /etc/multipath.conf
```

Replace `<<BASE64_ENCODED_MULTIPATH_CONF>>` in the MachineConfig with the base64 output.

### Step 4: Apply the MachineConfig

```bash
oc apply -f 99-worker-multipathd.yaml
```

**Important:** This triggers a rolling restart of all worker nodes. The nodes will be drained, rebooted, and multipathd will be enabled. Monitor the rollout:

```bash
oc get machines -n openshift-machine-api -w
oc get machineconfigpools
```

Wait until all nodes are `True` for `UPDATED` and `PROGRESSING` is `False`:

```bash
oc get machineconfigpools
# NAME     CONFIG                     KERNELVERSION                          UPDATED   UPDATING   DEGRADED   MISSING WORKERS
# worker   rendered-worker-xxxxx      4.18.x-2026xxxx                        True      False      False      0
# master   rendered-master-xxxxx      4.18.x-2026xxxx                        True      False      False      0
```

### Step 5: Verify multipathd on nodes

After all nodes have rebooted, verify multipathd is running:

```bash
# SSH to a worker node or use debug pod
oc debug node/<worker-node-name> -- chroot /host bash

# Inside the chroot:
systemctl status multipathd
systemctl status iscsid
systemctl status iscsi
multipath -ll  # Should show no paths until volumes are attached
```

---

## Create the hpe-storage Namespace

```bash
oc new-project hpe-storage --display-name="HPE CSI Operator for OpenShift"
```

> **Note:** The rest of this guide assumes the default `hpe-storage` namespace. If you use a different namespace, update the SCC accordingly.

---

## Apply SecurityContextConstraints (SCC)

The HPE CSI Driver needs privileged mode, host ports, host network, and hostPath volume access. Apply the SCC before installing the operator:

```bash
oc apply -f https://scod.hpedev.io/csi_driver/partners/redhat_openshift/examples/scc/hpe-csi-scc.yaml
```

This creates 4 SCCs:
- `hpe-csi-controller-scc` — Controller pod privileges
- `hpe-csi-node-scc` — Node driver pod privileges
- `hpe-csi-csp-scc` — Container Storage Provider privileges
- `hpe-csi-nfs-scc` — NFS Server Provisioner privileges

Expected output:
```
securitycontextconstraints.security.openshift.io/hpe-csi-controller-scc created
securitycontextconstraints.security.openshift.io/hpe-csi-node-scc created
securitycontextconstraints.security.openshift.io/hpe-csi-csp-scc created
securitycontextconstraints.security.openshift.io/hpe-csi-nfs-scc created
```

---

## Install the HPE CSI Operator

### Option A: OpenShift Web Console

1. Log in as `kubeadmin` → Navigate to **Operators → OperatorHub**
2. Search for `HPE CSI`
3. Select the **non-marketplace** version
4. Click **Install**
5. Select the `hpe-storage` namespace (where SCC was applied)
6. Select **Manual** Update Approval (⚠️ **NEVER enable Automatic Updates**)
7. Click **Install** → Click **Approve** to finalize
8. Click **View Operator**

### Option B: OpenShift CLI

#### 1. Create an OperatorGroup

```yaml
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: hpe-csi-driver-for-kubernetes
  namespace: hpe-storage
spec:
  targetNamespaces:
    - hpe-storage
```

```bash
oc apply -f operatorgroup.yaml
```

#### 2. Create a Subscription

```yaml
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: hpe-csi-operator
  namespace: hpe-storage
spec:
  channel: stable
  installPlanApproval: Manual
  name: hpe-csi-operator
  source: certified-operators
  sourceNamespace: openshift-marketplace
```

```bash
oc apply -f subscription.yaml
```

#### 3. Approve the Installation Plan

```bash
oc -n hpe-storage patch $(oc get installplans -n hpe-storage -o name) \
  -p '{"spec":{"approved":true}}' --type merge
```

#### 4. Wait for the Operator to Roll Out

```bash
oc rollout status deploy/hpe-csi-driver-operator -n hpe-storage
# deployment "hpe-csi-driver-operator" successfully rolled out
```

---

## Create the HPECSIDriver Instance

### Via Web Console

1. In the operator view, click **Create Instance**
2. Use defaults or customize the YAML (see below)
3. Click **Create**

### Via CLI

Apply the sample HPECSIDriver manifest. Choose the version matching your operator:

**v3.1.0 (latest):**
```bash
oc apply -n hpe-storage -f https://scod.hpedev.io/csi_driver/examples/deployment/hpecsidriver-v3.1.0-sample.yaml
```

**v3.0.1:**
```bash
oc apply -n hpe-storage -f https://scod.hpedev.io/csi_driver/examples/deployment/hpecsidriver-v3.0.1-sample.yaml
```

**v2.5.2:**
```bash
oc apply -n hpe-storage -f https://scod.hpedev.io/csi_driver/examples/deployment/hpecsidriver-v2.5.2-sample.yaml
```

### Key Configuration Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `iscsi.kubeletRootDir` | Kubelet root directory | `/var/lib/kubelet` |
| `iscsi.chapSecretName` | CHAP authentication secret | `""` |
| `logLevel` | Driver log level | `info` |
| `maxVolumesPerNode` | Max volumes per node | `100` |
| `disable.nimble` | Disable Nimble/Alletra 5000/6000 | `false` |
| `disable.primera` | Disable Primera/Alletra 9000 | `false` |
| `disable.alletra6000` | Disable Alletra 5000/6000 | `false` |
| `disable.alletra9000` | Disable Alletra 9000 | `false` |
| `disable.alletraStorageMP` | Disable Alletra Storage MP | `false` |
| `disable.b10000FileService` | Disable B10000 File Service | `false` |

### Custom HPECSIDriver Example

```yaml
apiVersion: storage.hpe.com/v1
kind: HPECSIDriver
metadata:
  name: hpecsidriver-sample
spec:
  controller:
    resources:
      limits:
        cpu: 2000m
        memory: 1Gi
      requests:
        cpu: 100m
        memory: 128Mi
  csp:
    resources:
      limits:
        cpu: 2000m
        memory: 1Gi
      requests:
        cpu: 100m
        memory: 128Mi
  node:
    resources:
      limits:
        cpu: 2000m
        memory: 1Gi
      requests:
        cpu: 100m
        memory: 128Mi
  disable:
    alletra6000: true     # Disable if not using Alletra 5000/6000
    alletra9000: true     # Disable if not using Alletra 9000
    nimble: true          # Disable if not using Nimble
    primera: true         # Disable if not using Primera
  iscsi:
    chapSecretName: ""
    kubeletRootDir: /var/lib/kubelet
  logLevel: info
  maxVolumesPerNode: 100
```

---

## Add an HPE Storage Backend

Create a Secret with your storage array credentials:

```bash
oc create secret generic hpe-secret \
  --from-literal=hpeStorageUsername="admin" \
  --from-literal=hpeStoragePassword="your_password" \
  -n hpe-storage
```

### Backend-specific ConfigMap

The HPE CSI Driver uses a ConfigMap `hpe-linux-config` to define storage backends:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: hpe-linux-config
  namespace: hpe-storage
data:
  hpe-3par-config-1.yaml: |
    ---
    hpe3parCredentialsSecretName: hpe-secret
    hpe3parCssEnabled: true
    hpe3parNasHostname: "192.168.1.100"
    hpe3parCpgName: default
    hpe3parFcEnabled: false
    hpe3parIscsiEnabled: true
    hpe3parIscsiInitiatorName: ""
    hpe3parSnmpReadOnlyToken: ""
    hpe3parTimeout: 0
    hpe3parFlashCache: false
    hpe3parFlashCacheMode: ""
    hpe3parHostVolPrefix: "k8s-"
    hpe3parSnapThrottling: 0
    hpe3parMaxSnapshots: 0
    hpe3parSyncPeriodInHours: 1
    hpe3parUseRasAPI: false
    hpe3parApiVn: 1
    hpe3parDisableAutoSpaceReclaim: true
```

> Replace values with your actual storage array configuration. See the [SCOD docs](https://scod.hpedev.io/csi_driver/container_storage_provider/) for your specific array type:
> - [Alletra Storage MP B10000, Alletra 9000, Primera, 3PAR](https://scod.hpedev.io/csi_driver/container_storage_provider/hpe_alletra_storage_mp_b10000/index.html)
> - [Alletra 5000/6000 & Nimble](https://scod.hpedev.io/csi_driver/container_storage_provider/hpe_alletra_6000/index.html)
> - [Alletra Storage MP B10000 File Service](https://scod.hpedev.io/csi_driver/container_storage_provider/hpe_alletra_storage_mp_b10000_file_service/index.html)

---

## Configuring HPE Alletra Storage MP B10000

This section covers the specific configuration steps for connecting an HPE Alletra Storage MP B10000 array to OpenShift.

### Platform Requirements

- **Array firmware**: HPE Primera OS (check the [compatibility table](https://scod.hpedev.io/csi_driver/index.html#compatibility-and-support) for your CSI driver version)
- **User role**: `edit` or `super` on the storage array (`edit` is recommended for security best practices)
- **LDAP accounts**: Supported from HPE CSI Driver v2.5.2 onwards

### Network Port Requirements

Ensure the following TCP ports are open inbound from Kubernetes worker nodes to the B10000 array:

| Port  | Protocol | Description |
|-------|----------|-------------|
| 443   | HTTPS    | WSAPI (management API) |
| 3260  | TCP      | iSCSI Target |
| 445   | TCP      | SMB (NFS via B10000 File Service) |

> **Note:** NVMe/TCP requires port 4443 open on the array. FC requires no additional ports beyond the fabric.

### Data Path Protocols

The B10000 supports multiple access protocols. Choose one when creating your StorageClass:

| Protocol   | IPv6 Support | Peer Persistence | Notes |
|------------|-------------|-------------------|-------|
| iSCSI      | Yes         | Yes               | Requires multipathd (see above) |
| FC         | N/A         | Yes               | Requires Fibre Channel HBAs |
| NVMe/TCP   | No          | No                | B10000 only |
| NFS        | No          | No                | B10000 only (uses File Service CSP) |

### Step 1: Create the B10000 Backend Secret

```bash
oc create secret generic hpe-backend \
  --from-literal=serviceName="alletrastoragemp-csp-svc" \
  --from-literal=servicePort="8080" \
  --from-literal=backend="192.168.1.110:443" \
  --from-literal=username="3paradm" \
  --from-literal=password="your_password" \
  -n hpe-storage
```

**Key differences from other platforms:**
- `serviceName` is `alletrastoragemp-csp-svc` (not `alletra6000-csp-svc` or `alletra9000-csp-svc`)
- `backend` includes `:443` suffix (required for B10000, Alletra 9000, and Primera from v2.5.2 onwards)
- `username` uses the array account name (not necessarily `admin`)

### Step 2: Create the B10000 Backend ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: hpe-linux-config
  namespace: hpe-storage
data:
  hpe-alletra-storage-mp-config-1.yaml: |
    ---
    hpeAlletraStorageMPCredentialsSecretName: hpe-backend
    hpeAlletraStorageMpCssEnabled: true
    hpeAlletraStorageMpNasHostname: ""
    hpeAlletraStorageMpCpgName: default
    hpeAlletraStorageMpFcEnabled: false
    hpeAlletraStorageMpIscsiEnabled: true
    hpeAlletraStorageMpIscsiInitiatorName: ""
    hpeAlletraStorageMpSnmpReadOnlyToken: ""
    hpeAlletraStorageMpTimeout: 0
    hpeAlletraStorageMpFlashCache: false
    hpeAlletraStorageMpFlashCacheMode: ""
    hpeAlletraStorageMpHostVolPrefix: "k8s-"
    hpeAlletraStorageMpSnapThrottling: 0
    hpeAlletraStorageMpMaxSnapshots: 0
    hpeAlletraStorageMpSyncPeriodInHours: 1
    hpeAlletraStorageMpUseRasAPI: false
    hpeAlletraStorageMpApiVn: 1
    hpeAlletraStorageMpDisableAutoSpaceReclaim: true
    hpeAlletraStorageMpNvmeTcpEnabled: false
```

> Replace values with your actual configuration:
> - `hpeAlletraStorageMpCpgName`: Set to your CPG name (or `default` to auto-select)
> - `hpeAlletraStorageMpIscsiEnabled`: Set to `true` for iSCSI, `false` otherwise
> - `hpeAlletraStorageMpFcEnabled`: Set to `true` if using Fibre Channel
> - `hpeAlletraStorageMpNvmeTcpEnabled`: Set to `true` if using NVMe/TCP

Apply:

```bash
oc apply -f hpe-linux-config.yaml
```

### Step 2b: Verify iSCSI Initiators (iSCSI deployments only)

The CSI driver auto-discovers iSCSI initiators on each worker node and creates hosts on the B10000 automatically. Before proceeding, verify each node has a valid initiator name:

```bash
# List all worker nodes
oc get nodes -l node-role.kubernetes.io/worker -o name

# Check the iSCSI initiator name on each worker node
oc debug node/<worker-node-name> -- chroot /host cat /etc/iscsi/initiatorname.iscsi
# Example output: InitiatorName=iqn.2019-08.com.redhat:xxxx

# Alternatively, check HPENodeInfos after the CSI driver is running
oc get hpenodeinfo -n hpe-storage -o custom-columns='NODE:.metadata.name,INITIATOR:.spec.record.InitiatorNames'
```

**If a node shows no initiator name or a blank file:**

```bash
# Inside the debug pod chroot:
yum install -y iscsi-initiator-utils
service iscsid start
cat /etc/iscsi/initiatorname.iscsi
```

**When manual host creation IS required:**
- Using **Virtual Domains** — hosts must be created manually on the array (see SCOD docs for [Virtual Domains steps](https://scod.hpedev.io/csi_driver/container_storage_provider/hpe_alletra_storage_mp_b10000/index.html#virtual-domains))
- Using `disableHostDeletion: true` in HPECSIDriver — prevents the driver from deleting hosts on the array
- Using storage array security policies that restrict API host creation

For Virtual Domains, manually create hosts via the B10000 CLI:
```bash
cli% createhost -sn iqn-<hostname> -domain <domain-name> iqn.2019-08.com.redhat:xxxx
```
> **Note:** From CSI Driver v3.0.0+, hostnames must be prefixed with the protocol (`iqn-` for iSCSI, `nqntcp-` for NVMe/TCP, `wwn-` for FC). Total length must not exceed 27 characters.

### Step 3: Create the B10000 StorageClass

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
  name: hpe-standard
parameters:
  csi.storage.k8s.io/controller-expand-secret-name: hpe-backend
  csi.storage.k8s.io/controller-expand-secret-namespace: hpe-storage
  csi.storage.k8s.io/controller-publish-secret-name: hpe-backend
  csi.storage.k8s.io/controller-publish-secret-namespace: hpe-storage
  csi.storage.k8s.io/node-publish-secret-name: hpe-backend
  csi.storage.k8s.io/node-publish-secret-namespace: hpe-storage
  csi.storage.k8s.io/node-stage-secret-name: hpe-backend
  csi.storage.k8s.io/node-stage-secret-namespace: hpe-storage
  csi.storage.k8s.io/provisioner-secret-name: hpe-backend
  csi.storage.k8s.io/provisioner-secret-namespace: hpe-storage
  csi.storage.k8s.io/fstype: xfs
  accessProtocol: iscsi
  description: Volume created by the HPE CSI Driver for Kubernetes
  cpg: SSD_r6
  snapCpg: SSD_r6
  hostSeesVLUN: "true"
  provisioningType: tpvv
provisioner: csi.hpe.com
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
```

**StorageClass parameters explained:**

| Parameter | Value | Description |
|-----------|-------|-------------|
| `accessProtocol` | `iscsi`, `fc`, `nvmetcp` | Data path protocol (case-sensitive) |
| `cpg` | CPG name | Storage CPG for volume provisioning |
| `snapCpg` | CPG name | CPG for snapshots (defaults to `cpg` if omitted) |
| `provisioningType` | `tpvv`, `full`, `dedup`, `reduce` | Volume type (default: `tpvv` = thin provisioned) |
| `hostSeesVLUN` | `true` or `false` | VLUN template: `true` = "host sees" (recommended), `false` = "matched set" |
| `fcPortsList` | Comma-separated | FC port list (e.g., `"0:5:1,1:4:2"`) — defaults to all ports |
| `iscsiPortalIps` | Comma-separated | iSCSI portal IPs — defaults to all portals |
| `qosName` | Volume set name | Apply QoS rules from a volume set |

Apply:

```bash
oc apply -f storageclass.yaml
```

### Step 4: Verify B10000 Connectivity

```bash
# Check CSP pod is running
oc get pods -n hpe-storage | grep alletrastoragemp

# Check HPENodeInfos are created
oc get hpenodeinfo -n hpe-storage

# Verify StorageClass
oc get sc hpe-standard

# Test provisioning
oc apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-b10000-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: hpe-standard
  resources:
    requests:
      storage: 10Gi
EOF

oc get pvc test-b10000-pvc
```

### HPECSIDriver Configuration for B10000 Only

If you're only using B10000 and no other HPE arrays, disable the other CSPs in your HPECSIDriver:

```yaml
spec:
  disable:
    alletra6000: true     # Disable if not using Alletra 5000/6000
    alletra9000: true     # Disable if not using Alletra 9000
    nimble: true          # Disable if not using Nimble
    primera: true         # Disable if not using Primera
    alletraStorageMP: false   # Keep enabled for B10000
    b10000FileService: true   # Disable unless using File Service
```

### Known Limitations

- **VolumeAttachments per node**: Tested up to 250 with iSCSI. HPE recommends ≤200 per node. Default limit is 100 — increase via `maxVolumesPerNode`.
- **Node hostnames**: Must not exceed 27 characters. From v3.0.0+, hostnames are prefixed with the protocol (`iqn-`, `nqntcp-`, `wwn-`).
- **IPv6**: Only supported for iSCSI and API endpoint access. Not supported for NVMe/TCP, NFS, or replication.
- **Inline ephemeral volumes**: Not supported.
- **Protocol migration**: Migrating PersistentVolumes between protocols is discouraged until further notice.

> **Reference:** [HPE Alletra Storage MP B10000 CSP Documentation](https://scod.hpedev.io/csi_driver/container_storage_provider/hpe_alletra_storage_mp_b10000/index.html)

---

## Create a StorageClass

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: hpe-standard
provisioner: csi.hpe.com
parameters:
  cpg: default
  protocol: iscsi
  nasHostname: "192.168.1.100"
  fsType: xfs
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

```bash
oc apply -f storageclass.yaml
```

> **SCC Note:** If you encounter write permission issues under a restricted SCC, add `fsMode: "0770"` for RWO or `fsMode: "0777"` for RWX claims.

---

## Verify the Installation

```bash
# Check operator status
oc get csv -n hpe-storage

# Check CSI driver pods
oc get pods -n hpe-storage

# Check HPECSIDriver instance
oc get hpecsidriver -n hpe-storage

# Check ConfigMap
oc get configmap hpe-linux-config -n hpe-storage

# Verify StorageClass
oc get sc
```

### Test with a PVC

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: hpe-standard
  resources:
    requests:
      storage: 10Gi
```

```bash
oc apply -f test-pvc.yaml
oc get pvc test-pvc
```

---

## Troubleshooting

### CSI Node Driver Fails with Duplicate NQN Error

If the init container reports:
```
Initiator validation failed: CRITICAL: Duplicate NQN detected on node 'my-worker-node-0'
```

Apply this MachineConfig to regenerate unique NVMe host identities:

```bash
oc apply -f https://scod.hpedev.io/csi_driver/partners/redhat_openshift/examples/nqns/machine-config.yaml
```

This triggers a rolling restart of worker nodes.

### Pods Stuck in ContainerCreating

Check the events:
```bash
oc describe pod <pod-name> -n hpe-storage
oc get events -n hpe-storage --sort-by='.lastTimestamp'
```

### multipathd Not Running on Nodes

```bash
oc debug node/<worker-node> -- chroot /host bash
# Inside chroot:
systemctl status multipathd
journalctl -u multipathd
```

### SCC Permission Issues

Verify SCC is applied:
```bash
oc get scc | grep hpe-csi
oc describe scc hpe-csi-controller-scc
oc describe scc hpe-csi-node-scc
```

### iSCSI CHAP Authentication

If your storage array requires CHAP authentication, create a secret:

```bash
oc create secret generic hpe-chap-secret \
  --from-literal=hpeIscsiInitiatorUsername="username" \
  --from-literal=hpeIscsiInitiatorPassword="password" \
  -n hpe-storage
```

Then set `iscsi.chapSecretName: hpe-chap-secret` in the HPECSIDriver spec.

---

## Uninstalling

> ⚠️ **WARNING:** Do NOT modify or remove CRDs if you plan to upgrade or reinstall — this prevents data loss.

CRDs installed by the driver:
- `hpenodeinfos.storage.hpe.com`
- `hpereplicationdeviceinfos.storage.hpe.com`
- `hpereplicationmappings.storage.hpe.com`
- `hpesnapshotgroupinfos.storage.hpe.com`
- `hpevolumegroupinfos.storage.hpe.com`
- `hpevolumeinfos.storage.hpe.com`
- `snapshotgroupclasses.storage.hpe.com`
- `snapshotgroupcontents.storage.hpe.com`
- `snapshotgroups.storage.hpe.com`
- `volumegroupclasses.storage.hpe.com`
- `volumegroupcontents.storage.hpe.com`
- `volumegroups.storage.hpe.com`

The `hpecsidrivers.storage.hpe.com` CRD is installed by the operator and CAN be removed during reinstallation.

---

## Upgrading

1. Follow prerequisite steps from the [Helm chart on ArtifactHub](https://artifacthub.io/packages/helm/hpe-storage/hpe-csi-driver)
2. **Never enable Automatic Updates** for the operator
3. Uninstall the HPECSIDriver instance
4. Delete the CRD: `oc delete crd/hpecsidrivers.storage.hpe.com`
5. Uninstall the HPE CSI Operator
6. Reinstall following the steps above
7. Reapply the SCC

> Deleting the HPECSIDriver instance and uninstalling the operator does NOT affect running workloads, PVCs, StorageClasses, or other resources. In-flight operations retry once the new HPECSIDriver is instantiated.
