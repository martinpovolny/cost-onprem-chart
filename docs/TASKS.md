# Tasks

Active engineering tasks for the cost-onprem CRC dev environment.

---

## Fix Redpanda SCC setup on fresh CRC

**Status:** Open  
**Affects:** `make crc-deploy-amd64-dev` on AMD64 (foobar), fresh CRC instances

### Symptom

On a freshly created CRC instance (after `crc delete` + `crc start`), the Redpanda
StatefulSet pod fails to start with:

```
create Pod redpanda-0 failed: pods "redpanda-0" is forbidden: unable to validate
against any security context constraint: [...] provider "privileged": Forbidden:
not usable by user or serviceaccount
```

The helm install times out waiting for the pod:

```
Error: resource StatefulSet/kafka/redpanda not ready. status: InProgress, Replicas: 0/1
context deadline exceeded
```

### Background

`scripts/deploy-redpanda.sh` uses a 3-phase strategy on OpenShift:

1. **Phase 1** — `helm install --set statefulset.replicas=0`: creates resources
   (including the `redpanda` ServiceAccount) without scheduling any pods.
2. **Phase 2** — `oc adm policy add-scc-to-user privileged system:serviceaccount:kafka:redpanda`:
   grants the privileged SCC so the init container can run as root with `SYS_RESOURCE`.
3. **Phase 3** — `helm upgrade --set statefulset.replicas=1 --wait --timeout 10m`:
   scales up and waits for the pod to be ready.

### What we know

- The 3-phase approach **worked on the first AMD64 run** against a 6-day-old CRC
  instance — 171/196 tests passed.
- It **consistently fails on freshly created CRC instances** (after `crc delete`).
- Manual inspection confirmed the ClusterRoleBinding IS created by Phase 2:
  `clusterrolebinding system:openshift:scc:privileged … kafka/redpanda`
- Yet `kubectl describe pod` still shows `provider "privileged": Forbidden`.
- Manually running `oc adm policy add-scc-to-user` again after the failure also
  reports "added" but the pod still can't start.
- `oc auth can-i use scc/privileged --as=system:serviceaccount:kafka:redpanda`
  has not been tested yet — would confirm whether the admission controller agrees.

### Hypothesis

The SCC ClusterRoleBinding is created but the admission controller hasn't refreshed
its RBAC cache by the time Phase 3 starts. There may be a propagation delay on fresh
CRC instances that didn't exist on the 6-day-old instance (where the cache was warm).

### Proposed fix

After Phase 2, verify the grant is effective before scaling up:

```bash
# Wait until the admission controller agrees
until oc auth can-i use scc/privileged \
    --as=system:serviceaccount:${KAFKA_NAMESPACE}:redpanda 2>/dev/null | grep -q yes; do
  echo "Waiting for SCC grant to propagate..."
  sleep 5
done
```

Then proceed to Phase 3.

### Files to change

- `scripts/deploy-redpanda.sh` — add propagation wait after Phase 2 SCC grant

---
