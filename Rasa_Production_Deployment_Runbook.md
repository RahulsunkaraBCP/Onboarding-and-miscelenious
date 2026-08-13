# Rasa Production Bot Deployment and Cluster Validation Runbook

**Environment:** BetterCarPeople production  
**Platform:** AWS EKS cluster `rasa`, namespace `rasa`, region `us-east-1`  
**Audience:** DevOps engineers supporting Rasa, Rasa Pro Services, Studio, Kafka, EKS, RDS, Istio, and the production deployment workflow  
**Version:** 1.0 - August 13, 2026

> This is an operational reference. The normal inspection commands are read-only. Commands that change production are placed only in **Approved changes only** sections. Prefer the existing GitHub Actions/GitOps workflow over manual production changes.

## 1. What this runbook gives you

Use this runbook whenever developers deploy a new bot, model, actions image, Rasa version, Rasa Services version, Kubernetes configuration, Helm values, or infrastructure change.

It provides:

- A fast command sequence for today's deployment.
- A complete pre-deployment baseline.
- Live rollout and pod monitoring.
- Rasa, Rasa Pro Services, Studio, Kafka, Istio, EKS, RDS, ALB, and CloudWatch checks.
- Procedures for a new Rasa or Rasa Services version.
- Safe diff, plan, deploy, rollback, and incident commands.
- A read-only collection script that writes a timestamped evidence bundle.
- A deployment record template for future audits and troubleshooting.

## 2. Production facts and variables

Known platform details should be verified at the start of every change because the live environment can drift.

| Item | Current reference value |
|---|---|
| AWS region | `us-east-1` |
| EKS cluster | `rasa` |
| Kubernetes namespace | `rasa` |
| Node group | `node-group-green-20260317165903002100000001` |
| Rasa workload | Deployment `rasa`; label `app.kubernetes.io/name=rasa` |
| Kafka brokers | Pods normally named `kafka-controller-0`, `-1`, and `-2` |
| Kafka topics of special interest | `rasa`, `rasa-events-dlq` |
| Kafka consumer groups | `rasa-analytics-group`, `studio` |
| Sidecar model | Istio sidecars are present; a healthy application pod may show `2/2` containers |
| Known Rasa reference version | Rasa Pro `3.16.6` was previously observed; always capture the live version |
| Known Rasa Services reference | `3.8.2.dev2` was previously observed; always capture the live version |

Set these variables in each terminal. Replace the profile only if your local AWS CLI profile uses a different name.

```bash
export BCP_AWS_PROFILE="<your-bettercarpeople-profile>"
export AWS_REGION="us-east-1"
export CLUSTER="rasa"
export NS="rasa"
export NODEGROUP="node-group-green-20260317165903002100000001"
```

If you do not use a named AWS profile, omit `--profile "$BCP_AWS_PROFILE"` from AWS commands.

## 3. Today's deployment: the short command sequence

Run this sequence in order. Keep one terminal for the rollout and another for logs/events.

### 3.1 Confirm identity and production context

```bash
aws sts get-caller-identity --profile "$BCP_AWS_PROFILE"
aws eks describe-cluster \
  --profile "$BCP_AWS_PROFILE" \
  --region "$AWS_REGION" \
  --name "$CLUSTER" \
  --query 'cluster.{name:name,status:status,version:version,endpoint:endpoint}'

kubectl config current-context
kubectl cluster-info
kubectl auth can-i get pods -n "$NS"
```

Stop if the account, cluster, or namespace is not the expected production target.

### 3.2 Save the baseline before developers begin

```bash
./rasa-deployment-collector.sh \
  --profile "$BCP_AWS_PROFILE" \
  --phase pre \
  --since 2h
```

If the script is not available yet, run the following minimum baseline:

```bash
date -u
kubectl get nodes -o wide
kubectl get deploy,statefulset,daemonset -n "$NS" -o wide
kubectl get pods -n "$NS" -o wide
kubectl get hpa,pdb -n "$NS"
kubectl top nodes
kubectl top pods -n "$NS" --containers
kubectl get events -n "$NS" --sort-by='.lastTimestamp' | tail -100
```

### 3.3 Watch the rollout live

Terminal 1:

```bash
kubectl get pods -n "$NS" -w -o wide
```

Terminal 2:

```bash
kubectl rollout status deployment/rasa -n "$NS" --timeout=15m
kubectl get rs -n "$NS" --sort-by='.metadata.creationTimestamp'
kubectl get events -n "$NS" --field-selector type=Warning \
  --sort-by='.lastTimestamp' | tail -100
```

Terminal 3 for Rasa application logs:

```bash
kubectl logs -n "$NS" deployment/rasa -c rasa \
  --since=30m --timestamps --tail=5000 -f
```

Press `Ctrl+C` to stop a watch or log follow; that does not stop the deployment.

### 3.4 Validate immediately after rollout

```bash
kubectl get deploy,statefulset,daemonset -n "$NS" -o wide
kubectl get pods -n "$NS" -o wide
kubectl get svc,endpoints,endpointslice -n "$NS"
kubectl top nodes
kubectl top pods -n "$NS" --containers
kubectl get events -n "$NS" --sort-by='.lastTimestamp' | tail -100

kubectl get deployment/rasa -n "$NS"
kubectl rollout history deployment/rasa -n "$NS"
```

### 3.5 Save the post-deployment bundle

```bash
./rasa-deployment-collector.sh \
  --profile "$BCP_AWS_PROFILE" \
  --phase post \
  --since 2h
```

Continue observing production for at least 30-60 minutes. A rollout can complete even though delayed readiness failures, IAM token refresh failures, Kafka lag, or memory pressure appear later.

## 4. Access and context setup

### 4.1 Authenticate to AWS

For an AWS SSO profile:

```bash
aws sso login --profile "$BCP_AWS_PROFILE"
aws sts get-caller-identity --profile "$BCP_AWS_PROFILE"
```

Confirm the returned account is the BetterCarPeople account before continuing.

### 4.2 Create or refresh the kubeconfig entry

This changes only your local kubeconfig; it does not change the cluster.

```bash
aws eks update-kubeconfig \
  --profile "$BCP_AWS_PROFILE" \
  --region "$AWS_REGION" \
  --name "$CLUSTER" \
  --alias rasa-prod
```

Then verify:

```bash
kubectl config current-context
kubectl cluster-info
kubectl get namespace "$NS" --show-labels
kubectl auth can-i get pods -n "$NS"
kubectl auth can-i get deployments -n "$NS"
```

### 4.3 Check local tools

```bash
aws --version
kubectl version --client
jq --version
git --version
gh --version
helm version
terraform version
istioctl version --remote=false
```

Only `aws` and `kubectl` are required for the core checks. `jq`, `gh`, `helm`, `terraform`, and `istioctl` enable additional sections.

## 5. Pre-deployment baseline

Capture the following before the deployment starts. This is how you prove whether a restart, lag increase, warning event, or resource spike existed before the change.

### 5.1 Record change identity

Record:

- Deployment date and UTC start time.
- Developer or release owner.
- Git branch, commit SHA, PR, and GitHub Actions run ID.
- Expected bot/model version.
- Current and candidate Rasa/Rasa Services image tags or digests.
- Files changed, especially `data/`, `domain`, actions, prompts, connectors, `endpoints.yml`, `k8s/prod/values.yaml`, Dockerfiles, workflows, Helm, and Terraform.
- Expected database migration or topic change.
- Rollback commit/image/model and owner authorized to approve rollback.

From the repository:

```bash
git status --short
git branch --show-current
git log -1 --date=iso --format='commit=%H%nshort=%h%nauthor=%an%ndate=%ad%nsubject=%s'
git remote -v
git fetch origin
git diff --name-status <last-production-sha>..<candidate-sha>
git diff <last-production-sha>..<candidate-sha> -- \
  k8s/prod/values.yaml endpoints.yml Dockerfile .github/workflows
```

### 5.2 Cluster and node baseline

```bash
date -u
kubectl version
kubectl cluster-info
kubectl get nodes -o wide
kubectl get nodes -L eks.amazonaws.com/nodegroup,topology.kubernetes.io/zone
kubectl top nodes
kubectl describe nodes
```

Compact node condition report with `jq`:

```bash
kubectl get nodes -o json | jq -r '
  .items[] |
  .metadata.name as $n |
  .status.conditions[] |
  select(.type=="Ready" or .type=="MemoryPressure" or
         .type=="DiskPressure" or .type=="PIDPressure") |
  [$n,.type,.status,.reason] | @tsv'
```

Healthy baseline:

- Every node is `Ready`.
- Memory, disk, and PID pressure are `False`.
- All expected availability zones and nodes are present.
- Kafka controllers are spread as intended; do not assume pod anti-affinity is working without checking pod placement.
- CPU and memory have headroom for the rolling surge.

### 5.3 EKS node group baseline

```bash
aws eks describe-nodegroup \
  --profile "$BCP_AWS_PROFILE" \
  --region "$AWS_REGION" \
  --cluster-name "$CLUSTER" \
  --nodegroup-name "$NODEGROUP" \
  --query 'nodegroup.{status:status,version:version,releaseVersion:releaseVersion,scaling:scalingConfig,health:health.issues,asg:resources.autoScalingGroups}'
```

Compare live `minSize`, `desiredSize`, and `maxSize` with `k8s/tf/autoscaling/prod.tfvars`. Do not apply Terraform while unexplained drift exists.

### 5.4 Workload baseline

```bash
kubectl get deploy,statefulset,daemonset -n "$NS" -o wide
kubectl get rs -n "$NS" --sort-by='.metadata.creationTimestamp'
kubectl get jobs,cronjobs -n "$NS" -o wide
kubectl get hpa,pdb -n "$NS" -o wide
kubectl get pods -n "$NS" -o wide
kubectl get pods -n "$NS" --field-selector=status.phase=Pending -o wide
kubectl get pvc -n "$NS"
```

Exact workload images:

```bash
kubectl get deploy,statefulset,daemonset -n "$NS" -o json | jq -r '
  .items[] as $w |
  ($w.spec.template.spec.containers // [])[] |
  [$w.kind,$w.metadata.name,.name,.image] | @tsv'
```

Exact readiness, restart, and last termination state:

```bash
kubectl get pods -n "$NS" -o json | jq -r '
  .items[] as $p |
  ($p.status.containerStatuses // [])[] |
  [$p.metadata.name,.name,.ready,.restartCount,
   (.state.waiting.reason // .state.terminated.reason // "Running"),
   (.lastState.terminated.reason // "-"),
   (.lastState.terminated.exitCode // "-"),
   (.lastState.terminated.finishedAt // "-")] | @tsv'
```

Healthy baseline:

- Deployments show desired replicas equal to ready, updated, and available replicas.
- StatefulSets show ready replicas equal to desired replicas.
- No unexpected Pending, CrashLoopBackOff, ImagePullBackOff, Error, Evicted, or Terminating pods.
- Restart counts are understood and not increasing.
- Jobs that are expected to complete show `Complete`, not repeated failures.

### 5.5 Probes and resource configuration

Capture the actual probes rather than relying on memory:

```bash
kubectl get deploy,statefulset -n "$NS" -o json | jq '
  .items[] |
  {kind,workload:.metadata.name,
   containers:[.spec.template.spec.containers[] |
     {name,readinessProbe,livenessProbe,startupProbe,resources}]}'
```

For the Rasa container only:

```bash
kubectl get deployment/rasa -n "$NS" -o json | jq '
  .spec.template.spec.containers[] |
  select(.name=="rasa") |
  {image,readinessProbe,livenessProbe,startupProbe,resources,ports}'
```

Record the probe path, port, initial delay, period, timeout, failure threshold, CPU/memory requests, and limits. These exact values are important when investigating readiness timeouts or restarts.

### 5.6 Services, endpoints, networking, and Istio

```bash
kubectl get svc,endpoints,endpointslice -n "$NS" -o wide
kubectl get ingress -n "$NS" -o wide
kubectl get virtualservice,destinationrule,gateway -n "$NS" 2>/dev/null || true
kubectl get namespace "$NS" --show-labels
kubectl get pods -n "$NS" \
  -o custom-columns='POD:.metadata.name,CONTAINERS:.spec.containers[*].name'
```

If `istioctl` is installed:

```bash
istioctl proxy-status
istioctl analyze -n "$NS"
```

Healthy baseline:

- Services have expected EndpointSlices and ready addresses.
- Rasa application pods contain both the application container and `istio-proxy` when injection is expected.
- Migration and one-time Jobs that should not have sidecars are annotated appropriately.
- `istioctl` reports synchronized proxies and no new critical analysis findings.

### 5.7 Events and logs before the change

```bash
kubectl get events -n "$NS" --sort-by='.lastTimestamp' | tail -200
kubectl get events -n "$NS" --field-selector type=Warning \
  --sort-by='.lastTimestamp' | tail -200

kubectl logs -n "$NS" deployment/rasa -c rasa \
  --since=2h --timestamps --tail=10000 > rasa-predeploy.log
```

Search the saved log:

```bash
rg -n -i 'error|exception|traceback|timeout|timed out|unhealthy|failed|oom|403|pam authentication|readiness|liveness' \
  rasa-predeploy.log
```

If `rg` is not installed, use `grep -Eni` with the same pattern.

## 6. Monitor the deployment live

### 6.1 Watch pods and rollout state

```bash
kubectl get pods -n "$NS" -w -o wide
```

For the main Rasa deployment:

```bash
kubectl rollout status deployment/rasa -n "$NS" --timeout=15m
kubectl rollout history deployment/rasa -n "$NS"
```

For every deployment:

```bash
for workload in $(kubectl get deployment -n "$NS" -o name); do
  echo "===== $workload ====="
  kubectl rollout status -n "$NS" "$workload" --timeout=10m
done
```

For StatefulSets:

```bash
for workload in $(kubectl get statefulset -n "$NS" -o name); do
  echo "===== $workload ====="
  kubectl rollout status -n "$NS" "$workload" --timeout=15m
done
```

Do not assume that every StatefulSet should roll during a bot-only deployment. An unexpected Kafka rollout is a reason to pause and investigate.

### 6.2 Watch ReplicaSets and image changes

```bash
kubectl get rs -n "$NS" --sort-by='.metadata.creationTimestamp' -w
```

```bash
kubectl get deployment/rasa -n "$NS" \
  -o custom-columns='NAME:.metadata.name,REVISION:.metadata.annotations.deployment\.kubernetes\.io/revision,DESIRED:.spec.replicas,UPDATED:.status.updatedReplicas,READY:.status.readyReplicas,AVAILABLE:.status.availableReplicas,UNAVAILABLE:.status.unavailableReplicas'
```

```bash
kubectl get pods -n "$NS" -l app.kubernetes.io/name=rasa \
  -o custom-columns='POD:.metadata.name,DECLARED_IMAGES:.spec.containers[*].image,IMAGE_DIGESTS:.status.containerStatuses[*].imageID'
```

### 6.3 Watch events continuously

Portable loop for macOS without the `watch` utility:

```bash
while true; do
  clear
  date -u
  kubectl get pods -n "$NS" -o wide
  echo
  kubectl get events -n "$NS" --field-selector type=Warning \
    --sort-by='.lastTimestamp' | tail -40
  sleep 10
done
```

### 6.4 Follow logs from every Rasa application pod

```bash
for pod in $(kubectl get pods -n "$NS" \
  -l app.kubernetes.io/name=rasa -o jsonpath='{.items[*].metadata.name}'); do
  echo "===== $pod / rasa ====="
  kubectl logs -n "$NS" "$pod" -c rasa \
    --since=30m --timestamps --tail=2000
done
```

For the RDS IAM authentication proxy sidecar, if present:

```bash
for pod in $(kubectl get pods -n "$NS" \
  -l app.kubernetes.io/name=rasa -o jsonpath='{.items[*].metadata.name}'); do
  echo "===== $pod / rdsauthproxy ====="
  kubectl logs -n "$NS" "$pod" -c rdsauthproxy \
    --since=30m --timestamps --tail=2000 2>&1
done
```

Watch for repeated HTTP `403`, Postgres PAM authentication failures, connection pool errors, timeouts, and retries. One successful retry still needs to be recorded if it occurs close to a restart.

### 6.5 Diagnose a pod that is not becoming ready

```bash
export POD="<pod-name>"

kubectl get pod -n "$NS" "$POD" -o wide
kubectl describe pod -n "$NS" "$POD"
kubectl get pod -n "$NS" "$POD" -o json | jq '.status'
kubectl logs -n "$NS" "$POD" --all-containers=true \
  --since=30m --timestamps --tail=5000
```

If a container restarted:

```bash
kubectl logs -n "$NS" "$POD" -c rasa --previous \
  --timestamps --tail=5000
kubectl get pod -n "$NS" "$POD" -o json | jq '
  .status.containerStatuses[] |
  {name,ready,restartCount,state,lastState}'
```

Typical meanings:

- `CrashLoopBackOff`: read current and `--previous` logs; inspect exit code and reason.
- `OOMKilled`: compare current memory, requests, and limits; inspect node pressure.
- `ImagePullBackOff`: verify image tag/digest and ECR pull permissions.
- Readiness timeout: inspect the active probe path/timeout and application latency; do not confuse readiness with liveness.
- `Pending`: inspect events for insufficient CPU/memory, taints, affinity, PVC, or maxed node group.
- `Evicted`: inspect node disk/memory pressure and pod requests.

## 7. Post-deployment validation

### 7.1 Confirm rollout convergence

```bash
kubectl rollout status deployment/rasa -n "$NS" --timeout=15m
kubectl get deployment/rasa -n "$NS" -o json | jq '
  {generation:.metadata.generation,
   observedGeneration:.status.observedGeneration,
   desired:.spec.replicas,
   updated:.status.updatedReplicas,
   ready:.status.readyReplicas,
   available:.status.availableReplicas,
   unavailable:(.status.unavailableReplicas // 0),
   conditions:.status.conditions}'
```

Healthy means observed generation equals current generation, and desired, updated, ready, and available replicas agree with zero unavailable replicas.

### 7.2 Confirm versions and images

```bash
kubectl get deploy,statefulset,daemonset -n "$NS" -o json | jq -r '
  .items[] as $w |
  ($w.spec.template.spec.containers // [])[] |
  [$w.kind,$w.metadata.name,.name,.image] | @tsv'

kubectl exec -n "$NS" deployment/rasa -c rasa -- rasa --version
kubectl rollout history deployment/rasa -n "$NS"
```

Model files, if the image/runtime stores them under `/app/models`:

```bash
kubectl exec -n "$NS" deployment/rasa -c rasa -- \
  sh -lc 'ls -lht /app/models 2>/dev/null | head -20'
```

Compare the image tag or digest and model timestamp/ID with the approved change record. A successful Kubernetes rollout with the old image is not a successful deployment.

### 7.3 Confirm pods, endpoints, resources, and events

```bash
kubectl get pods -n "$NS" -o wide
kubectl get svc,endpoints,endpointslice -n "$NS"
kubectl top nodes
kubectl top pods -n "$NS" --containers --sort-by=cpu
kubectl top pods -n "$NS" --containers --sort-by=memory
kubectl get events -n "$NS" --field-selector type=Warning \
  --sort-by='.lastTimestamp' | tail -100
```

Repeat the restart detail query from section 5.4 after 15 minutes and again after 30-60 minutes. Restart counts must not continue increasing.

### 7.4 Confirm Rasa probes and application health

First retrieve the actual probe so you test the same path and port Kubernetes uses:

```bash
kubectl get deployment/rasa -n "$NS" -o json | jq '
  .spec.template.spec.containers[] |
  select(.name=="rasa") |
  {readinessProbe,livenessProbe,startupProbe,ports}'
```

If the application exposes the normal Rasa HTTP API on port 5005, use a temporary local port-forward:

```bash
kubectl port-forward -n "$NS" deployment/rasa 5005:5005
```

In another terminal:

```bash
curl -fsS http://127.0.0.1:5005/status | jq .
```

Use the actual probe path instead if it differs. Port-forward is for inspection only; stop it with `Ctrl+C`.

Perform the team's approved bot smoke test:

- Use a test dealer/account or synthetic request, not a real customer interaction.
- Verify the expected intent/flow and response.
- Verify actions execute without timeout.
- Verify tracker events are written.
- Verify the event reaches Kafka and downstream Rasa Pro/Studio consumers.
- Verify there are no duplicate events or DLQ increase.
- Record the request/conversation ID and UTC timestamp for log correlation.

### 7.5 Compare pre and post evidence

Compare:

- Pod names, ages, images, image digests, and restart counts.
- Desired, updated, ready, and available replicas.
- Probe failures and warning events.
- Node and pod CPU/memory.
- Kafka topic replication, consumer lag, and DLQ activity.
- RDS CPU, connections, latency, queue depth, and authentication errors.
- ALB target health and HTTP 4xx/5xx, when the public endpoint changed.
- GitHub Actions result, commit SHA, and deployment revision.

## 8. Rasa, Rasa Pro Services, and Studio checks

### 8.1 Discover all Rasa-related workloads

```bash
kubectl get deploy,statefulset,pods -n "$NS" -o wide | \
  grep -Ei 'rasa|pro|studio|analytics'
```

```bash
kubectl get deploy -n "$NS" -o json | jq -r '
  .items[] |
  [.metadata.name,.spec.replicas,
   (.status.updatedReplicas // 0),
   (.status.readyReplicas // 0),
   (.status.availableReplicas // 0)] | @tsv'
```

### 8.2 Read the active tracker store section

This command is read-only, but review the output before sharing it because it contains internal connection details.

```bash
kubectl exec -n "$NS" deployment/rasa -c rasa -- \
  sed -n '/^tracker_store:/,/^[^[:space:]]/p' /app/endpoints.yml
```

Do not run `kubectl get secrets -o yaml`, do not decode Kubernetes Secrets into the evidence bundle, and do not paste credentials or tokens into tickets or chat.

### 8.3 Check recent Rasa errors

```bash
for pod in $(kubectl get pods -n "$NS" \
  -l app.kubernetes.io/name=rasa -o jsonpath='{.items[*].metadata.name}'); do
  kubectl logs -n "$NS" "$pod" -c rasa \
    --since=2h --timestamps --tail=10000
done | tee rasa-all-pods-postdeploy.log
```

```bash
rg -n -i 'error|exception|traceback|timeout|timed out|failed|oom|403|pam authentication|readiness|liveness|connection reset|pendingrollback' \
  rasa-all-pods-postdeploy.log
```

### 8.4 Check migrations and Jobs

```bash
kubectl get jobs -n "$NS" --sort-by='.metadata.creationTimestamp' -o wide
kubectl get pods -n "$NS" --selector=job-name -o wide 2>/dev/null || true
```

For a specific migration Job:

```bash
export JOB="<migration-job-name>"
kubectl describe job -n "$NS" "$JOB"
kubectl logs -n "$NS" job/"$JOB" --all-containers=true \
  --timestamps --tail=10000
```

Verify:

- The Job completed exactly as expected.
- It did not repeatedly retry or remain active.
- It did not receive an unwanted Istio sidecar that prevents completion.
- The migration version matches the candidate Rasa Services version.
- Database failures such as duplicate rows or `PendingRollbackError` are absent.

### 8.5 Check Studio and analytics symptoms

```bash
kubectl get pods -n "$NS" -o wide | grep -Ei 'studio|analytics|pro'
kubectl get events -n "$NS" --sort-by='.lastTimestamp' | \
  grep -Ei 'studio|analytics|pro|oom|unhealthy|failed'
```

For each matching deployment, inspect rollout status and logs:

```bash
kubectl rollout status -n "$NS" deployment/<deployment-name> --timeout=10m
kubectl logs -n "$NS" deployment/<deployment-name> \
  --all-containers=true --since=2h --timestamps --tail=10000
```

## 9. Kafka validation

Kafka is not just a background component. A bot can look healthy while analytics and Studio fall behind. Check broker placement, topic health, consumer lag, and DLQ activity.

### 9.1 Discover Kafka pod, service, and placement

```bash
kubectl get pods -n "$NS" -o wide | grep 'kafka-controller-'
kubectl get statefulset,pvc,svc -n "$NS" | grep -i kafka
kubectl get pods -n "$NS" -o wide \
  -l app.kubernetes.io/name=kafka 2>/dev/null || true
```

Set the first Kafka pod and verify the bootstrap service from `kubectl get svc`:

```bash
export KAFKA_POD=$(kubectl get pods -n "$NS" -o name | \
  sed -n 's#pod/\(kafka-controller-[^ ]*\)#\1#p' | head -1)
export KAFKA_BOOTSTRAP="kafka:9092"

echo "$KAFKA_POD"
echo "$KAFKA_BOOTSTRAP"
```

Do not proceed with Kafka CLI commands if the service name or listener differs. Confirm it from the service and StatefulSet configuration.

### 9.2 Broker and metadata quorum status

```bash
kubectl exec -n "$NS" "$KAFKA_POD" -c kafka -- \
  /opt/bitnami/kafka/bin/kafka-metadata-quorum.sh \
  --bootstrap-server "$KAFKA_BOOTSTRAP" describe --status
```

```bash
kubectl exec -n "$NS" "$KAFKA_POD" -c kafka -- \
  /opt/bitnami/kafka/bin/kafka-topics.sh \
  --bootstrap-server "$KAFKA_BOOTSTRAP" --list
```

Healthy means all expected controllers/brokers participate in the quorum, there is one stable leader, and the quorum is not repeatedly changing.

### 9.3 Topic partitions, replicas, and ISR

```bash
for topic in rasa rasa-events-dlq; do
  echo "===== $topic ====="
  kubectl exec -n "$NS" "$KAFKA_POD" -c kafka -- \
    /opt/bitnami/kafka/bin/kafka-topics.sh \
    --bootstrap-server "$KAFKA_BOOTSTRAP" \
    --describe --topic "$topic"
done
```

Record:

- Partition count.
- Replication factor.
- Leader for every partition.
- Replica list and in-sync replica (ISR) list.
- Any leader of `-1`, offline partition, or ISR smaller than the replica list.

The `rasa` topic previously had three partitions and replication factor 1. That is a redundancy risk, not a healthy target. Verify the live value. Do not assume a bot deployment changes replication automatically.

### 9.4 Consumer lag

```bash
for group in rasa-analytics-group studio; do
  echo "===== $group ====="
  kubectl exec -n "$NS" "$KAFKA_POD" -c kafka -- \
    /opt/bitnami/kafka/bin/kafka-consumer-groups.sh \
    --bootstrap-server "$KAFKA_BOOTSTRAP" \
    --describe --group "$group"
done
```

Calculate total lag for one group:

```bash
export GROUP="rasa-analytics-group"
kubectl exec -n "$NS" "$KAFKA_POD" -c kafka -- \
  /opt/bitnami/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server "$KAFKA_BOOTSTRAP" \
  --describe --group "$GROUP" | \
  awk 'NR > 1 && $6 ~ /^[0-9]+$/ {total += $6} END {print "TOTAL_LAG=" total+0}'
```

Current alarm references:

| Consumer group | Warning | Critical |
|---|---:|---:|
| `rasa-analytics-group` | Lag >= 5,000 for 3 of 3 five-minute periods | Lag >= 20,000 for 2 of 3 five-minute periods |
| `studio` | Lag >= 500 for 3 of 3 five-minute periods | Lag >= 2,000 for 2 of 3 five-minute periods |

The important post-deployment behavior is not only the peak: lag should return toward its pre-deployment baseline. A lag that keeps climbing means producers are outpacing or disconnected from consumers.

### 9.5 CloudWatch Kafka metrics and alarms

```bash
aws cloudwatch describe-alarms \
  --profile "$BCP_AWS_PROFILE" \
  --region "$AWS_REGION" \
  --alarm-name-prefix prod-rasa-kafka \
  --query 'MetricAlarms[].{Alarm:AlarmName,State:StateValue,Reason:StateReason,Updated:StateUpdatedTimestamp}' \
  --output table
```

```bash
for group in rasa-analytics-group studio; do
  aws cloudwatch get-metric-statistics \
    --profile "$BCP_AWS_PROFILE" \
    --region "$AWS_REGION" \
    --namespace RasaKafka \
    --metric-name ConsumerGroupTotalLag \
    --dimensions Name=ClusterName,Value=rasa Name=ConsumerGroup,Value="$group" \
    --start-time "$(python3 -c 'from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(hours=1)).isoformat())')" \
    --end-time "$(python3 -c 'from datetime import datetime,timezone; print(datetime.now(timezone.utc).isoformat())')" \
    --period 300 \
    --statistics Maximum Average
done
```

Verify `CollectorSuccess` remains `1` and the collector-unhealthy alarm is `OK`.

## 10. AWS, RDS, and load balancer checks

### 10.1 EKS control plane and add-ons

```bash
aws eks describe-cluster \
  --profile "$BCP_AWS_PROFILE" \
  --region "$AWS_REGION" \
  --name "$CLUSTER" \
  --query 'cluster.{status:status,version:version,platformVersion:platformVersion,endpoint:endpoint,logging:logging.clusterLogging}'

aws eks list-addons \
  --profile "$BCP_AWS_PROFILE" \
  --region "$AWS_REGION" \
  --cluster-name "$CLUSTER"
```

For each add-on returned:

```bash
aws eks describe-addon \
  --profile "$BCP_AWS_PROFILE" \
  --region "$AWS_REGION" \
  --cluster-name "$CLUSTER" \
  --addon-name <addon-name>
```

### 10.2 RDS instance status

Find Rasa-related DB identifiers:

```bash
aws rds describe-db-instances \
  --profile "$BCP_AWS_PROFILE" \
  --region "$AWS_REGION" \
  --query 'DBInstances[?contains(DBInstanceIdentifier, `rasa`)].{ID:DBInstanceIdentifier,Status:DBInstanceStatus,Engine:Engine,Version:EngineVersion,Endpoint:Endpoint.Address,AZ:AvailabilityZone,MultiAZ:MultiAZ}' \
  --output table
```

Set the correct identifier, especially for the analytics database:

```bash
export RDS_ID="<rasa-rds-instance-identifier>"
```

```bash
aws rds describe-db-instances \
  --profile "$BCP_AWS_PROFILE" \
  --region "$AWS_REGION" \
  --db-instance-identifier "$RDS_ID" \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Class:DBInstanceClass,Engine:Engine,Version:EngineVersion,Storage:AllocatedStorage,FreeMonitoring:MonitoringInterval,Pending:PendingModifiedValues,LatestRestorableTime:LatestRestorableTime}'
```

### 10.3 RDS CloudWatch metrics

Create portable start/end timestamps:

```bash
read START_UTC END_UTC <<EOF
$(python3 - <<'PY'
from datetime import datetime, timedelta, timezone
end = datetime.now(timezone.utc)
start = end - timedelta(hours=1)
print(start.isoformat(), end.isoformat())
PY
)
EOF
```

```bash
for metric in CPUUtilization DatabaseConnections FreeableMemory \
  ReadLatency WriteLatency DiskQueueDepth FreeStorageSpace; do
  echo "===== $metric ====="
  aws cloudwatch get-metric-statistics \
    --profile "$BCP_AWS_PROFILE" \
    --region "$AWS_REGION" \
    --namespace AWS/RDS \
    --metric-name "$metric" \
    --dimensions Name=DBInstanceIdentifier,Value="$RDS_ID" \
    --start-time "$START_UTC" \
    --end-time "$END_UTC" \
    --period 300 \
    --statistics Minimum Average Maximum \
    --output table
done
```

Compare with the pre-deployment baseline. Focus on sudden sustained changes, not one isolated point. Repeated IAM/PAM failures near a pod restart must be correlated with Rasa and `rdsauthproxy` logs at the same UTC timestamps.

### 10.4 ALB target health when the endpoint is affected

Discover the load balancer and target group rather than guessing:

```bash
aws elbv2 describe-load-balancers \
  --profile "$BCP_AWS_PROFILE" \
  --region "$AWS_REGION" \
  --query 'LoadBalancers[].{Name:LoadBalancerName,DNS:DNSName,State:State.Code,ARN:LoadBalancerArn}' \
  --output table
```

```bash
aws elbv2 describe-target-groups \
  --profile "$BCP_AWS_PROFILE" \
  --region "$AWS_REGION" \
  --load-balancer-arn <load-balancer-arn> \
  --query 'TargetGroups[].{Name:TargetGroupName,Protocol:Protocol,Port:Port,HealthPath:HealthCheckPath,ARN:TargetGroupArn}' \
  --output table
```

```bash
export TARGET_GROUP_ARN="<target-group-arn>"
aws elbv2 describe-target-health \
  --profile "$BCP_AWS_PROFILE" \
  --region "$AWS_REGION" \
  --target-group-arn "$TARGET_GROUP_ARN" \
  --query 'TargetHealthDescriptions[].{Target:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason,Description:TargetHealth.Description}' \
  --output table
```

Do not change listener rules, TLS policy, WAF, or target groups as part of a bot rollout unless those items are explicitly part of the approved change.

## 11. CloudWatch Logs Insights queries

Use the log group that contains EKS/container logs. Set the time picker to cover at least 30 minutes before the deployment through the current time, in UTC.

### 11.1 All Rasa errors and timeouts

```text
fields @timestamp, kubernetes.pod_name, kubernetes.container_name, @message
| filter kubernetes.namespace_name = "rasa"
| filter @message like /(?i)(error|exception|traceback|timeout|timed out|failed|unhealthy|oom|403|pam authentication)/
| sort @timestamp asc
| limit 10000
```

### 11.2 One pod's full timeline

```text
fields @timestamp, kubernetes.pod_name, kubernetes.container_name, @message
| filter kubernetes.namespace_name = "rasa"
| filter kubernetes.pod_name = "<pod-name>"
| sort @timestamp asc
| limit 10000
```

### 11.3 Readiness and liveness failures

```text
fields @timestamp, kubernetes.pod_name, kubernetes.container_name, @message
| filter kubernetes.namespace_name = "rasa"
| filter @message like /(?i)(readiness|liveness|probe|context deadline exceeded|i\/o timeout)/
| sort @timestamp asc
| limit 10000
```

### 11.4 IAM/RDS authentication correlation

```text
fields @timestamp, kubernetes.pod_name, kubernetes.container_name, @message
| filter kubernetes.namespace_name = "rasa"
| filter @message like /(?i)(rdsauthproxy|iam|http 403|pam authentication failed|postgres|token|retry)/
| sort @timestamp asc
| limit 10000
```

Export the query result for incidents. Preserve UTC timestamps, pod name, container name, request/conversation ID, failure, and immediate retry.

## 12. GitHub Actions deployment checks

The normal production path is the repository's deployment workflow from the approved branch/commit. The exact workflow name can be verified under `.github/workflows`; `deploy-prod.yaml` is a common production workflow filename in this repository.

```bash
gh auth status
gh workflow list
gh run list --workflow deploy-prod.yaml --branch main --limit 10
```

```bash
export RUN_ID="<github-actions-run-id>"
gh run view "$RUN_ID"
gh run watch "$RUN_ID" --exit-status
gh run view "$RUN_ID" --log-failed
```

Verify:

- The run used the intended commit SHA.
- Training completed and produced the expected model.
- Image build and push succeeded.
- Any migration completed.
- The deployment step targeted production, not dev or QA.
- The final workflow status is success.
- The cluster image and model match the workflow output.

A green GitHub Actions run does not replace post-deployment cluster checks.

## 13. New bot/model-only deployment procedure

For a bot data/domain/actions/model change without a platform version change:

1. Confirm dev/QA validation and the exact PR/commit.
2. Review changed paths and determine whether the workflow trains a model, builds an actions image, or both.
3. Capture the pre-deployment bundle.
4. Start the approved GitHub Actions production run or observe the developer-triggered run.
5. Watch the Rasa rollout, ReplicaSet, events, and logs.
6. Confirm the new image/model rather than only pod readiness.
7. Run one approved synthetic bot conversation.
8. Check tracker write, Kafka production, analytics/studio consumption, lag, DLQ, and RDS health.
9. Save the post-deployment bundle.
10. Observe 30-60 minutes and complete the deployment record.

Model-specific warning signs:

- Model cannot load or is incompatible with the runtime.
- Domain/action mismatch.
- Missing custom action or endpoint.
- NLU/flow errors only after the first real request.
- Tracker store write failures.
- Events produced but downstream consumers lag or fail.

## 14. New Rasa or Rasa Services version procedure

A runtime version upgrade has a larger blast radius than a model-only deployment.

### 14.1 Before approval

- Read the version's release notes and breaking changes.
- Confirm Rasa Pro, Rasa SDK/actions, Rasa Services, Studio, Python, database, and model compatibility.
- Confirm any required analytics database migration and whether it is reversible.
- Test the exact image tags/digests in dev and QA.
- Run training and representative conversations with the candidate version.
- Compare `endpoints.yml`, connectors, custom channels, action server dependencies, and Helm values.
- Confirm backup/snapshot requirements before a schema-changing migration.
- Define rollback image/model and the database rollback limitation.

Capture current version and image:

```bash
kubectl exec -n "$NS" deployment/rasa -c rasa -- rasa --version
kubectl get deployment/rasa -n "$NS" -o json | jq -r '
  .spec.template.spec.containers[] | [.name,.image] | @tsv'
kubectl rollout history deployment/rasa -n "$NS"
```

Review the repository change:

```bash
git diff <current-prod-sha>..<candidate-sha> -- \
  Dockerfile requirements.txt pyproject.toml poetry.lock \
  k8s/prod/values.yaml endpoints.yml .github/workflows
```

### 14.2 Deployment order

Use the order defined by the validated release plan. A typical safe order is:

1. Take required database backup/snapshot and record it.
2. Run the approved migration Job and wait for successful completion.
3. Deploy compatible Rasa Services/analytics components.
4. Deploy the Rasa runtime and actions image.
5. Confirm all rollouts and versions.
6. Run bot, tracker, Kafka, analytics, and Studio smoke tests.

Do not invent or reorder migrations in production. Follow the exact tested vendor/application procedure.

### 14.3 Extra monitoring for a version change

Run all normal checks plus:

```bash
kubectl get jobs -n "$NS" --sort-by='.metadata.creationTimestamp' -o wide
kubectl get events -n "$NS" --sort-by='.lastTimestamp' | tail -200
kubectl logs -n "$NS" deployment/rasa -c rasa \
  --since=2h --timestamps --tail=10000
```

Search for migration, deprecation, model compatibility, database, and connector errors:

```bash
rg -n -i 'migration|alembic|pendingrollback|deprecated|incompatible|model|schema|database|connector|channel|error|exception' \
  rasa-version-change.log
```

If you did not redirect the earlier log command, add `| tee rasa-version-change.log` and rerun it without `-f`.

## 15. Kubernetes, Helm, and Terraform change commands

### 15.1 Safe inspection and diff commands

These commands do not apply a change:

```bash
kubectl apply --dry-run=server -n "$NS" -f <manifest-path> -o yaml
kubectl diff -n "$NS" -f <manifest-path>
```

```bash
helm list -n "$NS"
helm status <release-name> -n "$NS"
helm history <release-name> -n "$NS"
helm get values <release-name> -n "$NS" --all
helm get manifest <release-name> -n "$NS" > current-release-manifest.yaml
helm template <release-name> <chart-path> -n "$NS" -f <prod-values.yaml> > candidate-manifest.yaml
```

If the Helm diff plugin is installed:

```bash
helm diff upgrade <release-name> <chart-path> \
  -n "$NS" -f <prod-values.yaml>
```

Terraform plan for the known autoscaling directory:

```bash
cd k8s/tf/autoscaling
terraform fmt -check -recursive
terraform init -backend-config=backends/prod.hcl
terraform validate
terraform plan -var-file=prod.tfvars -out=prod.tfplan
terraform show -no-color prod.tfplan | tee prod.tfplan.txt
```

Before applying, compare the plan with live node group sizes from section 5.3. Existing drift must be understood and approved.

### 15.2 Approved changes only

These commands change production. Use only with an approved PR/change plan, exact target verification, and rollback plan. Prefer the repository's GitHub Actions workflow.

Kubernetes manifest:

```bash
kubectl apply -n "$NS" -f <approved-manifest-path>
kubectl rollout status -n "$NS" deployment/<name> --timeout=15m
```

Helm:

```bash
helm upgrade --install <release-name> <chart-path> \
  -n "$NS" -f <prod-values.yaml> \
  --atomic --wait --timeout 15m
```

Terraform, only the previously reviewed saved plan:

```bash
terraform apply prod.tfplan
```

Emergency manual image update, only if the approved incident procedure explicitly calls for it:

```bash
kubectl set image -n "$NS" deployment/<deployment> \
  <container>=<approved-image@digest>
kubectl rollout status -n "$NS" deployment/<deployment> --timeout=15m
```

Record every manual change immediately and reconcile it back into Git to prevent drift.

## 16. Rollback and incident response

### 16.1 Pause criteria

Pause or stop the release and escalate when any of the following occurs:

- Wrong AWS account, cluster, namespace, commit, image, or model.
- Rollout does not converge within the approved window.
- Readiness/liveness failures continue beyond startup grace.
- Restart counts rise, `CrashLoopBackOff`, OOM, or unexpected pod eviction occurs.
- Rasa errors or action timeouts increase after the candidate pods receive traffic.
- Tracker store writes fail or IAM/PAM failures repeat.
- Kafka lag keeps rising, reaches critical alarm levels, ISR shrinks, or DLQ grows.
- RDS latency/connections/CPU or authentication errors materially exceed baseline.
- ALB targets become unhealthy or 5xx increases.
- Synthetic bot test fails or downstream analytics/Studio does not receive the event.

### 16.2 Inspect rollback history

```bash
kubectl rollout history deployment/rasa -n "$NS"
kubectl rollout history deployment/rasa -n "$NS" --revision=<revision>
helm history <release-name> -n "$NS"
```

### 16.3 Approved rollback only

Preferred GitOps rollback: revert the approved commit and run the normal production workflow.

Emergency Kubernetes revision rollback:

```bash
kubectl rollout undo deployment/rasa -n "$NS" --to-revision=<known-good-revision>
kubectl rollout status deployment/rasa -n "$NS" --timeout=15m
```

Helm rollback:

```bash
helm rollback <release-name> <known-good-revision> \
  -n "$NS" --wait --timeout 15m
```

Important: rolling back a Deployment or Helm revision may not reverse a database migration, Kafka topic/config change, or externally written data. Confirm the rollback compatibility before executing it.

### 16.4 Evidence to collect for an incident or Rasa Support

Include:

- Both local and UTC incident/deployment timestamps.
- Git commit, image tag/digest, model ID, workflow run, and Kubernetes revision.
- Pod name, node, container, restart count, exit code, reason, and start/finish time.
- Current and `--previous` logs for every relevant container.
- `kubectl describe pod` events and the exact readiness/liveness/startup probe active at the time.
- RDS/IAM failure and retry timestamps; state whether it was RDS or Redis.
- Kafka topic/ISR and consumer lag before, during, and after.
- RDS and node/pod resource metrics.
- Smoke-test conversation/request ID and result.
- What recovered the service: retry, new pod, rollback, scale, configuration, or no action.

Do not include passwords, tokens, decoded Secrets, customer PII, or unredacted conversation content.

## 17. Automated collector script

The companion script is `rasa-deployment-collector.sh`. It performs read-only inspection and saves timestamped text files plus a compressed evidence archive.

### 17.1 Install locally

```bash
chmod +x rasa-deployment-collector.sh
./rasa-deployment-collector.sh --help
```

### 17.2 Pre-deployment collection

```bash
./rasa-deployment-collector.sh \
  --profile "$BCP_AWS_PROFILE" \
  --phase pre \
  --since 2h
```

### 17.3 During or post-deployment collection

```bash
./rasa-deployment-collector.sh \
  --profile "$BCP_AWS_PROFILE" \
  --phase during \
  --since 1h

./rasa-deployment-collector.sh \
  --profile "$BCP_AWS_PROFILE" \
  --phase post \
  --since 2h
```

### 17.4 Full incident collection

```bash
./rasa-deployment-collector.sh \
  --profile "$BCP_AWS_PROFILE" \
  --phase incident \
  --since 4h \
  --include-describe \
  --rds-id <rasa-rds-instance-identifier> \
  --target-group-arn <target-group-arn>
```

Review the generated files before sharing. Logs and `describe` output may contain internal hostnames, request IDs, or application data even though the script intentionally does not read Kubernetes Secret values.

## 18. Go/no-go checklist

Mark the deployment **GO / healthy** only when all applicable items pass:

- [ ] Correct AWS account, production cluster, and namespace confirmed.
- [ ] Approved commit, workflow run, image, model, and version confirmed.
- [ ] All nodes Ready with no pressure and enough rollout headroom.
- [ ] All expected Deployments/StatefulSets converged; zero unexpected unavailable replicas.
- [ ] All application pods Running and Ready; expected `2/2` when Istio sidecar is present.
- [ ] Restart counts are stable; no CrashLoopBackOff, OOMKilled, eviction, or image pull error.
- [ ] Services and EndpointSlices have ready endpoints.
- [ ] Active readiness/liveness/startup probes are succeeding.
- [ ] No new unexplained Warning events.
- [ ] Rasa/model/action logs show no new error pattern.
- [ ] Tracker store reads/writes succeed; no repeated IAM/PAM failure.
- [ ] Kafka quorum stable; topic leaders/replicas/ISR healthy.
- [ ] Analytics and Studio consumer lag is stable or returning to baseline; DLQ not increasing.
- [ ] RDS status and metrics are within the pre-deployment baseline.
- [ ] ALB targets healthy when endpoint routing was in scope.
- [ ] Approved synthetic bot conversation succeeds end to end.
- [ ] Post-deployment evidence bundle saved.
- [ ] 30-60 minute observation completed without delayed regression.
- [ ] Deployment record completed and shared with the team.

## 19. Deployment record template

Copy this block into the ticket, change record, or team update.

```text
Deployment: <bot/model/Rasa/Rasa Services/config/infra change>
Environment: Production - EKS rasa / namespace rasa / us-east-1
Start time (local):
Start time (UTC):
End time (UTC):
Release owner:
DevOps observer:
PR / commit SHA:
GitHub Actions run ID / URL:

Before:
- Rasa version/image:
- Rasa Services version/image:
- Model ID/timestamp:
- Rasa desired/ready/restarts:
- Node count and nodegroup min/desired/max:
- Kafka rasa partitions/RF/ISR:
- Analytics lag / Studio lag / DLQ:
- RDS status and notable metrics:
- Existing warnings/errors:

Change performed:
- Files/components changed:
- Migration/job:
- Expected behavior:

After:
- Workflow result:
- Kubernetes rollout revision:
- Rasa version/image/model verified:
- Desired/updated/ready/available:
- New restarts/probe failures/warnings:
- Kafka lag and DLQ:
- RDS/IAM status:
- Smoke test conversation/request ID and result:
- Observation period:

Result: SUCCESS / ROLLED BACK / PARTIAL / INVESTIGATING
Rollback performed: Yes/No
Rollback revision/commit/image:
Open follow-ups:
Evidence archive filename:
```

## 20. Short team status messages

### Start message

```text
Production bot deployment monitoring has started. I confirmed the BetterCarPeople account, EKS cluster rasa, and namespace rasa and captured the pre-deployment baseline. I am watching the rollout, pod readiness/restarts, events/logs, Kafka lag, and RDS health.
```

### Success message

```text
Production bot deployment completed successfully. The expected image/model is active, all Rasa replicas are ready, restart counts are stable, Kafka lag is returning to baseline, RDS is healthy, and the end-to-end smoke test passed. I will continue observing for the remainder of the 30-60 minute validation window.
```

### Investigation message

```text
The production deployment is not yet cleared. I observed <symptom> starting at <UTC time> on <pod/component>. I am correlating rollout events, current/previous container logs, probes, Kafka lag, and RDS/IAM activity. No additional production change will be made until the cause and rollback decision are confirmed.
```

## 21. Command safety reference

| Category | Examples | Production effect |
|---|---|---|
| Read-only | `get`, `describe`, `logs`, `top`, `rollout status/history`, AWS `describe-*`, CloudWatch `get-*` | No cluster resource change |
| Local-only | `aws eks update-kubeconfig`, `kubectl port-forward`, writing evidence files | Changes local context/session only |
| Change production | `apply`, `set image`, `scale`, `rollout restart/undo`, `helm upgrade/rollback`, `terraform apply`, EKS scaling update | Requires approval and rollback plan |
| High sensitivity | Reading/decoding Secrets, dumping credentials, sharing raw logs with PII | Do not include in routine evidence |

When uncertain, stop after read-only checks and ask the release owner or lead for approval.
