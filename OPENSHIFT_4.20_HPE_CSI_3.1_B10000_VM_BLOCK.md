# Install HPE CSI Operator 3.1 on OpenShift 4.20.19 for B10000 VM Raw Block Storage

This runbook installs the HPE CSI Operator for Kubernetes 3.1.0 on OpenShift 4.20.19 and configures an HPE Alletra Storage MP B10000 backend for raw block volumes used by OpenShift Virtualization VMs.

The storage network NNCP is assumed to already be configured and working on the OpenShift nodes. This guide does not create or modify NNCP resources.

## Scope

- OpenShift Container Platform: 4.20.19
- HPE CSI Operator for Kubernetes / OpenShift: 3.1.0 from OperatorHub through the `certified-operators` catalog
- Storage backend: HPE Alletra Storage MP B10000 block CSP
- Data path: iSCSI
- VM disk mode: `volumeMode: Block`
- OpenShift Virtualization: installed before the StorageProfile step

HPE lists OpenShift 4.20 EUS with HPE CSI Operator 3.0.2 through 3.1.0 as certified. Do not enable Automatic Updates for the HPE CSI Operator for OpenShift.

## Files

The helper scripts are in [scripts/hpe-csi-b10000-vm-block](</c:/Users/jfosn/OneDrive/Documents/hpe/hp_csi_driver_for_openshift/scripts/hpe-csi-b10000-vm-block>):

- `00-env.example` - copy to `00-env` and fill in site-specific values.
- `01-install-hpe-csi-operator.sh` - install the namespace, SCCs, OperatorGroup, Subscription, approve the 3.1.0 InstallPlan, and create the HPECSIDriver instance.
- `02-create-b10000-backend-secret.sh` - create or update the B10000 backend Secret.
- `03-configure-vm-block-storage.sh` - create the B10000 VM block StorageClass and StorageProfile.
- `04-verify-vm-block-storage.sh` - create a test `ReadWriteMany` raw block PVC and confirm it binds.

Run the scripts from a Linux, macOS, or WSL shell with `oc` installed and logged in as a cluster-admin user.

## 1. Collect Required Values

You need these values before starting:

| Value | Example | Notes |
|-------|---------|-------|
| B10000 management endpoint | `192.168.1.110:443` | Use the B10000 management IPv4 address with `:443`. |
| B10000 user | `3paradm` | Use an array account with `edit` or `super`; `edit` is preferred. |
| B10000 password | `REPLACE_ME` | Do not commit real credentials. |
| CPG | `SSD_r6` | CPG used for VM disks. |
| Snapshot CPG | `SSD_r6` | Defaults to `cpg` if omitted in manual manifests. |
| StorageClass name | `hpe-b10000-vm-block` | Also becomes the StorageProfile name. |

Copy the environment file and edit it:

```bash
cd hp_csi_driver_for_openshift
cp scripts/hpe-csi-b10000-vm-block/00-env.example scripts/hpe-csi-b10000-vm-block/00-env
vi scripts/hpe-csi-b10000-vm-block/00-env
source scripts/hpe-csi-b10000-vm-block/00-env
```

## 2. Preflight Checks

Confirm the cluster version and login:

```bash
oc whoami
oc get clusterversion version
oc get nodes -o wide
```

Confirm the NNCP exists. This guide assumes it is already applied and available:

```bash
oc get nncp
```

Confirm OpenShift Virtualization/CDI is installed before the StorageProfile step:

```bash
oc get crd storageprofiles.cdi.kubevirt.io
oc get storageprofile
```

Confirm the B10000 management endpoint and iSCSI target network are reachable from the storage network before creating VM disks. The exact test depends on your node firewall and available node tools, but the required paths are:

- CSI/CSP control plane to B10000 management endpoint: TCP/443.
- Worker nodes to B10000 iSCSI target portals: TCP/3260.

## 3. Install the HPE CSI Operator

Run:

```bash
source scripts/hpe-csi-b10000-vm-block/00-env
bash scripts/hpe-csi-b10000-vm-block/01-install-hpe-csi-operator.sh
```

The script does the following:

1. Creates the `hpe-storage` namespace if needed.
2. Applies HPE's OpenShift SCC manifest.
3. Creates an `OperatorGroup` in `hpe-storage`.
4. Creates a `Subscription` to `hpe-csi-operator` from `certified-operators` on the `stable` channel with manual approval.
5. Waits for an InstallPlan containing version `3.1.0`.
6. Approves only that InstallPlan.
7. Waits for `deploy/hpe-csi-driver-operator`.
8. Applies the official HPECSIDriver 3.1.0 sample and patches it so only the B10000 block CSP remains enabled.

Expected checks:

```bash
oc get csv -n hpe-storage
oc get hpecsidriver -n hpe-storage
oc get pods -n hpe-storage
```

Do not continue until the operator and CSI pods are running.

## 4. Create the B10000 Backend Secret

Run:

```bash
source scripts/hpe-csi-b10000-vm-block/00-env
bash scripts/hpe-csi-b10000-vm-block/02-create-b10000-backend-secret.sh
```

The Secret contains:

```yaml
serviceName: alletrastoragemp-csp-svc
servicePort: "8080"
backend: <B10000_MGMT_ENDPOINT>
username: <B10000_USERNAME>
password: <B10000_PASSWORD>
```

For B10000 block backends with IPv4, HPE recommends including `:443` in the backend value, for example `192.168.1.110:443`, to avoid SSH-based communication.

## 5. Create the VM Raw Block StorageClass and StorageProfile

Run:

```bash
source scripts/hpe-csi-b10000-vm-block/00-env
bash scripts/hpe-csi-b10000-vm-block/03-configure-vm-block-storage.sh
```

The StorageClass uses the B10000 backend Secret and these B10000 parameters:

```yaml
provisioner: csi.hpe.com
parameters:
  accessProtocol: iscsi
  cpg: <B10000_CPG>
  snapCpg: <B10000_SNAP_CPG>
  hostSeesVLUN: "true"
  provisioningType: tpvv
```

The StorageClass does not make a volume raw block by itself. The PVC or DataVolume must request:

```yaml
volumeMode: Block
```

For OpenShift Virtualization, the script also applies a StorageProfile for the StorageClass:

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: StorageProfile
metadata:
  name: hpe-b10000-vm-block
spec:
  claimPropertySets:
  - accessModes:
    - ReadWriteMany
    volumeMode: Block
  - accessModes:
    - ReadWriteOnce
    volumeMode: Block
  cloneStrategy: csi-clone
```

`ReadWriteMany` with `volumeMode: Block` is listed first because HPE's OpenShift guidance says to use RWX block PVCs for OpenShift Virtualization VM boot/image workflows instead of HPE NFS Server Provisioner-backed StorageClasses.

Verify:

```bash
oc get sc "${HPE_VM_BLOCK_STORAGECLASS}"
oc get storageprofile "${HPE_VM_BLOCK_STORAGECLASS}" -o yaml
```

## 6. Verify Dynamic Raw Block Provisioning

Run:

```bash
source scripts/hpe-csi-b10000-vm-block/00-env
bash scripts/hpe-csi-b10000-vm-block/04-verify-vm-block-storage.sh
```

The verification script creates a test PVC similar to:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: hpe-b10000-vm-block-test
spec:
  accessModes:
  - ReadWriteMany
  volumeMode: Block
  storageClassName: hpe-b10000-vm-block
  resources:
    requests:
      storage: 10Gi
```

Expected result:

```bash
oc get pvc -n hpe-csi-test
oc get pv
```

The PVC should reach `Bound`. If it remains `Pending`, check the HPE CSI controller logs and confirm the CPG name, backend Secret, array credentials, and iSCSI pathing.

## 7. Use With OpenShift Virtualization

When creating VM disks from YAML, explicitly request raw block unless you are intentionally relying on the StorageProfile defaults:

```yaml
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: rhel-vm-rootdisk
  namespace: vm-workloads
spec:
  source:
    blank: {}
  storage:
    storageClassName: hpe-b10000-vm-block
    accessModes:
    - ReadWriteMany
    volumeMode: Block
    resources:
      requests:
        storage: 80Gi
```

In the OpenShift web console, select the `hpe-b10000-vm-block` StorageClass for VM disks. The StorageProfile should steer CDI/OpenShift Virtualization toward `ReadWriteMany` raw block claims.

Do not use HPE `nfsResources: "true"` StorageClasses for OpenShift Virtualization boot/image PVCs.

## 8. Troubleshooting

Check the operator and CSI pods:

```bash
oc get csv -n hpe-storage
oc get pods -n hpe-storage -o wide
oc logs -n hpe-storage deploy/hpe-csi-driver-operator
```

Check the B10000 CSP and CSI controller logs:

```bash
oc logs -n hpe-storage deploy/alletrastoragemp-csp
oc logs -n hpe-storage deploy/hpe-csi-controller -c hpe-csi-driver
```

Check node identity and initiators:

```bash
oc get hpenodeinfo -n hpe-storage -o yaml
oc debug node/<worker-node-name> -- chroot /host cat /etc/iscsi/initiatorname.iscsi
```

If the CSI node driver reports duplicate NVMe NQN errors, use HPE's OpenShift duplicate NQN MachineConfig procedure. It triggers a rolling node reboot, so schedule the change accordingly.

## References

- HPE OpenShift guidance: https://scod.hpedev.io/csi_driver/partners/redhat_openshift/index.html
- HPE deployment guidance: https://scod.hpedev.io/csi_driver/deployment.html
- HPE B10000 CSP guidance: https://scod.hpedev.io/csi_driver/container_storage_provider/hpe_alletra_storage_mp_b10000/index.html
- HPE raw block volume guidance: https://scod.hpedev.io/csi_driver/using.html
- Red Hat OpenShift Virtualization storage profile guidance: https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/virtualization/storage
