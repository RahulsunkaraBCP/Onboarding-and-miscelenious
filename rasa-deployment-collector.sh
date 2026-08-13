#!/usr/bin/env bash

# Read-only production evidence collector for the BetterCarPeople Rasa platform.
# It never calls kubectl apply/patch/delete/scale/set-image/rollout-undo/restart,
# Helm upgrade/rollback, Terraform apply, or an AWS mutation API.

set -u

SCRIPT_VERSION="1.0.0"
PHASE="post"
BCP_PROFILE=""
AWS_REGION_NAME="us-east-1"
CLUSTER_NAME="rasa"
NAMESPACE_NAME="rasa"
NODEGROUP_NAME="node-group-green-20260317165903002100000001"
KUBE_CONTEXT=""
SINCE_WINDOW="2h"
LOG_TAIL="10000"
OUTPUT_DIR=""
INCLUDE_DESCRIBE="false"
SKIP_LOGS="false"
SKIP_AWS="false"
SKIP_KAFKA="false"
RDS_IDENTIFIER=""
TARGET_GROUP_ARN=""
KAFKA_BOOTSTRAP="kafka:9092"
KAFKA_CONTAINER="kafka"
REPO_DIR="."

usage() {
  cat <<'EOF'
Rasa production deployment collector (read-only)

Usage:
  ./rasa-deployment-collector.sh [options]

Options:
  --phase pre|during|post|incident  Evidence label (default: post)
  --profile NAME                   AWS CLI profile name
  --region REGION                  AWS region (default: us-east-1)
  --cluster NAME                   EKS cluster (default: rasa)
  --namespace NAME                 Kubernetes namespace (default: rasa)
  --nodegroup NAME                 EKS managed node group
  --context NAME                   Explicit kubectl context
  --since DURATION                 Log lookback, for example 30m, 2h, 4h
  --tail LINES                     Maximum log lines per container (default: 10000)
  --output-dir PATH                Output directory (default: timestamped directory)
  --include-describe               Include full pod descriptions (review before sharing)
  --skip-logs                      Do not collect container logs
  --no-aws                         Skip AWS/EKS/RDS/CloudWatch checks
  --no-kafka                       Skip Kafka CLI checks
  --rds-id ID                      Collect one hour of AWS/RDS metrics for this DB
  --target-group-arn ARN           Collect ALB target health for this target group
  --kafka-bootstrap HOST:PORT      Kafka bootstrap service (default: kafka:9092)
  --kafka-container NAME           Kafka container name (default: kafka)
  --repo PATH                      Git repository to inspect (default: current directory)
  -h, --help                       Show this help

Examples:
  ./rasa-deployment-collector.sh --profile bcp --phase pre --since 2h
  ./rasa-deployment-collector.sh --profile bcp --phase post --since 2h
  ./rasa-deployment-collector.sh --profile bcp --phase incident --since 4h \
    --include-describe --rds-id rasa-analytics

Safety:
  The script is read-only against Kubernetes and AWS. It does not read or
  decode Kubernetes Secret values. Logs and optional pod descriptions can
  still contain internal hostnames, request IDs, or application/customer data;
  review and redact the output before sharing it outside the approved team.
EOF
}

need_value() {
  if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
    echo "Missing value for $1" >&2
    exit 2
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --phase)
      need_value "$@"; PHASE="$2"; shift 2 ;;
    --profile)
      need_value "$@"; BCP_PROFILE="$2"; shift 2 ;;
    --region)
      need_value "$@"; AWS_REGION_NAME="$2"; shift 2 ;;
    --cluster)
      need_value "$@"; CLUSTER_NAME="$2"; shift 2 ;;
    --namespace)
      need_value "$@"; NAMESPACE_NAME="$2"; shift 2 ;;
    --nodegroup)
      need_value "$@"; NODEGROUP_NAME="$2"; shift 2 ;;
    --context)
      need_value "$@"; KUBE_CONTEXT="$2"; shift 2 ;;
    --since)
      need_value "$@"; SINCE_WINDOW="$2"; shift 2 ;;
    --tail)
      need_value "$@"; LOG_TAIL="$2"; shift 2 ;;
    --output-dir)
      need_value "$@"; OUTPUT_DIR="$2"; shift 2 ;;
    --include-describe)
      INCLUDE_DESCRIBE="true"; shift ;;
    --skip-logs)
      SKIP_LOGS="true"; shift ;;
    --no-aws)
      SKIP_AWS="true"; shift ;;
    --no-kafka)
      SKIP_KAFKA="true"; shift ;;
    --rds-id)
      need_value "$@"; RDS_IDENTIFIER="$2"; shift 2 ;;
    --target-group-arn)
      need_value "$@"; TARGET_GROUP_ARN="$2"; shift 2 ;;
    --kafka-bootstrap)
      need_value "$@"; KAFKA_BOOTSTRAP="$2"; shift 2 ;;
    --kafka-container)
      need_value "$@"; KAFKA_CONTAINER="$2"; shift 2 ;;
    --repo)
      need_value "$@"; REPO_DIR="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

case "$PHASE" in
  pre|during|post|incident) ;;
  *)
    echo "Invalid --phase '$PHASE'; use pre, during, post, or incident." >&2
    exit 2 ;;
esac

case "$LOG_TAIL" in
  ''|*[!0-9]*)
    echo "--tail must be a positive integer." >&2
    exit 2 ;;
esac

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is required but was not found." >&2
  exit 1
fi

UTC_STAMP=$(date -u '+%Y%m%dT%H%M%SZ')
if [ -z "$OUTPUT_DIR" ]; then
  OUTPUT_DIR="rasa-deployment-${PHASE}-${UTC_STAMP}"
fi

if [ -e "$OUTPUT_DIR" ] && [ -n "$(ls -A "$OUTPUT_DIR" 2>/dev/null)" ]; then
  echo "Refusing to overwrite non-empty output directory: $OUTPUT_DIR" >&2
  exit 2
fi

mkdir -p "$OUTPUT_DIR"

COMMAND_INDEX="$OUTPUT_DIR/COMMAND_INDEX.txt"
: > "$COMMAND_INDEX"

kube() {
  if [ -n "$KUBE_CONTEXT" ]; then
    kubectl --context "$KUBE_CONTEXT" "$@"
  else
    kubectl "$@"
  fi
}

bcp_aws() {
  if [ -n "$BCP_PROFILE" ]; then
    aws --profile "$BCP_PROFILE" --region "$AWS_REGION_NAME" "$@"
  else
    aws --region "$AWS_REGION_NAME" "$@"
  fi
}

print_command() {
  printf '$'
  printf ' %q' "$@"
  printf '\n'
}

run_cmd() {
  local output_file="$1"
  shift
  {
    echo "Collected UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    print_command "$@"
    echo
    "$@"
    local rc=$?
    echo
    echo "Exit code: $rc"
  } > "$OUTPUT_DIR/$output_file" 2>&1

  {
    printf '%s\t' "$output_file"
    print_command "$@"
  } >> "$COMMAND_INDEX"
  return 0
}

collect_metadata() {
  echo "collector_version=$SCRIPT_VERSION"
  echo "phase=$PHASE"
  echo "collected_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "local_time=$(date '+%Y-%m-%dT%H:%M:%S%z')"
  echo "host=$(hostname 2>/dev/null || true)"
  echo "user=$(id -un 2>/dev/null || true)"
  echo "uname=$(uname -a 2>/dev/null || true)"
  echo "aws_profile=${BCP_PROFILE:-default-resolution}"
  echo "aws_region=$AWS_REGION_NAME"
  echo "cluster=$CLUSTER_NAME"
  echo "namespace=$NAMESPACE_NAME"
  echo "nodegroup=$NODEGROUP_NAME"
  echo "kube_context=${KUBE_CONTEXT:-current-context}"
  echo "log_since=$SINCE_WINDOW"
  echo "log_tail=$LOG_TAIL"
  echo "include_describe=$INCLUDE_DESCRIBE"
  echo "skip_logs=$SKIP_LOGS"
  echo "skip_aws=$SKIP_AWS"
  echo "skip_kafka=$SKIP_KAFKA"
  echo "rds_identifier=${RDS_IDENTIFIER:-not-set}"
  echo "target_group_arn=${TARGET_GROUP_ARN:-not-set}"
  echo "kafka_bootstrap=$KAFKA_BOOTSTRAP"
  echo "repo_dir=$REPO_DIR"
}

collect_tool_versions() {
  command -v aws >/dev/null 2>&1 && aws --version 2>&1 || echo "aws: not found"
  kubectl version --client=true 2>&1 || true
  command -v jq >/dev/null 2>&1 && jq --version 2>&1 || echo "jq: not found"
  command -v git >/dev/null 2>&1 && git --version 2>&1 || echo "git: not found"
  command -v gh >/dev/null 2>&1 && gh --version 2>&1 | head -1 || echo "gh: not found"
  command -v helm >/dev/null 2>&1 && helm version 2>&1 || echo "helm: not found"
  command -v terraform >/dev/null 2>&1 && terraform version 2>&1 || echo "terraform: not found"
  command -v istioctl >/dev/null 2>&1 && istioctl version --remote=false 2>&1 || echo "istioctl: not found"
}

collect_node_conditions() {
  if command -v jq >/dev/null 2>&1; then
    kube get nodes -o json | jq -r '
      .items[] |
      .metadata.name as $n |
      .status.conditions[] |
      select(.type=="Ready" or .type=="MemoryPressure" or
             .type=="DiskPressure" or .type=="PIDPressure") |
      [$n,.type,.status,.reason,(.message // "-")] | @tsv'
  else
    echo "jq is not installed; showing kubectl describe condition excerpts."
    kube describe nodes | grep -E '^(Name:|Conditions:|  (Ready|MemoryPressure|DiskPressure|PIDPressure))' || true
  fi
}

collect_workload_images() {
  if command -v jq >/dev/null 2>&1; then
    kube get deployment,statefulset,daemonset -n "$NAMESPACE_NAME" -o json | jq -r '
      .items[] as $w |
      ($w.spec.template.spec.containers // [])[] |
      [$w.kind,$w.metadata.name,.name,.image] | @tsv'
  else
    kube get deployment,statefulset,daemonset -n "$NAMESPACE_NAME" \
      -o custom-columns='KIND:.kind,NAME:.metadata.name,IMAGES:.spec.template.spec.containers[*].image'
  fi
}

collect_restart_details() {
  if command -v jq >/dev/null 2>&1; then
    kube get pods -n "$NAMESPACE_NAME" -o json | jq -r '
      .items[] as $p |
      ($p.status.containerStatuses // [])[] |
      [$p.metadata.name,.name,.ready,.restartCount,
       (.state.waiting.reason // .state.terminated.reason // "Running"),
       (.lastState.terminated.reason // "-"),
       (.lastState.terminated.exitCode // "-"),
       (.lastState.terminated.finishedAt // "-")] | @tsv'
  else
    kube get pods -n "$NAMESPACE_NAME" \
      -o custom-columns='POD:.metadata.name,PHASE:.status.phase,RESTARTS:.status.containerStatuses[*].restartCount'
  fi
}

collect_probe_resources() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required for the compact probe/resource report."
    return 0
  fi
  kube get deployment,statefulset -n "$NAMESPACE_NAME" -o json | jq '
    .items[] |
    {kind,workload:.metadata.name,
     containers:[.spec.template.spec.containers[] |
       {name,image,readinessProbe,livenessProbe,startupProbe,resources}]}'
}

collect_pod_logs() {
  local pod_lines
  pod_lines=$(kube get pods -n "$NAMESPACE_NAME" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{range .spec.containers[*]}{.name}{" "}{end}{"\n"}{end}' 2>/dev/null)

  printf '%s\n' "$pod_lines" | while IFS='|' read -r pod containers; do
    [ -n "$pod" ] || continue
    for container in $containers; do
      echo
      echo "===== CURRENT LOG: pod=$pod container=$container ====="
      kube logs -n "$NAMESPACE_NAME" "$pod" -c "$container" \
        --since="$SINCE_WINDOW" --timestamps --tail="$LOG_TAIL" 2>&1 || true
    done
  done
}

collect_previous_logs() {
  local pod_lines
  pod_lines=$(kube get pods -n "$NAMESPACE_NAME" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{range .spec.containers[*]}{.name}{" "}{end}{"\n"}{end}' 2>/dev/null)

  printf '%s\n' "$pod_lines" | while IFS='|' read -r pod containers; do
    [ -n "$pod" ] || continue
    for container in $containers; do
      echo
      echo "===== PREVIOUS LOG ATTEMPT: pod=$pod container=$container ====="
      kube logs -n "$NAMESPACE_NAME" "$pod" -c "$container" \
        --previous --timestamps --tail="$LOG_TAIL" 2>&1 || true
    done
  done
}

collect_pod_descriptions() {
  local pod
  for pod in $(kube get pods -n "$NAMESPACE_NAME" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    echo
    echo "===== DESCRIBE POD: $pod ====="
    kube describe pod -n "$NAMESPACE_NAME" "$pod" 2>&1 || true
  done
}

collect_rasa_version() {
  kube exec -n "$NAMESPACE_NAME" deployment/rasa -c rasa -- rasa --version
}

collect_rasa_models() {
  kube exec -n "$NAMESPACE_NAME" deployment/rasa -c rasa -- \
    sh -lc 'ls -lht /app/models 2>/dev/null | head -20'
}

discover_kafka_pod() {
  kube get pods -n "$NAMESPACE_NAME" -o name 2>/dev/null | \
    sed -n 's#pod/\(kafka-controller-[^ ]*\)#\1#p' | head -1
}

collect_kafka_quorum() {
  local kafka_pod
  kafka_pod=$(discover_kafka_pod)
  if [ -z "$kafka_pod" ]; then
    echo "No kafka-controller-* pod found."
    return 0
  fi
  echo "Kafka pod: $kafka_pod"
  echo "Bootstrap: $KAFKA_BOOTSTRAP"
  kube exec -n "$NAMESPACE_NAME" "$kafka_pod" -c "$KAFKA_CONTAINER" -- \
    /opt/bitnami/kafka/bin/kafka-metadata-quorum.sh \
    --bootstrap-server "$KAFKA_BOOTSTRAP" describe --status
}

collect_kafka_topics() {
  local kafka_pod topic
  kafka_pod=$(discover_kafka_pod)
  if [ -z "$kafka_pod" ]; then
    echo "No kafka-controller-* pod found."
    return 0
  fi

  kube exec -n "$NAMESPACE_NAME" "$kafka_pod" -c "$KAFKA_CONTAINER" -- \
    /opt/bitnami/kafka/bin/kafka-topics.sh \
    --bootstrap-server "$KAFKA_BOOTSTRAP" --list 2>&1 || true

  for topic in rasa rasa-events-dlq; do
    echo
    echo "===== TOPIC: $topic ====="
    kube exec -n "$NAMESPACE_NAME" "$kafka_pod" -c "$KAFKA_CONTAINER" -- \
      /opt/bitnami/kafka/bin/kafka-topics.sh \
      --bootstrap-server "$KAFKA_BOOTSTRAP" \
      --describe --topic "$topic" 2>&1 || true
  done
}

collect_kafka_groups() {
  local kafka_pod group
  kafka_pod=$(discover_kafka_pod)
  if [ -z "$kafka_pod" ]; then
    echo "No kafka-controller-* pod found."
    return 0
  fi

  for group in rasa-analytics-group studio; do
    echo
    echo "===== CONSUMER GROUP: $group ====="
    kube exec -n "$NAMESPACE_NAME" "$kafka_pod" -c "$KAFKA_CONTAINER" -- \
      /opt/bitnami/kafka/bin/kafka-consumer-groups.sh \
      --bootstrap-server "$KAFKA_BOOTSTRAP" \
      --describe --group "$group" 2>&1 || true
  done
}

collect_git_state() {
  if ! command -v git >/dev/null 2>&1; then
    echo "git is not installed."
    return 0
  fi
  if ! git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "$REPO_DIR is not a Git working tree."
    return 0
  fi

  echo "===== STATUS ====="
  git -C "$REPO_DIR" status --short --branch
  echo
  echo "===== CURRENT COMMIT ====="
  git -C "$REPO_DIR" log -1 --date=iso \
    --format='commit=%H%nshort=%h%nauthor=%an%ndate=%ad%nsubject=%s'
  echo
  echo "===== LAST 10 COMMITS ====="
  git -C "$REPO_DIR" log -10 --oneline --decorate
  echo
  echo "===== REMOTES ====="
  git -C "$REPO_DIR" remote -v
}

collect_github_runs() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "gh is not installed."
    return 0
  fi
  if ! git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "$REPO_DIR is not a Git working tree."
    return 0
  fi
  (
    cd "$REPO_DIR" || exit 1
    gh auth status 2>&1 || true
    echo
    gh run list --limit 10 2>&1 || true
  )
}

collect_rds_metrics() {
  if [ -z "$RDS_IDENTIFIER" ]; then
    echo "No --rds-id supplied; RDS metric collection skipped."
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required to produce portable UTC metric timestamps."
    return 0
  fi

  local time_range start_utc end_utc metric
  time_range=$(python3 - <<'PY'
from datetime import datetime, timedelta, timezone
end = datetime.now(timezone.utc)
start = end - timedelta(hours=1)
print(start.isoformat(), end.isoformat())
PY
)
  start_utc=${time_range%% *}
  end_utc=${time_range#* }

  for metric in CPUUtilization DatabaseConnections FreeableMemory ReadLatency \
    WriteLatency DiskQueueDepth FreeStorageSpace; do
    echo
    echo "===== RDS METRIC: $metric ====="
    bcp_aws cloudwatch get-metric-statistics \
      --namespace AWS/RDS \
      --metric-name "$metric" \
      --dimensions Name=DBInstanceIdentifier,Value="$RDS_IDENTIFIER" \
      --start-time "$start_utc" \
      --end-time "$end_utc" \
      --period 300 \
      --statistics Minimum Average Maximum \
      --output table 2>&1 || true
  done
}

collect_istio_status() {
  if ! command -v istioctl >/dev/null 2>&1; then
    echo "istioctl is not installed."
    return 0
  fi
  if [ -n "$KUBE_CONTEXT" ]; then
    istioctl --context "$KUBE_CONTEXT" proxy-status 2>&1 || true
    echo
    istioctl --context "$KUBE_CONTEXT" analyze -n "$NAMESPACE_NAME" 2>&1 || true
  else
    istioctl proxy-status 2>&1 || true
    echo
    istioctl analyze -n "$NAMESPACE_NAME" 2>&1 || true
  fi
}

run_cmd "000_METADATA.txt" collect_metadata
run_cmd "001_TOOL_VERSIONS.txt" collect_tool_versions
run_cmd "010_KUBE_CURRENT_CONTEXT.txt" kube config current-context
run_cmd "011_KUBE_CLUSTER_INFO.txt" kube cluster-info
run_cmd "012_KUBE_AUTH_CAN_I.txt" kube auth can-i get pods -n "$NAMESPACE_NAME"
run_cmd "013_NAMESPACE_LABELS.txt" kube get namespace "$NAMESPACE_NAME" --show-labels

run_cmd "020_NODES_WIDE.txt" kube get nodes -o wide
run_cmd "021_NODES_TOPOLOGY.txt" kube get nodes \
  -L eks.amazonaws.com/nodegroup,topology.kubernetes.io/zone
run_cmd "022_NODE_CONDITIONS.txt" collect_node_conditions
run_cmd "023_NODE_TOP.txt" kube top nodes
run_cmd "024_NODE_DESCRIBE.txt" kube describe nodes

run_cmd "030_WORKLOADS.txt" kube get deployment,statefulset,daemonset \
  -n "$NAMESPACE_NAME" -o wide
run_cmd "031_REPLICASETS.txt" kube get replicaset -n "$NAMESPACE_NAME" \
  --sort-by=.metadata.creationTimestamp
run_cmd "032_JOBS_CRONJOBS.txt" kube get jobs,cronjobs -n "$NAMESPACE_NAME" -o wide
run_cmd "033_HPA_PDB.txt" kube get hpa,pdb -n "$NAMESPACE_NAME" -o wide
run_cmd "034_PODS_WIDE.txt" kube get pods -n "$NAMESPACE_NAME" -o wide
run_cmd "035_PENDING_PODS.txt" kube get pods -n "$NAMESPACE_NAME" \
  --field-selector=status.phase=Pending -o wide
run_cmd "036_POD_RESTART_DETAILS.txt" collect_restart_details
run_cmd "037_WORKLOAD_IMAGES.txt" collect_workload_images
run_cmd "038_PROBES_RESOURCES.txt" collect_probe_resources
run_cmd "039_POD_RESOURCE_TOP.txt" kube top pods -n "$NAMESPACE_NAME" --containers
run_cmd "040_PVC.txt" kube get pvc -n "$NAMESPACE_NAME" -o wide

run_cmd "050_SERVICES_ENDPOINTS.txt" kube get service,endpoints,endpointslice \
  -n "$NAMESPACE_NAME" -o wide
run_cmd "051_INGRESS.txt" kube get ingress -n "$NAMESPACE_NAME" -o wide
run_cmd "052_ISTIO_OBJECTS.txt" kube get virtualservice,destinationrule,gateway \
  -n "$NAMESPACE_NAME" -o wide
run_cmd "053_POD_CONTAINERS.txt" kube get pods -n "$NAMESPACE_NAME" \
  -o custom-columns='POD:.metadata.name,CONTAINERS:.spec.containers[*].name'
run_cmd "054_ISTIO_STATUS.txt" collect_istio_status

run_cmd "060_EVENTS_ALL.txt" kube get events -n "$NAMESPACE_NAME" \
  --sort-by=.lastTimestamp
run_cmd "061_EVENTS_WARNING.txt" kube get events -n "$NAMESPACE_NAME" \
  --field-selector=type=Warning --sort-by=.lastTimestamp

run_cmd "070_RASA_DEPLOYMENT.txt" kube get deployment/rasa -n "$NAMESPACE_NAME" -o wide
run_cmd "071_RASA_ROLLOUT_STATUS.txt" kube rollout status deployment/rasa \
  -n "$NAMESPACE_NAME" --timeout=60s
run_cmd "072_RASA_ROLLOUT_HISTORY.txt" kube rollout history deployment/rasa \
  -n "$NAMESPACE_NAME"
run_cmd "073_RASA_VERSION.txt" collect_rasa_version
run_cmd "074_RASA_MODELS.txt" collect_rasa_models

if [ "$SKIP_LOGS" != "true" ]; then
  run_cmd "080_ALL_CONTAINER_LOGS.txt" collect_pod_logs
  if [ "$PHASE" = "incident" ]; then
    run_cmd "081_PREVIOUS_CONTAINER_LOGS.txt" collect_previous_logs
  fi
fi

if [ "$INCLUDE_DESCRIBE" = "true" ]; then
  run_cmd "090_POD_DESCRIPTIONS.txt" collect_pod_descriptions
fi

if [ "$SKIP_KAFKA" != "true" ]; then
  run_cmd "100_KAFKA_PLACEMENT.txt" kube get pods -n "$NAMESPACE_NAME" -o wide
  run_cmd "101_KAFKA_QUORUM.txt" collect_kafka_quorum
  run_cmd "102_KAFKA_TOPICS.txt" collect_kafka_topics
  run_cmd "103_KAFKA_CONSUMER_GROUPS.txt" collect_kafka_groups
fi

run_cmd "110_GIT_STATE.txt" collect_git_state
run_cmd "111_GITHUB_RUNS.txt" collect_github_runs

if [ "$SKIP_AWS" != "true" ]; then
  if command -v aws >/dev/null 2>&1; then
    run_cmd "120_AWS_CALLER_IDENTITY.txt" bcp_aws sts get-caller-identity
    run_cmd "121_EKS_CLUSTER.txt" bcp_aws eks describe-cluster \
      --name "$CLUSTER_NAME"
    run_cmd "122_EKS_NODEGROUP.txt" bcp_aws eks describe-nodegroup \
      --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP_NAME"
    run_cmd "123_EKS_ADDONS.txt" bcp_aws eks list-addons \
      --cluster-name "$CLUSTER_NAME"
    run_cmd "124_RASA_CLOUDWATCH_ALARMS.txt" bcp_aws cloudwatch describe-alarms \
      --alarm-name-prefix prod-rasa
    run_cmd "125_RDS_INSTANCES.txt" bcp_aws rds describe-db-instances \
      --query 'DBInstances[?contains(DBInstanceIdentifier, `rasa`)].{ID:DBInstanceIdentifier,Status:DBInstanceStatus,Engine:Engine,Version:EngineVersion,Endpoint:Endpoint.Address,AZ:AvailabilityZone,MultiAZ:MultiAZ}' \
      --output table
    if [ -n "$RDS_IDENTIFIER" ]; then
      run_cmd "126_RDS_INSTANCE.txt" bcp_aws rds describe-db-instances \
        --db-instance-identifier "$RDS_IDENTIFIER"
      run_cmd "127_RDS_METRICS.txt" collect_rds_metrics
    fi
    if [ -n "$TARGET_GROUP_ARN" ]; then
      run_cmd "128_ALB_TARGET_HEALTH.txt" bcp_aws elbv2 describe-target-health \
        --target-group-arn "$TARGET_GROUP_ARN"
    fi
  else
    echo "AWS CLI not found; AWS checks skipped." > "$OUTPUT_DIR/120_AWS_SKIPPED.txt"
  fi
fi

cat > "$OUTPUT_DIR/README.txt" <<EOF
Rasa production deployment evidence bundle

Phase: $PHASE
Collected UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
Cluster: $CLUSTER_NAME
Namespace: $NAMESPACE_NAME
Region: $AWS_REGION_NAME
Context override: ${KUBE_CONTEXT:-none; current context used}
Log lookback: $SINCE_WINDOW

This collector used read-only Kubernetes and AWS commands. It did not fetch or
decode Kubernetes Secret values. Review and redact logs and optional pod
descriptions before sharing because they can contain internal hostnames,
request IDs, or application/customer data.

Start with:
  000_METADATA.txt
  034_PODS_WIDE.txt
  036_POD_RESTART_DETAILS.txt
  037_WORKLOAD_IMAGES.txt
  038_PROBES_RESOURCES.txt
  061_EVENTS_WARNING.txt
  071_RASA_ROLLOUT_STATUS.txt
  101_KAFKA_QUORUM.txt
  102_KAFKA_TOPICS.txt
  103_KAFKA_CONSUMER_GROUPS.txt
  122_EKS_NODEGROUP.txt
  124_RASA_CLOUDWATCH_ALARMS.txt

COMMAND_INDEX.txt records the command associated with each output file.
EOF

ARCHIVE_PATH="${OUTPUT_DIR%/}.tar.gz"
tar -czf "$ARCHIVE_PATH" -C "$(dirname "$OUTPUT_DIR")" "$(basename "$OUTPUT_DIR")"

if command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$ARCHIVE_PATH" > "${ARCHIVE_PATH}.sha256"
elif command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$ARCHIVE_PATH" > "${ARCHIVE_PATH}.sha256"
fi

echo
echo "Collection complete."
echo "Directory: $OUTPUT_DIR"
echo "Archive:   $ARCHIVE_PATH"
if [ -f "${ARCHIVE_PATH}.sha256" ]; then
  echo "Checksum:  ${ARCHIVE_PATH}.sha256"
fi
echo "Review and redact the evidence before sharing it."

