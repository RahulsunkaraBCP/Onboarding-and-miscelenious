# Rasa Production Deployment and Health-Check Runbook

Use this runbook when developers deploy a new bot, model, actions change, Rasa version, Rasa Pro Services version, or Kubernetes configuration change to the production Rasa environment.

> **Safety:** All commands in this document are read-only. They inspect production but do not deploy, restart, scale, roll back, or modify resources.

## Production environment

| Setting | Value |
| --- | --- |
| AWS account | `451781105151` |
| AWS region | `us-east-1` |
| EKS cluster | `rasa` |
| Kubernetes namespace | `rasa` |
| Main Rasa deployment | `rasa` |
| Rasa Pro Services deployment | `rasa-rasa-pro-services` |
| Main Rasa container | `rasa` |
| Pro Services container | `rasa-pro-services` |

## Quick deployment-day checklist

1. Run `awslogin` and verify the AWS account and Kubernetes context.
2. Capture the current Pods, images, versions, restarts, node health, Kafka lag, RDS status, and alarms.
3. Open three terminals to watch Pods, the rollout, and Kubernetes events.
4. Watch Rasa and Pro Services logs during the deployment.
5. Confirm that all replicas become ready and use the same new image.
6. Verify Rasa health, version, loaded model, Kafka lag, warning events, resource usage, and alarms.
7. If a Pod restarts, immediately capture `describe`, current logs, and `--previous` logs before the Pod is replaced.

## 1. Log in to production

Run from a Mac terminal:

```bash
awslogin
```

Select the BetterCarPeople production account. Verify the login and Kubernetes access:

```bash
aws sts get-caller-identity --profile "$BCP_AWS_PROFILE"
kubectl config current-context
kubectl cluster-info
kubectl auth can-i get pods -n rasa
```

Expected AWS account:

```text
451781105151
```

Expected Kubernetes context:

```text
arn:aws:eks:us-east-1:451781105151:cluster/rasa
```

Do not continue if the account or cluster context is different.

## 2. Capture the pre-deployment baseline

Record the UTC start time:

```bash
date -u
```

Check cluster nodes:

```bash
kubectl get nodes -o wide
kubectl top nodes
```

Check all workloads:

```bash
kubectl get deployments,statefulsets,daemonsets -n rasa -o wide
kubectl get pods -n rasa -o wide
kubectl top pods -n rasa --containers
```

Check Pod readiness, restarts, termination reasons, exit codes, and placement:

```bash
kubectl get pods -n rasa \
  -o custom-columns='POD:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,LAST_REASON:.status.containerStatuses[*].lastState.terminated.reason,LAST_EXIT:.status.containerStatuses[*].lastState.terminated.exitCode,NODE:.spec.nodeName'
```

List Pods that are not `Running` or `Completed`:

```bash
kubectl get pods -n rasa | grep -Ev 'Running|Completed|NAME'
```

No output is the healthy result.

Check warning events:

```bash
kubectl get events -n rasa \
  --field-selector type=Warning \
  --sort-by=.lastTimestamp
```

Check the 50 most recent events:

```bash
kubectl get events -n rasa \
  --sort-by=.lastTimestamp | tail -50
```

Check services, endpoints, ingress, jobs, and autoscaling objects:

```bash
kubectl get services,endpoints,ingress -n rasa -o wide
kubectl get endpointslices -n rasa
kubectl get jobs,cronjobs -n rasa
kubectl get hpa,pdb -n rasa
```

## 3. Capture current deployments, images, and versions

Check the two main deployments:

```bash
kubectl get deployment rasa rasa-rasa-pro-services -n rasa -o wide
```

Show images for every deployment:

```bash
kubectl get deployments -n rasa \
  -o custom-columns='DEPLOYMENT:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas,AVAILABLE:.status.availableReplicas,IMAGES:.spec.template.spec.containers[*].image'
```

Show images for every StatefulSet:

```bash
kubectl get statefulsets -n rasa \
  -o custom-columns='STATEFULSET:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas,IMAGES:.spec.template.spec.containers[*].image'
```

Show the exact Rasa image and image ID on every main Rasa Pod:

```bash
kubectl get pods -n rasa \
  -l app.kubernetes.io/name=rasa \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[?(@.name=="rasa")].image}{"\t"}{.status.containerStatuses[?(@.name=="rasa")].imageID}{"\n"}{end}'
```

Check the installed Rasa version:

```bash
kubectl exec -n rasa deploy/rasa -c rasa -- rasa --version
```

Show Pro Services images and image IDs:

```bash
kubectl get pods -n rasa \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].image}{"\t"}{.status.containerStatuses[*].imageID}{"\n"}{end}' \
  | grep rasa-pro-services
```

Check rollout history before the change:

```bash
kubectl rollout history deployment/rasa -n rasa
kubectl rollout history deployment/rasa-rasa-pro-services -n rasa
```

## 4. Watch the deployment live

After running `awslogin`, use three terminal windows.

### Terminal 1: watch Pods

```bash
kubectl get pods -n rasa -w
```

### Terminal 2: watch the Rasa rollout

```bash
kubectl rollout status deployment/rasa \
  -n rasa \
  --timeout=15m
```

If Pro Services is also changing:

```bash
kubectl rollout status deployment/rasa-rasa-pro-services \
  -n rasa \
  --timeout=15m
```

### Terminal 3: watch Kubernetes events

```bash
kubectl get events -n rasa \
  --sort-by=.lastTimestamp \
  --watch
```

Use `Control+C` to stop a watch command.

## 5. Check rollout progress and ReplicaSets

```bash
kubectl get deployment rasa rasa-rasa-pro-services -n rasa
kubectl rollout history deployment/rasa -n rasa
kubectl rollout history deployment/rasa-rasa-pro-services -n rasa
kubectl get replicasets -n rasa --sort-by=.metadata.creationTimestamp
```

Check deployment conditions and recent events:

```bash
kubectl describe deployment rasa -n rasa
kubectl describe deployment rasa-rasa-pro-services -n rasa
```

## 6. Watch Rasa logs

Get recent logs from all main Rasa Pods:

```bash
kubectl logs -n rasa \
  -l app.kubernetes.io/name=rasa \
  -c rasa \
  --since=30m \
  --timestamps \
  --prefix \
  --max-log-requests=20
```

Continuously follow all main Rasa Pods:

```bash
kubectl logs -n rasa \
  -l app.kubernetes.io/name=rasa \
  -c rasa \
  --follow \
  --tail=100 \
  --timestamps \
  --prefix \
  --max-log-requests=20
```

Filter for possible errors:

```bash
kubectl logs -n rasa \
  -l app.kubernetes.io/name=rasa \
  -c rasa \
  --since=30m \
  --timestamps \
  --prefix \
  --max-log-requests=20 2>&1 \
  | grep -Eai 'error|exception|traceback|fatal|panic|failed|timeout|readiness|liveness|oom|403|pam|authentication'
```

> The filter can include harmless messages. Review the timestamp and surrounding log lines before treating a match as an incident.

## 7. Watch Rasa Pro Services logs

Get recent logs from every Pro Services Pod:

```bash
for pod_name in $(kubectl get pods -n rasa -o name | grep '^pod/rasa-rasa-pro-services-'); do
  kubectl logs -n rasa "$pod_name" \
    -c rasa-pro-services \
    --since=30m \
    --timestamps \
    --prefix
done
```

Filter Pro Services logs for errors:

```bash
for pod_name in $(kubectl get pods -n rasa -o name | grep '^pod/rasa-rasa-pro-services-'); do
  kubectl logs -n rasa "$pod_name" \
    -c rasa-pro-services \
    --since=30m \
    --timestamps \
    --prefix 2>&1
done | grep -Eai 'error|exception|traceback|fatal|panic|failed|timeout|migration|rollback|kafka|postgres|database'
```

Check the analytics migration flag on all Pro Services Pods:

```bash
for pod_name in $(kubectl get pods -n rasa -o name | grep '^pod/rasa-rasa-pro-services-'); do
  printf '%s: ' "$pod_name"
  kubectl exec -n rasa "$pod_name" -c rasa-pro-services -- \
    printenv RUN_ANALYTICS_DB_MIGRATIONS
done
```

## 8. If a Pod restarts or fails

Immediately identify the affected Pod:

```bash
kubectl get pods -n rasa \
  -o custom-columns='POD:.metadata.name,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,LAST_REASON:.status.containerStatuses[*].lastState.terminated.reason,LAST_EXIT:.status.containerStatuses[*].lastState.terminated.exitCode'
```

Set the affected Pod name:

```bash
RASA_POD="replace-with-pod-name"
```

Describe the Pod:

```bash
kubectl describe pod "$RASA_POD" -n rasa
```

Get current Rasa logs:

```bash
kubectl logs "$RASA_POD" \
  -n rasa \
  -c rasa \
  --since=1h \
  --timestamps
```

Get logs from the previous, crashed Rasa container:

```bash
kubectl logs "$RASA_POD" \
  -n rasa \
  -c rasa \
  --previous \
  --timestamps
```

Check every container's current and previous state:

```bash
kubectl get pod "$RASA_POD" -n rasa \
  -o jsonpath='{range .status.containerStatuses[*]}{"Container: "}{.name}{"\nReady: "}{.ready}{"\nRestarts: "}{.restartCount}{"\nCurrent: "}{.state}{"\nPrevious: "}{.lastState}{"\n\n"}{end}'
```

Check the Pod's node:

```bash
kubectl get pod "$RASA_POD" -n rasa -o wide
RASA_NODE=$(kubectl get pod "$RASA_POD" -n rasa -o jsonpath='{.spec.nodeName}')
kubectl describe node "$RASA_NODE"
kubectl top node "$RASA_NODE"
```

Check events associated with the Pod:

```bash
kubectl get events -n rasa \
  --field-selector involvedObject.name="$RASA_POD" \
  --sort-by=.lastTimestamp
```

> Capture `--previous` logs before the failed Pod is deleted. Kubernetes cannot retrieve the previous container's logs after the Pod object has been replaced.

## 9. Check Rasa health, version, and loaded bot model

In one terminal, start local port-forwarding:

```bash
kubectl port-forward -n rasa deployment/rasa 5005:5005
```

In a second terminal, run:

```bash
curl -i http://127.0.0.1:5005/
curl -sS http://127.0.0.1:5005/version
curl -i http://127.0.0.1:5005/status
```

The root endpoint should return HTTP `200`. The `/version` endpoint shows the running version. The `/status` endpoint shows the loaded model when authentication permits it.

The `/status` endpoint may return `401` if API authentication is enabled. Do not copy API tokens into terminal history or this file.

Check model-loading log messages:

```bash
kubectl logs -n rasa \
  -l app.kubernetes.io/name=rasa \
  -c rasa \
  --since=1h \
  --prefix \
  --max-log-requests=20 2>&1 \
  | grep -Eai 'model|loading|loaded|assistant|version'
```

Stop port-forwarding with `Control+C`.

## 10. Check readiness, liveness, and startup probes

```bash
kubectl describe deployment rasa -n rasa

kubectl get deployment rasa -n rasa -o yaml \
  | grep -A20 -E 'readinessProbe:|livenessProbe:|startupProbe:'
```

Search recent events for probe failures:

```bash
kubectl get events -n rasa \
  --sort-by=.lastTimestamp \
  | grep -Eai 'readiness|liveness|startup|unhealthy|probe|timeout'
```

Search Rasa logs for probe and timeout messages:

```bash
kubectl logs -n rasa \
  -l app.kubernetes.io/name=rasa \
  -c rasa \
  --since=1h \
  --prefix \
  --max-log-requests=20 2>&1 \
  | grep -Eai 'readiness|liveness|startup|probe|timeout|timed out'
```

## 11. Check Kafka brokers, topics, and consumer lag

Check Kafka resources and utilization:

```bash
kubectl get statefulsets -n rasa | grep kafka
kubectl get pods -n rasa -o wide | grep kafka
kubectl top pods -n rasa --containers | grep kafka
kubectl get services -n rasa | grep kafka
```

Check the main `rasa` topic's partitions, replicas, and ISR:

```bash
kubectl exec -n rasa kafka-controller-0 -c kafka -- \
  /opt/bitnami/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 \
  --describe \
  --topic rasa
```

Check the DLQ topic:

```bash
kubectl exec -n rasa kafka-controller-0 -c kafka -- \
  /opt/bitnami/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 \
  --describe \
  --topic rasa-events-dlq
```

Check analytics consumer lag:

```bash
kubectl exec -n rasa kafka-controller-0 -c kafka -- \
  /opt/bitnami/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --describe \
  --group rasa-analytics-group
```

Check Studio consumer lag:

```bash
kubectl exec -n rasa kafka-controller-0 -c kafka -- \
  /opt/bitnami/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --describe \
  --group studio
```

Review these Kafka fields:

- `Leader` must be assigned.
- `Replicas` shows the configured replicas.
- `Isr` should contain all expected in-sync replicas.
- `LAG` should not grow continuously after deployment.

## 12. Check EKS node groups

List node groups:

```bash
aws eks list-nodegroups \
  --cluster-name rasa \
  --region us-east-1 \
  --profile "$BCP_AWS_PROFILE"
```

Display status, capacity, and Kubernetes version for every node group:

```bash
for nodegroup_name in $(aws eks list-nodegroups \
  --cluster-name rasa \
  --region us-east-1 \
  --profile "$BCP_AWS_PROFILE" \
  --query 'nodegroups[]' \
  --output text); do
  aws eks describe-nodegroup \
    --cluster-name rasa \
    --nodegroup-name "$nodegroup_name" \
    --region us-east-1 \
    --profile "$BCP_AWS_PROFILE" \
    --query 'nodegroup.{Name:nodegroupName,Status:status,Min:scalingConfig.minSize,Desired:scalingConfig.desiredSize,Max:scalingConfig.maxSize,Version:version}' \
    --output table
done
```

Check for node pressure or scheduling problems:

```bash
kubectl get nodes \
  -o custom-columns='NODE:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,MEMORY_PRESSURE:.status.conditions[?(@.type=="MemoryPressure")].status,DISK_PRESSURE:.status.conditions[?(@.type=="DiskPressure")].status,PID_PRESSURE:.status.conditions[?(@.type=="PIDPressure")].status'
```

## 13. Check RDS status and database errors

```bash
aws rds describe-db-instances \
  --region us-east-1 \
  --profile "$BCP_AWS_PROFILE" \
  --query 'DBInstances[].{DB:DBInstanceIdentifier,Status:DBInstanceStatus,Engine:Engine,Version:EngineVersion,Class:DBInstanceClass,Endpoint:Endpoint.Address}' \
  --output table
```

All production databases used by Rasa should report `available`.

Search Rasa logs for RDS, PostgreSQL, IAM, and authentication problems:

```bash
kubectl logs -n rasa \
  -l app.kubernetes.io/name=rasa \
  -c rasa \
  --since=1h \
  --prefix \
  --max-log-requests=20 2>&1 \
  | grep -Eai 'postgres|rds|rdsauthproxy|pam|iam|authentication|403|connection refused|connection reset|database'
```

## 14. Check CloudWatch alarms

Show alarms currently in `ALARM`:

```bash
aws cloudwatch describe-alarms \
  --state-value ALARM \
  --region us-east-1 \
  --profile "$BCP_AWS_PROFILE" \
  --query 'MetricAlarms[].{Alarm:AlarmName,Metric:MetricName,Reason:StateReason,Updated:StateUpdatedTimestamp}' \
  --output table
```

Show alarms in `INSUFFICIENT_DATA`:

```bash
aws cloudwatch describe-alarms \
  --state-value INSUFFICIENT_DATA \
  --region us-east-1 \
  --profile "$BCP_AWS_PROFILE" \
  --query 'MetricAlarms[].{Alarm:AlarmName,Metric:MetricName,Reason:StateReason,Updated:StateUpdatedTimestamp}' \
  --output table
```

Check Rasa/Kafka alarm states:

```bash
aws cloudwatch describe-alarms \
  --region us-east-1 \
  --profile "$BCP_AWS_PROFILE" \
  --query 'MetricAlarms[?contains(AlarmName, `rasa`) || contains(AlarmName, `kafka`)].{Alarm:AlarmName,State:StateValue,Metric:MetricName,Reason:StateReason}' \
  --output table
```

## 15. Final post-deployment validation

Record the UTC completion time:

```bash
date -u
```

Confirm both rollouts:

```bash
kubectl rollout status deployment/rasa -n rasa --timeout=15m
kubectl rollout status deployment/rasa-rasa-pro-services -n rasa --timeout=15m
```

Recheck deployments, Pods, and restarts:

```bash
kubectl get deployment rasa rasa-rasa-pro-services -n rasa -o wide
kubectl get pods -n rasa -o wide

kubectl get pods -n rasa \
  -o custom-columns='POD:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[*].ready,RESTARTS:.status.containerStatuses[*].restartCount,LAST_REASON:.status.containerStatuses[*].lastState.terminated.reason,LAST_EXIT:.status.containerStatuses[*].lastState.terminated.exitCode,NODE:.spec.nodeName'
```

Confirm the new Rasa image and image ID are consistent across replicas:

```bash
kubectl get pods -n rasa \
  -l app.kubernetes.io/name=rasa \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[?(@.name=="rasa")].image}{"\t"}{.status.containerStatuses[?(@.name=="rasa")].imageID}{"\n"}{end}'
```

Confirm the running Rasa version:

```bash
kubectl exec -n rasa deploy/rasa -c rasa -- rasa --version
```

Recheck resource usage:

```bash
kubectl top nodes
kubectl top pods -n rasa --containers
```

Recheck warning events and active alarms:

```bash
kubectl get events -n rasa --field-selector type=Warning --sort-by=.lastTimestamp

aws cloudwatch describe-alarms \
  --state-value ALARM \
  --region us-east-1 \
  --profile "$BCP_AWS_PROFILE" \
  --query 'MetricAlarms[].{Alarm:AlarmName,Metric:MetricName,Reason:StateReason,Updated:StateUpdatedTimestamp}' \
  --output table
```

Recheck Kafka lag:

```bash
kubectl exec -n rasa kafka-controller-0 -c kafka -- \
  /opt/bitnami/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --describe \
  --group rasa-analytics-group

kubectl exec -n rasa kafka-controller-0 -c kafka -- \
  /opt/bitnami/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --describe \
  --group studio
```

## Healthy deployment criteria

The deployment can be considered healthy when all of the following are true:

- `deployment/rasa` reports `successfully rolled out`.
- If changed, `deployment/rasa-rasa-pro-services` reports `successfully rolled out`.
- Desired, ready, and available replica counts match.
- Main Rasa and Pro Services Pods show `2/2 Running` because the application container and Istio sidecar are ready.
- Restart counts do not unexpectedly increase.
- There are no Pods in `Pending`, `CrashLoopBackOff`, `ImagePullBackOff`, `ErrImagePull`, or `CreateContainerConfigError`.
- No container terminated with `OOMKilled` or a non-zero exit code.
- All Rasa replicas use the same intended image and image ID.
- `rasa --version` reports the intended version.
- The Rasa health endpoint returns HTTP `200`.
- The intended new bot/model is loaded.
- Readiness, liveness, and startup probes are succeeding.
- Kafka topic leaders are assigned and expected replicas remain in the ISR.
- Analytics and Studio consumer lag do not continue increasing.
- Nodes are `Ready` without memory, disk, or PID pressure.
- RDS instances are `available`, with no repeated IAM/PAM authentication failures.
- No relevant CloudWatch alarm is in the `ALARM` state.

## Escalation evidence to save

If the deployment is unhealthy, capture:

```bash
date -u
kubectl config current-context
kubectl get deployment rasa rasa-rasa-pro-services -n rasa -o wide
kubectl get pods -n rasa -o wide
kubectl get events -n rasa --sort-by=.lastTimestamp | tail -100
kubectl describe deployment rasa -n rasa
kubectl rollout history deployment/rasa -n rasa
```

For every affected Pod, save:

```bash
kubectl describe pod <POD_NAME> -n rasa
kubectl logs <POD_NAME> -n rasa -c rasa --since=1h --timestamps
kubectl logs <POD_NAME> -n rasa -c rasa --previous --timestamps
```

Include these details in the escalation:

- Deployment start and failure timestamps in UTC.
- Commit, pull request, GitHub Actions run, and intended image/version.
- Previous and new Rasa image tags.
- Previous and new Rasa version.
- Affected Pod names and nodes.
- Restart count, termination reason, and exit code.
- Readiness/liveness failure timestamps and active probe settings.
- RDS/IAM/PAM errors and whether the immediate retry succeeded.
- Kafka lag before and after deployment.
- Relevant CloudWatch alarms.
- Whether production traffic or calls were affected.

---

Last updated: 2026-08-13

