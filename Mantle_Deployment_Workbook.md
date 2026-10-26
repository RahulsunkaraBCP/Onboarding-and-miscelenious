# Rasa Mantle deployment workbook

DEV → QA → PROD · Better Car People · Rahul Sunkara

## How to use this workbook

This is a reconstruction of the implementation and troubleshooting recorded in our conversation, plus the saved PROD staged configuration diff from October 19, 2026. It is a learning workbook, an implementation record, and a command reference. It is **not a fresh audit of AWS, GitHub, Kubernetes, or the repository**. The latest direct evidence in this thread is from October 20; later changes outside this thread are not assumed.

Read the architecture first, then follow the implementation sections in dependency order. Commands that create databases, roles, node groups, repositories, topics, or releases are historical recipes, **not a script to run again against resources that already exist**. Read-only verification commands are the right starting point when returning to this work.

Code blocks are classified as:

- **Recorded:** supplied in the conversation or recovered from the staged diff.
- **Reconstructed:** assembled from recorded commands and known settings to make the sequence readable; not represented as the current repository bytes.
- **Follow-up:** useful verification or a proposed improvement; no claim it was executed.

No secret values, licenses, passwords, API tokens, or signed login links are included. Resource identifiers, account IDs, DNS names, and project IDs are operational configuration, not credentials.

### Contents

1. Goal and architectural decisions
2. Environment and resource map
3. Evidence, chronology, and status
4. Tools, context, and repository hygiene
5. Inspecting the legacy setup
6. PROD nodes, scheduling, and monitoring
7. PostgreSQL and reporting access
8. Secrets, licenses, and Langfuse
9. Pod IAM and GitHub OIDC
10. Storage and Kafka
11. Studio and certificates
12. Image/model promotion and runtime deployment
13. CI/CD design and full workflow code
14. Branch promotion and first deployment review
15. Lag collector implementation
16. Jambonz routing and the failed-call investigation
17. Verification, controlled cutover, and rollback
18. Troubleshooting lessons
19. Remaining work and learning exercises
20. Full configuration snapshots

## 1. Goal and architectural decisions

We introduced a Mantle stack alongside the existing CALM stack rather than replacing it in place.

| Layer | Existing stack | Mantle stack |
|---|---|---|
| Kubernetes namespace | `rasa` | `rasa-mantle` |
| Bot Helm release | `rasa` | `rasa-mantle` |
| Studio release | `studio` | `studio-mantle` |
| Kafka release | `kafka` in `rasa` | `kafka` in `rasa-mantle` |
| Tracker database | Existing `assistant` | `assistant_mantle` |
| Studio database | Existing Studio/analytics databases | `studio-mantle` |
| Redis | Existing shared service | Same environment's service, Mantle prefixes |
| PROD bot hostname | `assistant.rasa.brooke.ai` | `mantle-assistant.rasa.brooke.ai` |
| PROD Studio hostname | `studio.rasa.brooke.ai` | `studio-mantle.rasa.brooke.ai` |

This supports a **blue-green style application cutover**: run both applications, validate Mantle through a test route, then deliberately switch call routing. It does not mean every dependency is isolated. The EKS control plane, ingress/load balancer, Redis service, and RDS instances remain shared in PROD. Databases, Kafka data, namespaces, and Mantle compute are separated to the extent described here.

### Data flow

1. Jambonz receives a telephone call and POSTs the configured call webhook.
2. The custom Mantle channel returns a Jambonz `listen` verb pointing at a WebSocket endpoint.
3. Audio streaming uses the custom channel, ASR, TTS, and Mantle runtime.
4. Tracker events go to PostgreSQL `assistant_mantle`.
5. Conversation events are published to Kafka topic `rasa-mantle`.
6. Studio ingestion consumes the topic using group `studio-mantle`.
7. Studio stores its application/conversation data in database `studio-mantle`.
8. The bot's reporting module reads Studio's `reporting_v1` views through `bcp_reporting`.
9. The lag CronJob measures consumer progress and publishes CloudWatch metrics.

### Decisions that changed during implementation

- An early DEV plan considered reusing Kafka and disabling event publishing initially. The implemented stack uses a dedicated three-controller Kafka release in `rasa-mantle`.
- Early QA automation promoted a DEV image/model. The selected QA implementation instead builds, trains, publishes, and deploys on pushes to `qa`.
- PROD initially received the QA-tested artifacts manually to establish the infrastructure. For future automated releases, Rahul selected the existing CALM pattern: build/train separately on each environment branch, including `main` for PROD.
- A proposal to use a separate `PROD_RASA_LICENSE` GitHub secret was reversed. The selected workflow references existing `secrets.RASA_LICENSE` and `secrets.OPENAI_API_KEY`.
- Personal DEV Langfuse tracing was retained in QA but removed from PROD configuration.

Building again in PROD is the selected process, not a universal requirement. A fresh PROD build/model is a new artifact; branch testing alone does not prove its bytes are identical to QA. Post-build deployment validation remains necessary.

## 2. Environment and resource map

### AWS and branches

| Environment | Account | EKS cluster | Branch | Mantle namespace |
|---|---|---|---|---|
| DEV | `534725115372` | `rasa` | `dev` | `rasa-mantle` |
| QA | `534725115372` | `qa-rasa` | `qa` | `rasa-mantle` |
| PROD | `451781105151` | `rasa` | `main` | `rasa-mantle` |

Cluster names are scoped by AWS account and region. DEV and PROD can both be named `rasa` without being the same cluster.

### Endpoints and data

| Setting | DEV | QA | PROD |
|---|---|---|---|
| ECR repository | `534725115372.dkr.ecr.us-east-1.amazonaws.com/rasa-mantle` | Same repository as DEV; different SHA tags | `451781105151.dkr.ecr.us-east-1.amazonaws.com/rasa-mantle` |
| Model bucket | `bcp-nlwe-rasa-model` | `qa-rasa-oihg-qa-rasa-model` | `bcp-efnw-rasa-model` |
| Model prefix | `models/mantle/` | `models/mantle/` | `models/mantle/` |
| Tracker RDS | `rasa.cwmwrw6dbsxc.us-east-1.rds.amazonaws.com` | `qa-rasa.cwmwrw6dbsxc.us-east-1.rds.amazonaws.com` | `rasa.ca5ecrqmcbhd.us-east-1.rds.amazonaws.com` |
| Tracker DB/user | `assistant_mantle` / `assistant` | Same | Same |
| Studio RDS | DEV app RDS above | QA app RDS above | `rasa-analytics.ca5ecrqmcbhd.us-east-1.rds.amazonaws.com` |
| Studio DB/user | `studio-mantle` / `studio-mantle` | Same | Same |
| Reporting login | `bcp_reporting` | `bcp_reporting` | `bcp_reporting` |
| Redis host | `master.dev-rasa-redis-group.ghajwf.use1.cache.amazonaws.com` | `master.qa-rasa-redis-group.ghajwf.use1.cache.amazonaws.com` | `master.rasa-rasa-redis-group1.yaiset.use1.cache.amazonaws.com` |
| Redis username | `assistant` | `qa-assistant` | `assistant` |
| Redis cluster name | `dev-rasa-redis-group` | `qa-rasa-redis-group` | `rasa-rasa-redis-group1` |
| Pod IAM role name | `rasa-assistant` | `qa-rasa-assistant` | `rasa-assistant` |
| ServiceAccount name | `rasa-assistant` | `rasa-assistant` | `rasa-assistant` |

A Kubernetes ServiceAccount name does not have to equal its IAM role name. QA uses SA `rasa-assistant` annotated with role `qa-rasa-assistant`.

### URLs and Studio project IDs

| Environment | Bot host | Studio host | Recorded project ID |
|---|---|---|---|
| DEV | `mantle-assistant.rasa.dev-bcp.com` | `studio-mantle.rasa.dev-bcp.com` | `01a1222e-5921-73da-8d08-bc3584b206d7` |
| QA | `mantle-assistant.qa-rasa.dev-bcp.com` | `studio-mantle.qa-rasa.dev-bcp.com` | `01a13c2b-e6c9-773e-aa93-c34f2d01c213` |
| PROD | `mantle-assistant.rasa.brooke.ai` | `studio-mantle.rasa.brooke.ai` | `01a1555b-6fb8-734b-bbf5-940795664bc3` |

Project name: `brooke-voice-bcp`. The same human-readable name can be used in separate installations; each installation has its own UUID.

### Integration settings discovered from deployments

| Setting | QA | PROD |
|---|---|---|
| Jambonz API URL | `https://qa.jambonz.brooke.ai/api/v1` | `http://jambonz.brooke.ai/api/v1` |
| Jambonz account SID | `6923114c-44ef-4135-829a-65d804bf3d33` | `c8d2608d-6d62-48eb-9758-a076b707d909` |
| DVA API | QA values originally retained `https://dva-dev.brooke.ai/api` | `https://dva.brooke.ai/api` |
| SIP transfer | QA values originally retained `transfer-dev.brooke.ai:5060` | `transfer.brooke.ai:5060` |

These API URLs are outbound integration configuration. They are not the inbound Mantle call webhook. DEV/QA Jambonz DNS names also do not prove physically separate Jambonz server fleets.

## 3. Evidence, chronology, and status

### Recorded implementation sequence

1. Established DEV Mantle image/model packaging, custom modules, Helm RC18, tracker persistence, and graceful draining.
2. Deployed DEV Kafka and Studio; resolved SSL/license/secret mismatches.
3. Disabled DEV autoscaling and used one bot replica for debugging; automated DEV build/model/deploy.
4. Copied DEV configuration to QA and replaced account/environment endpoints.
5. Corrected QA database username (`assistant`) versus Redis username (`qa-assistant`).
6. Created QA databases/reporting grants, secrets, role trust, certificates, Kafka topics, and Studio project.
7. Expanded QA compute after Kafka scheduling failed on reserved CPU and anti-affinity.
8. Created `qa` branch and combined QA build/train/deploy workflow; aligned Rasa Pro versions.
9. Captured PROD baseline and created the dedicated Mantle node group in October 19 work.
10. Created PROD tracker/Studio databases, Kafka, Studio, certificates, IAM trust, and reporting access.
11. Promoted QA SHA `b1bed9ad7e2b40886ca0d4faafdb26ee10f1005d` manually to PROD.
12. Deployed three PROD Mantle replicas; verified `/status`, Studio login, and Rasa Pro `3.21.0.dev11`.
13. Added lag monitoring; initial test failed because empty Kafka partitions had no committed offsets.
14. Prepared PROD CI/CD on October 20, created PROD GitHub IAM role/access, and pushed configuration.
15. Jim pointed a dedicated PROD test number at Mantle. Calls failed; investigation established the full webhook path and confirmed HTTPS/GET route reachability, but not a successful call.

### Last confirmed status in this thread

| Item | Status/evidence |
|---|---|
| PROD node group | Active, three Ready nodes, one in each AZ |
| Node agents | New Relic, CloudWatch, Fluent Bit, CNI, EBS CSI and core agents Running |
| Kafka | Three 2/2 pods; three encrypted 30Gi PVCs Bound |
| Topics | RF 3; all three replicas in ISR in observed output |
| Studio | App and ingestion Running; HTTPS200 and login worked |
| Mantle | Three 2/2 pods; rollout completed |
| Runtime version | `3.21.0.dev11` from package metadata inside PROD container |
| Model | `/status` returned expected promoted model SHA |
| HPA | CPU1%/80%, min3/max6/current3 in observed output |
| PROD GitHub IAM | Role created, policy attached, namespace-scoped EKS access associated |
| PROD workflow | Generated and linted; pushed; PR targeting DEV was instructed |
| PR merges / first automated PROD run | Not confirmed in the provided evidence |
| Lag collection | Authentication and group membership worked; numeric lag/publish not yet validated |
| Lag schedule | Saved October19 diff has `suspend: false`; live enablement after the instruction was not separately shown |
| PROD telephone test | Failed; root cause and successful retest not confirmed |
| Full traffic cutover | Not confirmed; configuring a test number is not full cutover |

## 4. Tools, context, and repository hygiene

Tools used on the Mac: AWS CLI v2, kubectl, Helm4, Docker, Git, GitHub CLI, `jq`, Mike Farah `yq` v4, `rg`, actionlint, and Homebrew libpq `psql`.

```bash
cd /Users/bcpadmin/brooke-rasa-mantle

DEV_CONTEXT='arn:aws:eks:us-east-1:534725115372:cluster/rasa'
QA_CONTEXT='arn:aws:eks:us-east-1:534725115372:cluster/qa-rasa'
PROD_CONTEXT='arn:aws:eks:us-east-1:451781105151:cluster/rasa'

aws sts get-caller-identity
kubectl config current-context
git branch --show-current
git status --short
```

AWS CLI credentials and Kubernetes context are different selections. An explicit kubectl context does not switch AWS CLI credentials. Context exec authentication may also depend on a profile or ambient credentials. Verify both before mutation.

One serious confusion occurred when `PROD_CONTEXT` was empty. The command inspected the currently selected QA cluster and misleadingly appeared to show PROD's Langfuse key. The correction was to set the variable explicitly and verify the full context.

For new commands, this prevents an empty variable from silently falling back:

```bash
kubectl --context "${PROD_CONTEXT:?Set PROD_CONTEXT first}" get pods -n rasa-mantle
```

The Mac uses zsh. `sed -i ''` is the macOS form, not Linux `sed -i`. `set -- $entry` did not split a string like Bash in the recorded zsh loop. Prefer explicit SQL invocations or a Bash script.

`git diff --check` ignores untracked files. We saw only `?? k8s/prod/`, so the correct review was:

```bash
git add k8s/prod/ .github/workflows/deploy-rasa-mantle-prod.yaml
git diff --cached --check
git diff --cached --stat
git diff --cached
```

Do not put passwords in committed values files. Kubernetes Secret references are expected; decoded Secret output is not.

## 5. Inspecting the legacy setup

We copied settings from observed deployment/Helm state instead of guessing PROD endpoints.

```bash
helm --kube-context "$PROD_CONTEXT" list -A
kubectl --context "$PROD_CONTEXT" get nodes -L eks.amazonaws.com/nodegroup
kubectl --context "$PROD_CONTEXT" top nodes
kubectl --context "$PROD_CONTEXT" get storageclass
kubectl --context "$PROD_CONTEXT" get daemonsets -A

helm --kube-context "$PROD_CONTEXT" get values rasa -n rasa -a |
  rg -n -A8 -B2 'tracker_store:|DB_HOST|DB_DATABASE|analytics|DATABASE_URL'

helm --kube-context "$PROD_CONTEXT" get values studio -n rasa -a |
  rg -n -A12 '^  database:'
```

Extract selected non-secret integration environment variables:

```bash
kubectl --context "$PROD_CONTEXT" get deployment rasa -n rasa -o json |
jq -r '
  .spec.template.spec.containers[].env[]?
  | select(.name | test("^(REDIS_HOST|REDIS_USER|AWS_ELASTICACHE_CLUSTER_NAME|BUCKET_NAME|JAMBONZ_API_URL|JAMBONZ_ACCOUNT_SID|DIGITAL_ASSISTANT_API_URL|SIP_TRANSFER_DOMAIN)$"))
  | "\(.name)=\(.value)"
'
```

### Database capacity evidence and placement decision

| RDS | Recorded class | Recorded allocation | Observed capacity signals |
|---|---|---|---|
| `rasa` | `db.t4g.large` | 300GiB | PeakCPU63.5%; minimum freeRAM3.9GiB; minimum free disk45.6GiB |
| `rasa-analytics` | `db.m7g.xlarge` | 400GiB initially; later440GiB available | PeakCPU43.5%; minimum freeRAM9.7GiB; minimum free disk41.6GiB before increase |

These were samples supplied during planning; their time window was not recorded here. Do not treat them as current capacity or a load-test result.

Chris and Eman agreed Studio2's database belongs on the analytics RDS instance because it performs both prior analytics and Studio work. We did not put the whole Mantle application on the smaller app RDS. Tracker and Studio were split.

The exact RDS resize command was not supplied. Later `describe-db-instances` confirmed analytics allocation440GiB and no pending changes. Do not invent a resize procedure as if executed.

## 6. PROD nodes, scheduling, and monitoring

### Baseline backup

```bash
PROD_NODEGROUP='node-group-green-20260317165903002100000001'
PROD_BASELINE_DIR="$HOME/mantle-prod-baseline"
mkdir -p "$PROD_BASELINE_DIR"

aws eks describe-nodegroup \
  --cluster-name rasa --nodegroup-name "$PROD_NODEGROUP" \
  --region us-east-1 --output json \
  > "$PROD_BASELINE_DIR/nodegroup.json"

aws ec2 describe-launch-template-versions \
  --launch-template-id lt-01635e2f4b778c6d7 --versions 2 \
  --region us-east-1 --output json \
  > "$PROD_BASELINE_DIR/launch-template.json"

jq '.nodegroup | {nodeRole,subnets,instanceTypes,amiType,capacityType,version,releaseVersion,launchTemplate,remoteAccess,labels,taints,scalingConfig,updateConfig}' \
  "$PROD_BASELINE_DIR/nodegroup.json"
jq '.LaunchTemplateVersions[0].LaunchTemplateData' \
  "$PROD_BASELINE_DIR/launch-template.json"
```

We reused the baseline's node IAM role, launch-template version, subnets, instance family, and security configuration. This reduced accidental differences while creating separate compute.

Recorded launch template features: encrypted100Gi gp3 root, 3000IOPS,125MiB/s throughput, detailed monitoring, security group `sg-0faaefdc47f47397b`, IMDSv2 required, metadata hop limit2. The `Name=node-group-green` EC2 tag was inherited and cosmetic; EKS nodegroup identity is `rasa-mantle`.

### Node group creation — historical, do not rerun blindly

```bash
aws eks create-nodegroup \
  --region us-east-1 \
  --cluster-name rasa \
  --nodegroup-name rasa-mantle \
  --node-role arn:aws:iam::451781105151:role/node-group-green-eks-node-group-20260317150353705700000002 \
  --subnets subnet-0355bb62cf772574f subnet-06bdcb3017c934b93 subnet-04fafcfa411eb982e \
  --instance-types m6i.xlarge \
  --ami-type AL2023_x86_64_STANDARD \
  --version 1.33 \
  --capacity-type ON_DEMAND \
  --launch-template id=lt-01635e2f4b778c6d7,version=2 \
  --scaling-config minSize=3,maxSize=4,desiredSize=3 \
  --update-config maxUnavailable=1 \
  --labels workload=rasa-mantle \
  --taints key=workload,value=rasa-mantle,effect=NO_SCHEDULE
```

Observed release `1.33.13-20261012`; control plane version1.33. Omitting an explicit releaseVersion at creation did not install a higher Kubernetes minor. It also does not establish automatic future AMI upgrades.

Observed nodes:

| Node | Zone |
|---|---|
| `ip-10-67-15-21.ec2.internal` | `us-east-1a` |
| `ip-10-67-45-80.ec2.internal` | `us-east-1b` |
| `ip-10-67-75-7.ec2.internal` | `us-east-1c` |

### What taints and selectors actually do

```yaml
nodeSelector:
  workload: rasa-mantle
tolerations:
  - key: workload
    operator: Equal
    value: rasa-mantle
    effect: NoSchedule
```

- The node label + pod selector direct Mantle pods to these nodes.
- The taint rejects new pods without a matching toleration.
- A toleration permits scheduling; it does not force a pod onto those nodes.
- `NoSchedule` does not evict existing pods.
- Pods with broad tolerations, including infrastructure agents, can still run here.
- Node isolation does not isolate RDS, Redis, shared networking, control-plane capacity, or ingress.

The EKS control plane is AWS-managed. We did not create a customer-managed master node. These node groups are workers.

### Namespace and agents

```bash
kubectl --context "$PROD_CONTEXT" create namespace rasa-mantle
kubectl --context "$PROD_CONTEXT" label namespace rasa-mantle istio-injection=enabled

kubectl --context "$PROD_CONTEXT" get nodes -l workload=rasa-mantle \
  -L topology.kubernetes.io/zone
kubectl --context "$PROD_CONTEXT" get nodes -l workload=rasa-mantle \
  -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints'
kubectl --context "$PROD_CONTEXT" get pods -A -o wide
```

Existing DaemonSets automatically scheduled CloudWatch agent, Fluent Bit, New Relic kubelet, VPC CNI, EBS CSI node, Pod Identity agent, and kube-proxy. They were not installed individually on each new EC2 instance. Running agents prove scheduling/readiness, not that every dashboard/query has already been checked.

## 7. PostgreSQL and reporting access

### Three different meanings of database

- **RDS instance:** PostgreSQL server with compute/storage, roles, and multiple logical databases.
- **Database:** e.g. `assistant_mantle`, `studio-mantle`.
- **Schema:** e.g. `public` or `reporting_v1` inside a database.

`bcp_reporting` is a **login role**, not a replacement for schema `reporting_v1`. Code continues querying `reporting_v1.project`, `reporting_v1.memory_set`, etc., while authenticating as `bcp_reporting`.

### Network diagnostic and in-cluster client

Mac `psql` and `nc` timed out to both private PROD RDS hosts. A client pod reached both. This pointed to the Mac/network access path rather than PostgreSQL being down.

```bash
nc -vz -G 5 rasa.ca5ecrqmcbhd.us-east-1.rds.amazonaws.com 5432
nc -vz -G 5 rasa-analytics.ca5ecrqmcbhd.us-east-1.rds.amazonaws.com 5432
```

Reconstructed client manifest (temporary; no Istio; Mantle nodes):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: pg-client
  namespace: rasa-mantle
  annotations:
    sidecar.istio.io/inject: "false"
spec:
  restartPolicy: Never
  nodeSelector:
    workload: rasa-mantle
  tolerations:
    - key: workload
      operator: Equal
      value: rasa-mantle
      effect: NoSchedule
  containers:
    - name: pg-client
      image: postgres:17
      command: ["sleep", "7200"]
```

A Completed client pod cannot execute new commands. Delete/recreate it only when another DB session is needed; it is not an application service.

```bash
kubectl --context "$PROD_CONTEXT" exec -n rasa-mantle pg-client -- \
  pg_isready -h rasa.ca5ecrqmcbhd.us-east-1.rds.amazonaws.com -p 5432
```

### App RDS admin secret

The `rasa` instance used an RDS-managed Secrets Manager master secret. We read username/password into local variables, not terminal output:

```bash
PROD_RASA_SECRET_ARN='arn:aws:secretsmanager:us-east-1:451781105151:secret:rds!db-ebddcfc0-1c68-4a7b-b640-10b46eccff9d-zt8Q4F'
PROD_DB_SECRET_JSON=$(aws secretsmanager get-secret-value \
  --region us-east-1 --secret-id "$PROD_RASA_SECRET_ARN" \
  --query SecretString --output text)
PROD_DB_ADMIN_USER=$(jq -r '.username' <<< "$PROD_DB_SECRET_JSON")
PROD_DB_ADMIN_PASSWORD=$(jq -r '.password' <<< "$PROD_DB_SECRET_JSON")
unset PROD_DB_SECRET_JSON
```

Verified role `assistant` existed but database `assistant_mantle` did not. Then ran:

```bash
printf '%s\n%s\n' "$PROD_DB_ADMIN_USER" "$PROD_DB_ADMIN_PASSWORD" |
kubectl --context "$PROD_CONTEXT" exec -i -n rasa-mantle pg-client -- bash -c '
  IFS= read -r PGUSER
  IFS= read -r PGPASSWORD
  export PGUSER PGPASSWORD PGSSLMODE=require
  export PGHOST=rasa.ca5ecrqmcbhd.us-east-1.rds.amazonaws.com
  psql -d postgres -v ON_ERROR_STOP=1 \
    -c "CREATE DATABASE assistant_mantle;" \
    -c "GRANT CONNECT, CREATE, TEMPORARY ON DATABASE assistant_mantle TO assistant;" &&
  psql -d assistant_mantle -v ON_ERROR_STOP=1 \
    -c "GRANT USAGE, CREATE ON SCHEMA public TO assistant;"
'
```

Creating a database and granting schema permissions are separate steps. Success of one does not imply the other ran. `CREATE DATABASE` is not a repeat-safe command and cannot be wrapped in a PostgreSQL transaction block.

### Analytics admin connection

The analytics instance had no `MasterUserSecret` ARN in the output. Existing secret `rasa/rasa-secrets:analyticsDbUrl` supplied a connection as `postgres`. We verified `rolcreatedb=t`, `rolcreaterole=t` and listed databases `analytics`, `postgres`, `rdsadmin`.

```bash
kubectl --context "$PROD_CONTEXT" get secret rasa-secrets -n rasa \
  -o jsonpath='{.data.analyticsDbUrl}' |
base64 --decode |
kubectl --context "$PROD_CONTEXT" exec -i -n rasa-mantle pg-client -- bash -c '
  ANALYTICS_DB_URL=$(cat)
  psql "$ANALYTICS_DB_URL" -v ON_ERROR_STOP=1 \
    -c "SELECT current_user, rolcreatedb, rolcreaterole FROM pg_roles WHERE rolname=current_user;" \
    -c "SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY datname;"
'
```

Do not use an unrelated PDS reader endpoint. It is another service and may be read-only.

### Studio database creation

The SQL executed against analytics was:

```sql
CREATE ROLE "studio-mantle" LOGIN;
CREATE DATABASE "studio-mantle";
GRANT CONNECT, CREATE, TEMPORARY ON DATABASE "studio-mantle" TO "studio-mantle";
-- Reconnect to database studio-mantle before the next statement:
GRANT USAGE, CREATE ON SCHEMA public TO "studio-mantle";
```

Roles are instance-wide. The Studio role was created without a password first; we then set its password interactively:

```text
\password studio-mantle
```

The password entered must be the same value stored as Kubernetes `studio-secrets/DATABASE_PASSWORD`. A local variable and a typed password are not automatically synchronized. We verified a real connection as `studio-mantle` after storing it.

Studio's chart migration job creates/updates the application's schema. We did not manually create its application tables. A migration job not appearing in `kubectl get jobs` for the old release does not prove no migration ever ran; Helm hook cleanup/history differs by chart.

### Reporting login after Studio migration

After Studio created `reporting_v1`, the reporting setup was:

```sql
-- Run as analytics administrator, after checking role does not already exist:
CREATE ROLE bcp_reporting LOGIN;
GRANT CONNECT ON DATABASE "studio-mantle" TO bcp_reporting;
-- Set password interactively with \password bcp_reporting.
```

Connected as `studio-mantle` to `studio-mantle`:

```sql
GRANT USAGE ON SCHEMA reporting_v1 TO bcp_reporting;
GRANT SELECT ON ALL TABLES IN SCHEMA reporting_v1 TO bcp_reporting;
ALTER DEFAULT PRIVILEGES IN SCHEMA reporting_v1
  GRANT SELECT ON TABLES TO bcp_reporting;
```

Default privileges apply to objects subsequently created by the role executing the command. We ran them as `studio-mantle`, the relevant object owner. They do not globally apply to future objects created by any role.

Password went into `rasa-mantle/rasa-secrets:studioDbPassword`. Verified:

- `current_user=bcp_reporting`.
- Schema USAGE true, CREATE false.
- SELECT worked on `reporting_v1.memory_set`, count0.
- Observed table privileges SELECT.

Read-only zero rows is successful access, not an authentication failure. Before conversations/projects are present, reporting results can be empty. We did not insert fake reporting rows or a fake project into the views. The project was created through Studio, and its UUID was set in Helm values.

### DEV/QA equivalent

DEV/QA use the corresponding app RDS host for both databases. QA corrected values were:

```yaml
tracker_store:
  db: assistant_mantle
  username: assistant
# extraEnv:
# DB_USER=assistant
# REDIS_USER=qa-assistant
# STUDIO_DB_USER=bcp_reporting
```

The QA `set -- $entry` loop failed because zsh retained `assistant_mantle assistant` as one argument. Explicit grants resolved it. Do not repeat that loop unchanged.

## 8. Secrets, licenses, and Langfuse

### Secret inventory

| Secret | Key | Consumer/purpose |
|---|---|---|
| `rasa-secrets` | `RASA_LICENSE` | Mantle runtime license expected by RC18 configuration |
| `rasa-secrets` | `authToken` | Rasa API authentication |
| `rasa-secrets` | `kafkaSslPassword` | New Mantle Kafka client password; name is historical, transport is SASL_PLAINTEXT |
| `rasa-secrets` | `openaiApiKey` | LLM calls |
| `rasa-secrets` | `deepgramApiKey` | ASR |
| `rasa-secrets` | `elevenlabsApiKey` | TTS |
| `rasa-secrets` | `jambonzApiKey` | Outbound Jambonz API |
| `rasa-secrets` | `digitalAssistantClientId`, `digitalAssistantClientSecret` | DVA integration |
| `rasa-secrets` | `studioDbPassword` | Read-only reporting login password |
| `rasa-secrets` | `chrisLangfuseKey` | DEV/QA personal tracing key; removed from PROD env references |
| `studio-secrets` | `DATABASE_PASSWORD` | Studio DB role password |
| `studio-secrets` | `AUTH_SECRET` | Studio application authentication/session secret |
| `studio-secrets` | `studio-admin-password` | Initial Studio UI admin password |
| `studio-secrets` | `KAFKA_SASL_PASSWORD` | Studio ingestion's Kafka password |
| `kafka-lag-client-config` | `client.properties` | Collector SASL client configuration |

Legacy `rasaProLicense`, `jwtSecret`, or other keys may remain. Their presence does not mean the new deployment references them. Required references must match exact key spelling/case.

List only key names:

```bash
kubectl --context "$PROD_CONTEXT" get secret rasa-secrets -n rasa-mantle \
  -o go-template='{{range $key,$value := .data}}{{printf "%s\n" $key}}{{end}}' | sort
```

A nonzero decoded byte count proves a value exists, not that the credential is correct.

### Namespace copy and Kafka correction

We copied legacy application integration secrets into the new namespace, excluding the legacy analytics administrator URL and old Kafka password:

```bash
kubectl --context "$PROD_CONTEXT" get secret rasa-secrets -n rasa -o json |
jq '{apiVersion:"v1",kind:"Secret",metadata:{name:"rasa-secrets",namespace:"rasa-mantle"},type:"Opaque",data:(.data | del(.analyticsDbUrl,.kafkaSslPassword))}' |
kubectl --context "$PROD_CONTEXT" create -f -
```

New Kafka generated its own password. Copy the first client password into Studio:

```bash
kubectl --context "$PROD_CONTEXT" get secret kafka-user-passwords -n rasa-mantle \
  -o jsonpath='{.data.client-passwords}' |
base64 --decode | cut -d, -f1 |
jq -Rs '{stringData:{KAFKA_SASL_PASSWORD:rtrimstr("\n")}}' |
kubectl --context "$PROD_CONTEXT" patch secret studio-secrets -n rasa-mantle \
  --type merge --patch-file=/dev/stdin
```

For the bot use the same pipeline but JSON key `kafkaSslPassword` and target `rasa-secrets`. Existing workload env values from a Secret are normally picked up by newly created containers; changing Secret data alone is not proof running processes reloaded it.

### License distinctions

1. Studio UI license uploaded in the Studio settings page.
2. Runtime Mantle license in Kubernetes `RASA_LICENSE`.
3. GitHub training license in Actions secret `RASA_LICENSE`, passed to the training process as `RASA_PRO_LICENSE`.

Uploading through Studio did not create the Kubernetes Secret key. We separately patched the runtime key and verified it existed. GitHub Secrets are another location again.

The selected future workflow uses existing GitHub `RASA_LICENSE`. Its suitability/entitlements for PROD training should be confirmed by the license owner if unknown; the key name alone proves nothing about scope. We did not decide to obtain a new license.

We briefly created `PROD_RASA_LICENSE` in GitHub, then instructed removal and changed the workflow back to existing `RASA_LICENSE`. No evidence suggests changing the existing secret's value. Check references rather than creating duplicates.

### Langfuse decision

Chris explained the DEV key was personal and used to demonstrate tracing. PROD should not silently send customer traces to that personal project. We removed the three PROD env entries:

```bash
yq -i '.extraEnv |= map(select(.name != "LANGFUSE_HOST" and .name != "LANGFUSE_PUBLIC_KEY" and .name != "LANGFUSE_PRIVATE_KEY"))' \
  k8s/prod/prod-values.yaml
```

Commented tracing examples may still contain those strings; comments are not active configuration. No runtime `optional: true` workaround was introduced. QA retained its existing arrangement; that is a historical fact, not approval to reuse a personal key for PROD.

## 9. Pod IAM and GitHub OIDC

### Two independent trust relationships

| Identity | Issuer | Subject | Purpose |
|---|---|---|---|
| Kubernetes pod IRSA | EKS OIDC provider | `system:serviceaccount:<namespace>:<sa>` | Runtime AWS access |
| GitHub Actions | `token.actions.githubusercontent.com` | Repository/branch subject | CI/CD AWS access |

Same account does not mean same role. The issuer, token subject, role trust, permissions, and Kubernetes access determine what is allowed. No long-lived IAM access keys were needed for the Mantle Actions role.

### Pod role trust extension

PROD EKS issuer suffix: `60AED03E1EFEB9C19FAB8BF84ACFA52C`. Existing role `rasa-assistant` trusted legacy namespace only. We backed it up and extended it to allow both SAs while preserving existing access:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "arn:aws:iam::451781105151:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/60AED03E1EFEB9C19FAB8BF84ACFA52C"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {"StringEquals": {
      "oidc.eks.us-east-1.amazonaws.com/id/60AED03E1EFEB9C19FAB8BF84ACFA52C:aud": "sts.amazonaws.com",
      "oidc.eks.us-east-1.amazonaws.com/id/60AED03E1EFEB9C19FAB8BF84ACFA52C:sub": [
        "system:serviceaccount:rasa:rasa-assistant",
        "system:serviceaccount:rasa-mantle:rasa-assistant"
      ]
    }}
  }]
}
```

The same principle was used in QA's role. Do not copy an issuer ID between clusters. Existing runtime policies for Redis, RDS IAM, model bucket, translation, etc. were reused; exact policy bodies were not all supplied.

### GitHub immutable subject

Verified with:

```bash
gh api repos/BetterCarPeople/brooke-rasa-mantle/actions/oidc/customization/sub
```

Returned `use_default=true`, `use_immutable_subject=true`, prefix:

```text
repo:BetterCarPeople@1440728/brooke-rasa-mantle@1352686373
```

PROD role name: `BrookeRasaMantleGitHubActionsRole` in account451781105151. Its trust file:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Federated": "arn:aws:iam::451781105151:oidc-provider/token.actions.githubusercontent.com"},
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {"StringEquals": {
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
      "token.actions.githubusercontent.com:sub": "repo:BetterCarPeople@1440728/brooke-rasa-mantle@1352686373:ref:refs/heads/main"
    }}
  }]
}
```

```bash
aws iam create-role \
  --role-name BrookeRasaMantleGitHubActionsRole \
  --assume-role-policy-document file:///tmp/mantle-prod-github-trust.json
```

DEV/QA account's role was restricted to `dev` and `qa`. We removed `main` there because PROD has a separate account/role. A future GitHub Environment changes the OIDC subject context; do not add `environment: production` without reviewing trust first.

### PROD Actions permissions — recorded policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect":"Allow","Action":"ecr:GetAuthorizationToken","Resource":"*"},
    {
      "Effect":"Allow",
      "Action":["ecr:BatchCheckLayerAvailability","ecr:InitiateLayerUpload","ecr:UploadLayerPart","ecr:CompleteLayerUpload","ecr:PutImage","ecr:BatchGetImage","ecr:GetDownloadUrlForLayer","ecr:DescribeImages"],
      "Resource":"arn:aws:ecr:us-east-1:451781105151:repository/rasa-mantle"
    },
    {
      "Effect":"Allow","Action":"s3:ListBucket",
      "Resource":"arn:aws:s3:::bcp-efnw-rasa-model",
      "Condition":{"StringLike":{"s3:prefix":["models/mantle/*"]}}
    },
    {
      "Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:AbortMultipartUpload"],
      "Resource":"arn:aws:s3:::bcp-efnw-rasa-model/models/mantle/*"
    },
    {
      "Effect":"Allow","Action":"eks:DescribeCluster",
      "Resource":"arn:aws:eks:us-east-1:451781105151:cluster/rasa"
    }
  ]
}
```

```bash
aws iam put-role-policy --role-name BrookeRasaMantleGitHubActionsRole \
  --policy-name MantleProdCICD \
  --policy-document file:///tmp/mantle-prod-github-permissions.json

ROLE_ARN='arn:aws:iam::451781105151:role/BrookeRasaMantleGitHubActionsRole'
aws eks create-access-entry --region us-east-1 --cluster-name rasa \
  --principal-arn "$ROLE_ARN" --type STANDARD
aws eks associate-access-policy --region us-east-1 --cluster-name rasa \
  --principal-arn "$ROLE_ARN" \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy \
  --access-scope type=namespace,namespaces=rasa-mantle
```

IAM `eks:DescribeCluster` allows fetching endpoint metadata; it does not itself authorize Helm actions. EKS access association provides namespace authorization. It does not grant cluster-wide creation of StorageClasses or certificates in `istio-system`; those remain separately managed.

### Read-only developer logs

QA used role `RasaMantleExternalLogsReadOnly`, EKS group `rasa-mantle-log-readers`. Tests returned logs yes, secrets no. PROD Adam access used an Identity Center permission set `ProdRasaLogsReadOnly`, resulting in a PROD SSO IAM role and group `prod-rasa-log-readers` in namespace `rasa`.

A permission set lives in Identity Center; assignment provisions an IAM role in the target account. EKS maps that role to Kubernetes authorization. It is not the same as an IAM policy alone. We did not grant all users of a shared AWSReadOnlyAccess role access just to onboard Adam.

Representative namespace Role (reconstructed):

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: mantle-log-reader
  namespace: rasa-mantle
rules:
  - apiGroups: [""]
    resources: [pods, events]
    verbs: [get, list, watch]
  - apiGroups: [""]
    resources: [pods/log]
    verbs: [get]
  - apiGroups: [apps]
    resources: [deployments, replicasets, statefulsets]
    verbs: [get, list, watch]
  - apiGroups: [autoscaling]
    resources: [horizontalpodautoscalers]
    verbs: [get, list, watch]
```

Bind this to the intended group, not to everyone. Studio UI membership is separate again: Andy requested existing QA users be added to Mantle Studio; EKS log access does not create Studio accounts.

## 10. Storage and Kafka

### Storage class

Existing PROD Kafka had30Gi PVCs on `auto-ebs-sc` with Immediate binding. The new Mantle values originally copied8Gi from QA. We changed Mantle to30Gi before install and created a distinct StorageClass with delayed binding and encryption.

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: auto-ebs-sc-wffc
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

```bash
kubectl --context "$PROD_CONTEXT" apply --dry-run=server \
  -f k8s/prod/auto-ebs-sc-wffc.yaml
kubectl --context "$PROD_CONTEXT" apply -f k8s/prod/auto-ebs-sc-wffc.yaml
```

WaitForFirstConsumer lets provisioning consider where a pod can run, important for zonal EBS. It does not make one EBS volume multi-AZ. `Delete` can remove underlying storage when its claim is deleted; do not delete PVCs as a routine deployment fix. Expansion is possible, shrinking is not the inverse operation.

### Kafka production configuration

Full snapshot is in the appendix. Important settings:

| Setting | Value and reason |
|---|---|
| Controller replicas | 3; combined controller/broker mode |
| Separate broker replicas | 0 |
| Required anti-affinity | One Kafka controller pod per hostname |
| Node placement | Mantle label/toleration |
| Storage |30Gi per controller, encrypted gp3 |
| Requests |1CPU,2Gi memory |
| Limits |2CPU,4Gi memory |
| Heap |Xms1024m/Xmx1024m |
| PDB |maxUnavailable1 |
| Client auth |SASL_PLAINTEXT / PLAIN, user kafka |
| Image |bitnamilegacy/kafka:4.0.0-debian-12-r10 |
| Default replication factor |3 |
| min.insync.replicas |1, deliberately matching observed legacy PROD |
| Retention |168hours, bytes-1 |
| Unclean leader election |false |

The PDB helps voluntary eviction policy; it is not a substitute for topic replication or a guarantee against failure. SASL_PLAINTEXT authenticates without Kafka transport TLS. `allowInsecureImages: true` in the chart permits the substituted image; it does not make that image security-validated.

Required hostname anti-affinity achieved one broker on each of the three initial nodes, which happened to span three AZs. It does **not** guarantee AZ diversity if future nodes are added unevenly. Zone spread would be a separate reviewed change; it was not applied in this record.

### RF, ISR, minimum ISR, and partitions

- RF 3 means three stored replicas per partition.
- ISR lists replicas currently caught up. Output `Isr:2,0,1` means all 3 in sync at that moment.
- `min.insync.replicas=1` is not ISR 3. It is a configured threshold relevant to writes with appropriate producer acknowledgements, especially `acks=all`.
- A topic with RF 3/minISR 1 does not have the same write durability as RF 3/minISR 2.
- Partitions distribute work/ordering; three broker pods do not automatically mean three partitions.
- Adding consumer replicas beyond useful partition assignments does not ensure more throughput.
- The legacy topic observed during this work had24 partitions, RF 3, ISR 3, minISR 1. Earlier historical partition counts are not the current snapshot used for this decision.
- Kafka partition count does not autoscale merely because HPA scales the bot. We created3 Mantle partitions initially; future increases require a deliberate plan, including key-ordering effects.

### Install and verify

```bash
helm lint k8s/prod/charts/kafka-32.4.3.tgz \
  -n rasa-mantle -f k8s/prod/kafka-values.yaml

helm --kube-context "$PROD_CONTEXT" install kafka \
  k8s/prod/charts/kafka-32.4.3.tgz \
  -n rasa-mantle -f k8s/prod/kafka-values.yaml \
  --rollback-on-failure --timeout 15m

kubectl --context "$PROD_CONTEXT" get pods,pvc -n rasa-mantle -o wide
```

All3 Kafka pods were2/2 Running and all PVCs30Gi Bound. A sidecar accounts for the second Ready container in these application pods.

### Authenticated topic administration — reconstructed reusable command

The first attempt used an unavailable `$KAFKA_CLIENT_PASSWORDS` environment variable and failed `password not specified`. We switched to the actual Secret and streamed it into an ephemeral client config.

```bash
kubectl --context "$PROD_CONTEXT" get secret kafka-user-passwords -n rasa-mantle \
  -o jsonpath='{.data.client-passwords}' |
base64 --decode | cut -d, -f1 |
kubectl --context "$PROD_CONTEXT" exec -i -n rasa-mantle kafka-controller-0 -c kafka -- bash -ec '
  password=$(cat)
  test -n "$password"
  cfg=$(mktemp)
  trap '\''rm -f "$cfg"'\'' EXIT
  chmod 600 "$cfg"
  printf "security.protocol=SASL_PLAINTEXT\nsasl.mechanism=PLAIN\nsasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"kafka\" password=\"%s\";\n" "$password" > "$cfg"
  unset password
  /opt/bitnami/kafka/bin/kafka-topics.sh \
    --bootstrap-server localhost:9092 --command-config "$cfg" \
    --create --if-not-exists --topic rasa-mantle \
    --partitions 3 --replication-factor 3
  /opt/bitnami/kafka/bin/kafka-topics.sh \
    --bootstrap-server localhost:9092 --command-config "$cfg" \
    --create --if-not-exists --topic rasa-mantle-events-dlq \
    --partitions 1 --replication-factor 3
  /opt/bitnami/kafka/bin/kafka-topics.sh \
    --bootstrap-server localhost:9092 --command-config "$cfg" --describe --topic rasa-mantle
'
```

This example follows the generated password format used in the session. For arbitrary passwords containing JAAS quotes/backslashes, escape them before writing JAAS, as done in the collector-secret recipe later.

Recorded results: main topic 3 partitions/RF 3, DLQ 1 partition/RF 3, all ISR 3. There was no partition migration from the legacy topic.

## 11. Studio and certificates

### Correct chart paths

We inspected `helm show values` and `_helpers.tpl` because plausible-looking global keys did not render:

```bash
helm show values k8s/prod/charts/studio-3.0.0-rc.54.tgz | sed -n '1,140p'
tar -xOf k8s/prod/charts/studio-3.0.0-rc.54.tgz studio/templates/_helpers.tpl |
  rg -n -A15 -B5 'nodeSelector|tolerations'
```

Correct chart configuration:

```yaml
config:
  connectionType: https
  database:
    host: rasa-analytics.ca5ecrqmcbhd.us-east-1.rds.amazonaws.com
    port: "5432"
    username: studio-mantle
    password:
      secretName: studio-secrets
      secretKey: DATABASE_PASSWORD
    databaseName: studio-mantle
    queryParams: sslmode=require
    preferSSL: "true"
  nodeSelector:
    workload: rasa-mantle
  tolerations:
    - key: workload
      operator: Equal
      value: rasa-mantle
      effect: NoSchedule
```

We deleted `.global.database`, `.global.nodeSelector`, and `.global.tolerations` after finding them ineffective. Global ingressHost is valid, but that does not make every setting a global option.

### Rendered verification before install

```bash
helm template studio-mantle k8s/prod/charts/studio-3.0.0-rc.54.tgz \
  -n rasa-mantle -f k8s/prod/studio-values.yaml > /tmp/prod-studio.yaml

yq 'select(.kind == "Deployment" or .kind == "Job") |
  {"name":.metadata.name,"nodeSelector":.spec.template.spec.nodeSelector,"tolerations":.spec.template.spec.tolerations}' \
  /tmp/prod-studio.yaml
rg -n -A2 'name: DB_HOST' /tmp/prod-studio.yaml
```

Three DB_HOST entries were all Studio components: app, ingestion, migration. They did not mean the Mantle tracker also pointed at analytics. We rendered the bot separately to verify tracker/appDB host versus reporting host.

### Certificates

Certificate resources live in `istio-system` for the gateway's TLS use. The app Ingress is in `rasa-mantle`. This placement follows this cluster's ingress setup; do not generalize it to every Ingress controller.

Recorded identities:

| Certificate resource | Secret | DNS name |
|---|---|---|
| `rasa-assistant-mantle` | `rasa-mantle-tls` | `mantle-assistant.rasa.brooke.ai` |
| `studio-mantle` | `studio-mantle-tls` | `studio-mantle.rasa.brooke.ai` |

```bash
kubectl --context "$PROD_CONTEXT" apply --dry-run=server \
  -f k8s/prod/studio-mantle-certificate.yaml
kubectl --context "$PROD_CONTEXT" apply \
  -f k8s/prod/studio-mantle-certificate.yaml
kubectl --context "$PROD_CONTEXT" wait certificate/studio-mantle \
  -n istio-system --for=condition=Ready --timeout=5m
```

The QA wait initially used `certificate/rasa-mantle` and returned NotFound; actual `metadata.name` was `rasa-assistant-mantle`. Certificate resource name, Secret name, hostname, and release name are separate identifiers.

### Studio install

```bash
helm lint k8s/prod/charts/studio-3.0.0-rc.54.tgz \
  -n rasa-mantle -f k8s/prod/studio-values.yaml
helm --kube-context "$PROD_CONTEXT" install studio-mantle \
  k8s/prod/charts/studio-3.0.0-rc.54.tgz \
  -n rasa-mantle -f k8s/prod/studio-values.yaml \
  --rollback-on-failure --timeout 15m
```

Version was `docker.io/rasa/studio:2.0.0.dev3`. This is the recorded experimental version, not a claim of general production support. App/ingestion became2/2. HTTPS initially failed while the certificate was not Ready, then returned200 after readiness. UI login worked.

After project creation:

```bash
yq -i '(.extraEnv[] | select(.name == "STUDIO_PROJECT_ID").value) = "01a1555b-6fb8-734b-bbf5-940795664bc3"' \
  k8s/prod/prod-values.yaml
```

Changing an env value in Git requires Helm deployment to put it in the pod template; a local edit does not update a running container.

## 12. Image/model promotion and runtime deployment

### Repository versus image tag

`rasa-mantle` is an ECR repository. `b1bed9...` is a tag inside it. DEV and QA both used the DEV account's same Mantle repository, not a Mantle tag inside the legacy `rasa` repository. PROD needed its own repository in the PROD account.

Recorded create:

```bash
aws ecr create-repository --region us-east-1 \
  --repository-name rasa-mantle --image-tag-mutability IMMUTABLE \
  --image-scanning-configuration scanOnPush=true \
  --encryption-configuration encryptionType=AES256
```

### Initial promotion: copy, not build

```bash
MANTLE_SHA='b1bed9ad7e2b40886ca0d4faafdb26ee10f1005d'
MODEL_KEY="models/mantle/${MANTLE_SHA}-model.tar.gz"
```

Authenticated source login, then local pull:

```bash
aws ecr get-login-password --region us-east-1 |
docker login --username AWS --password-stdin \
  534725115372.dkr.ecr.us-east-1.amazonaws.com

docker pull --platform linux/amd64 \
  "534725115372.dkr.ecr.us-east-1.amazonaws.com/rasa-mantle:${MANTLE_SHA}"
```

The~1.16GB layer took time to download. `docker pull` downloads an existing image; it does not compile/build the application or train a model.

After switching AWS login to PROD and verifying account:

```bash
aws ecr get-login-password --region us-east-1 |
docker login --username AWS --password-stdin \
  451781105151.dkr.ecr.us-east-1.amazonaws.com

docker tag \
  "534725115372.dkr.ecr.us-east-1.amazonaws.com/rasa-mantle:${MANTLE_SHA}" \
  "451781105151.dkr.ecr.us-east-1.amazonaws.com/rasa-mantle:${MANTLE_SHA}"
docker push "451781105151.dkr.ecr.us-east-1.amazonaws.com/rasa-mantle:${MANTLE_SHA}"
```

Recorded digest: `sha256:efc091fd5c608492814ebcd2d5a9a55843a09c0f2cad33f169e0950d547a2b72`.

Model copy with source-account login, then target-account login:

```bash
# While authenticated to DEV/QA:
aws s3 cp "s3://qa-rasa-oihg-qa-rasa-model/${MODEL_KEY}" \
  "/tmp/${MANTLE_SHA}-model.tar.gz" --region us-east-1
# After switching to PROD:
aws sts get-caller-identity
aws s3 cp "/tmp/${MANTLE_SHA}-model.tar.gz" \
  "s3://bcp-efnw-rasa-model/${MODEL_KEY}" --sse AES256 --region us-east-1
```

Earlier QA promotion used the same pattern from DEV bucket `bcp-nlwe-rasa-model` to QA bucket for SHA `72c3a1db15061dea2f05f33d1859155bb09653f4`.

The first `head-object` failed because SOURCE_BUCKET was empty. We explicitly assigned SOURCE_BUCKET, QA_BUCKET, MODEL_SHA, MODEL_KEY. Environment variables do not automatically survive opening another shell/login.

### Values and deploy

```bash
export MANTLE_SHA='b1bed9ad7e2b40886ca0d4faafdb26ee10f1005d'
yq -i '.image.tag = strenv(MANTLE_SHA) |
  .extraArgs[4] = "models/mantle/" + strenv(MANTLE_SHA) + "-model.tar.gz"' \
  k8s/prod/prod-values.yaml
```

The workflow uses `extraArgs[4]` because the recorded array is:

```yaml
extraArgs:
  - --inspect
  - --remote-storage
  - aws
  - --model
  - models/mantle/<SHA>-model.tar.gz
```

That index is positional. Reordering the list without updating the workflow can set the wrong argument.

Reconstructed install/upgrade used for the working deployment:

```bash
helm --kube-context "$PROD_CONTEXT" upgrade --install rasa-mantle \
  k8s/prod/charts/rasa-3.0.0-rc.18.tgz \
  -n rasa-mantle -f k8s/prod/prod-values.yaml \
  --rollback-on-failure --timeout 15m
kubectl --context "$PROD_CONTEXT" rollout status deployment/rasa-mantle \
  -n rasa-mantle --timeout=15m
```

Three replicas became2/2 across the three Mantle nodes.

### Runtime verification

```bash
kubectl --context "$PROD_CONTEXT" exec -n rasa-mantle deployment/rasa-mantle -c rasa -- \
  python -c 'from importlib.metadata import version; print(version("rasa-pro"))'
```

Output: `3.21.0.dev11`. The SHA tag alone would not establish the base package version.

API status without putting the token in the curl URL command argument:

```bash
RASA_AUTH_TOKEN=$(kubectl --context "$PROD_CONTEXT" get secret rasa-secrets \
  -n rasa-mantle -o jsonpath='{.data.authToken}' | base64 --decode)
printf 'url = "https://mantle-assistant.rasa.brooke.ai/status"\nget\n data-urlencode = "token=%s"\n' \
  "$RASA_AUTH_TOKEN" |
curl --config - --silent --show-error --fail | jq
unset RASA_AUTH_TOKEN
```

Recorded response:

```json
{
  "model_file": "b1bed9ad7e2b40886ca0d4faafdb26ee10f1005d-model.tar.gz",
  "model_id": "783924a6df48477597581dc1131b68f9",
  "num_active_training_jobs": 0,
  "worker_pid": 1,
  "engine_version": "mantle"
}
```

This proves one successful API response and loaded model, not all telephone integrations or all replicas' semantic correctness. A follow-up can check each pod's version/logs and consistent deployment image.

### HPA and shutdown

```yaml
replicaCount: 3
autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 6
  targetCPUUtilizationPercentage: 80
terminationGracePeriodSeconds: 240
lifecycle:
  preStop:
    exec:
      command: [python, -m, channels.jambonz_drain, --timeout, "180"]
```

CPU scaling is based on CPU requests, not instance utilization or number of telephone calls. HPA3–6 does not prove nodes can host6 replicas during every surge/failure scenario. Drain configuration was copied and DEV drain had been tested earlier; PROD mid-call termination validation was still pending.

## 13. CI/CD design and full workflow code

### What the existing CALM process did

We inspected `brooke-rasa-poc/.github/workflows/deploy-prod.yaml`. It triggered on selected `main` paths, pulled Rasa Pro3.16.6, trained the model, built/pushed a custom image, uploaded to PROD S3, then Helm deployed. It used static AWS secrets; Mantle uses OIDC instead. The old workflow's E2E section was commented out; a job called `train_test_deploy` is not evidence E2E tests executed.

### Selected Mantle process

| Environment | Trigger | Packaging/deploy |
|---|---|---|
| DEV | Relevant changes in `dev` | Separate build and train workflows; reusable DEV deploy |
| QA | Relevant changes in `qa` | One workflow with parallel build/train, then deploy |
| PROD | Relevant changes in `main` | One workflow with parallel build/train, then deploy |

The initial manual QA→PROD artifact copy was for bootstrapping. The PROD workflow below rebuilds/trains from the `main` checkout. This is an intentional distinction, not a silent claim of artifact promotion.

The QA workflow supplied in full in the conversation is the template for PROD. The full reconstructed PROD and QA code appear below. They reflect the reviewed shape, not a live GitHub checkout. Dockerfile/build context, model config, and secrets must match the repository revision.

### Critical operating limits of the recorded workflow

- No `workflow_dispatch` in the supplied QA trigger; copied PROD trigger is push-only.
- No GitHub Environment approval gate is configured in this version.
- `cancel-in-progress:false` avoids cancelling an active deployment, but does not promise every pending queued push will deploy.
- Helm rollout checks readiness. They are not a telephone, transfer, or reporting E2E test.
- Only the bot release is deployed here. Studio/Kafka/certificates/StorageClass/lag YAML are not automatically applied by this workflow.
- Paths specifically include bot values/chart/workflow and listed source directories. Changes only to another PROD manifest may not trigger it.
- PROD ECR is IMMUTABLE. Rerunning a successful image push for the same SHA may fail because the tag exists. Model S3 upload is not similarly immutable by this policy. An idempotent/retry-aware artifact policy is a follow-up, not already implemented.
- `helm --rollback-on-failure` can restore Kubernetes release state when possible. It does not roll back external side effects, DB schema changes, calls, or messages.
- `extraArgs[4]` depends on the current array order.
- Training uses `RASA_PRO_LICENSE` from existing GitHub `RASA_LICENSE`. Runtime uses Kubernetes `RASA_LICENSE`. These are separate credential locations.

### PROD combined workflow

File: `.github/workflows/deploy-rasa-mantle-prod.yaml`.
```yaml
name: Build, Train, and Deploy Rasa Mantle PROD

on:
  push:
    branches:
      - main
    paths:
      - Dockerfile
      - agent.yml
      - endpoints.yml
      - integrations.yml
      - memory.yml
      - responses.yml
      - channels/**
      - connectors/**
      - custom_asr/**
      - skills/**
      - tools/**
      - bcp_reporting/**
      - k8s/prod/prod-values.yaml
      - k8s/prod/charts/rasa-*.tgz
      - .github/workflows/deploy-rasa-mantle-prod.yaml

permissions:
  contents: read
  id-token: write

concurrency:
  group: rasa-mantle-prod
  cancel-in-progress: false

env:
  AWS_REGION: us-east-1
  RASA_PRO_VERSION: 3.21.0.dev11
  ECR_REPOSITORY: rasa-mantle
  MODEL_BUCKET: bcp-efnw-rasa-model
  MODEL_PREFIX: models/mantle
  EKS_CLUSTER: rasa
  NAMESPACE: rasa-mantle
  RELEASE: rasa-mantle
  CHART: k8s/prod/charts/rasa-3.0.0-rc.18.tgz
  VALUES: k8s/prod/prod-values.yaml

jobs:
  build_image:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::451781105151:role/BrookeRasaMantleGitHubActionsRole
          aws-region: ${{ env.AWS_REGION }}
      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2
      - name: Build and push PROD image
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          IMAGE_TAG: ${{ github.sha }}
        run: |
          docker build \
            --platform linux/amd64 \
            --build-arg "RASA_PRO_VERSION=${RASA_PRO_VERSION}" \
            -t "${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}" \
            .
          docker push "${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}"

  train_model:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::451781105151:role/BrookeRasaMantleGitHubActionsRole
          aws-region: ${{ env.AWS_REGION }}
      - name: Train Mantle model
        env:
          RASA_PRO_LICENSE: ${{ secrets.RASA_LICENSE }}
          OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
          MODEL_FILENAME: ${{ github.sha }}-model.tar.gz
        run: |
          mkdir -p models
          docker run --rm \
            -v "${GITHUB_WORKSPACE}:/app" \
            -w /app \
            -e RASA_PRO_LICENSE \
            -e OPENAI_API_KEY \
            -e RASA_TELEMETRY_ENABLED=false \
            "rasa/rasa-pro:${RASA_PRO_VERSION}" \
            train \
            --out /app/models \
            --fixed-model-name "${MODEL_FILENAME}"
          test -f "models/${MODEL_FILENAME}"
      - name: Upload model to PROD S3
        env:
          MODEL_FILENAME: ${{ github.sha }}-model.tar.gz
        run: |
          aws s3 cp \
            "models/${MODEL_FILENAME}" \
            "s3://${MODEL_BUCKET}/${MODEL_PREFIX}/${MODEL_FILENAME}" \
            --sse AES256 \
            --region "${AWS_REGION}"

  deploy:
    needs:
      - build_image
      - train_model
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::451781105151:role/BrookeRasaMantleGitHubActionsRole
          aws-region: ${{ env.AWS_REGION }}
      - name: Verify image and model
        run: |
          aws ecr describe-images \
            --repository-name "${ECR_REPOSITORY}" \
            --image-ids "imageTag=${GITHUB_SHA}" \
            --region "${AWS_REGION}"
          aws s3api head-object \
            --bucket "${MODEL_BUCKET}" \
            --key "${MODEL_PREFIX}/${GITHUB_SHA}-model.tar.gz" \
            --region "${AWS_REGION}"
      - uses: azure/setup-kubectl@v4
      - uses: azure/setup-helm@v4
        with:
          version: v4.0.0
      - name: Configure EKS
        run: |
          aws eks update-kubeconfig             --region "${AWS_REGION}"             --name "${EKS_CLUSTER}"
      - name: Lint chart
        run: |
          helm lint "${CHART}"             -n "${NAMESPACE}"             -f "${VALUES}"
      - name: Deploy PROD
        run: |
          helm upgrade --install "${RELEASE}" "${CHART}" \
            -n "${NAMESPACE}" \
            -f "${VALUES}" \
            --set-string "image.tag=${GITHUB_SHA}" \
            --set-string "extraArgs[4]=${MODEL_PREFIX}/${GITHUB_SHA}-model.tar.gz" \
            --rollback-on-failure \
            --timeout 15m
      - name: Verify rollout
        run: |
          kubectl rollout status deployment/rasa-mantle             -n "${NAMESPACE}"             --timeout=15m
          kubectl get pods -n "${NAMESPACE}" -o wide
```

### QA combined workflow

File: `.github/workflows/deploy-rasa-mantle-qa.yaml`. Reconstructed with equivalent commands and the supplied version pin.

```yaml
name: Build, Train, and Deploy Rasa Mantle QA

on:
  push:
    branches:
      - qa
    paths:
      - Dockerfile
      - agent.yml
      - endpoints.yml
      - integrations.yml
      - memory.yml
      - responses.yml
      - channels/**
      - connectors/**
      - custom_asr/**
      - skills/**
      - tools/**
      - bcp_reporting/**
      - k8s/qa/qa-values.yaml
      - k8s/qa/charts/rasa-*.tgz
      - .github/workflows/deploy-rasa-mantle-qa.yaml

permissions:
  contents: read
  id-token: write

concurrency:
  group: rasa-mantle-qa
  cancel-in-progress: false

env:
  AWS_REGION: us-east-1
  RASA_PRO_VERSION: 3.21.0.dev11
  ECR_REPOSITORY: rasa-mantle
  MODEL_BUCKET: qa-rasa-oihg-qa-rasa-model
  MODEL_PREFIX: models/mantle
  EKS_CLUSTER: qa-rasa
  NAMESPACE: rasa-mantle
  RELEASE: rasa-mantle
  CHART: k8s/qa/charts/rasa-3.0.0-rc.18.tgz
  VALUES: k8s/qa/qa-values.yaml

jobs:
  build_image:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::534725115372:role/BrookeRasaMantleGitHubActionsRole
          aws-region: ${{ env.AWS_REGION }}
      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2
      - name: Build and push QA image
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          IMAGE_TAG: ${{ github.sha }}
        run: |
          docker build \
            --platform linux/amd64 \
            --build-arg "RASA_PRO_VERSION=${RASA_PRO_VERSION}" \
            -t "${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}" \
            .
          docker push "${ECR_REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}"

  train_model:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::534725115372:role/BrookeRasaMantleGitHubActionsRole
          aws-region: ${{ env.AWS_REGION }}
      - name: Train Mantle model
        env:
          RASA_PRO_LICENSE: ${{ secrets.RASA_LICENSE }}
          OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
          MODEL_FILENAME: ${{ github.sha }}-model.tar.gz
        run: |
          mkdir -p models
          docker run --rm \
            -v "${GITHUB_WORKSPACE}:/app" \
            -w /app \
            -e RASA_PRO_LICENSE \
            -e OPENAI_API_KEY \
            -e RASA_TELEMETRY_ENABLED=false \
            "rasa/rasa-pro:${RASA_PRO_VERSION}" \
            train \
            --out /app/models \
            --fixed-model-name "${MODEL_FILENAME}"
          test -f "models/${MODEL_FILENAME}"
      - name: Upload model to QA S3
        env:
          MODEL_FILENAME: ${{ github.sha }}-model.tar.gz
        run: |
          aws s3 cp \
            "models/${MODEL_FILENAME}" \
            "s3://${MODEL_BUCKET}/${MODEL_PREFIX}/${MODEL_FILENAME}" \
            --sse AES256 \
            --region "${AWS_REGION}"

  deploy:
    needs:
      - build_image
      - train_model
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::534725115372:role/BrookeRasaMantleGitHubActionsRole
          aws-region: ${{ env.AWS_REGION }}
      - name: Verify image and model
        run: |
          aws ecr describe-images \
            --repository-name "${ECR_REPOSITORY}" \
            --image-ids "imageTag=${GITHUB_SHA}" \
            --region "${AWS_REGION}"
          aws s3api head-object \
            --bucket "${MODEL_BUCKET}" \
            --key "${MODEL_PREFIX}/${GITHUB_SHA}-model.tar.gz" \
            --region "${AWS_REGION}"
      - uses: azure/setup-kubectl@v4
      - uses: azure/setup-helm@v4
        with:
          version: v4.0.0
      - name: Configure EKS
        run: |
          aws eks update-kubeconfig             --region "${AWS_REGION}"             --name "${EKS_CLUSTER}"
      - name: Lint chart
        run: |
          helm lint "${CHART}"             -n "${NAMESPACE}"             -f "${VALUES}"
      - name: Deploy QA
        run: |
          helm upgrade --install "${RELEASE}" "${CHART}" \
            -n "${NAMESPACE}" \
            -f "${VALUES}" \
            --set-string "image.tag=${GITHUB_SHA}" \
            --set-string "extraArgs[4]=${MODEL_PREFIX}/${GITHUB_SHA}-model.tar.gz" \
            --rollback-on-failure \
            --timeout 15m
      - name: Verify rollout
        run: |
          kubectl rollout status deployment/rasa-mantle             -n "${NAMESPACE}"             --timeout=15m
          kubectl get pods -n "${NAMESPACE}" -o wide
```

### DEV reusable deploy workflow — historical reconstruction

The DEV workflow was supplied before the QA/prod changes. It accepted a40-character deploy SHA, checked out that commit, verified an image, waited for a matching model, then Helm deployed. These were separate build and model-training pipelines. The complete current versions of their files were not supplied, so their exact caller wiring cannot be certified here.

The build workflow recorded a Docker build argument and pushed SHA and Rasa-version tags. The training workflow recorded `RASA_PRO_VERSION`, `rasa/rasa-pro`, and a fixed SHA model filename. These are the same core build/train commands shown in the combined workflow; do not assume the current DEV triggers from this reconstruction.

Below is the historical full deploy flow, without the temporary force-conflicts workaround:

```yaml
name: Deploy Rasa Mantle DEV
on:
  workflow_call:
    inputs:
      deploy_sha:
        required: true
        type: string
  workflow_dispatch:
    inputs:
      deploy_sha:
        description: Image/model commit SHA
        required: true
        type: string
permissions:
  contents: read
  id-token: write
concurrency:
  group: rasa-mantle-dev-deploy
  cancel-in-progress: false
env:
  AWS_REGION: us-east-1
  EKS_CLUSTER: rasa
  NAMESPACE: rasa-mantle
  RELEASE: rasa-mantle
  ECR_REPOSITORY: rasa-mantle
  MODEL_BUCKET: bcp-nlwe-rasa-model
  MODEL_PREFIX: models/mantle
  CHART: k8s/dev/charts/rasa-3.0.0-rc.18.tgz
  VALUES: k8s/dev/dev-values.yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Set deployment SHA
        id: deploy
        env:
          DEPLOY_SHA: ${{ inputs.deploy_sha }}
        shell: bash
        run: |
          [[ "${DEPLOY_SHA}" =~ ^[0-9a-f]{40}$ ]] || exit 1
          echo "sha=${DEPLOY_SHA}" >> "${GITHUB_OUTPUT}"
      - name: Checkout deployment commit
        uses: actions/checkout@v4
        with:
          ref: ${{ steps.deploy.outputs.sha }}
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::534725115372:role/BrookeRasaMantleGitHubActionsRole
          aws-region: ${{ env.AWS_REGION }}
      - name: Verify image
        run: |
          aws ecr describe-images \
            --repository-name "${ECR_REPOSITORY}" \
            --image-ids imageTag="${{ steps.deploy.outputs.sha }}" \
            --region "${AWS_REGION}"
      - name: Wait for matching model
        shell: bash
        run: |
          model_key="${MODEL_PREFIX}/${{ steps.deploy.outputs.sha }}-model.tar.gz"
          for attempt in $(seq 1 30); do
            if aws s3api head-object \
              --bucket "${MODEL_BUCKET}" --key "${model_key}" \
              --region "${AWS_REGION}" >/dev/null 2>&1; then
              echo "Model is available: ${model_key}"
              exit 0
            fi
            echo "Waiting for ${model_key} (${attempt}/30)"
            sleep 20
          done
          echo "Matching model was not found."
          exit 1
      - uses: azure/setup-kubectl@v4
      - uses: azure/setup-helm@v4
        with:
          version: v4.0.0
      - name: Configure EKS
        run: |
          aws eks update-kubeconfig --region "${AWS_REGION}" --name "${EKS_CLUSTER}"
      - name: Lint chart
        run: |
          helm lint "${CHART}" -n "${NAMESPACE}" -f "${VALUES}"
      - name: Deploy Rasa Mantle
        run: |
          helm upgrade --install "${RELEASE}" "${CHART}" \
            -n "${NAMESPACE}" -f "${VALUES}" \
            --set-string image.tag="${{ steps.deploy.outputs.sha }}" \
            --set-string "extraArgs[4]=${MODEL_PREFIX}/${{ steps.deploy.outputs.sha }}-model.tar.gz" \
            --rollback-on-failure --timeout 15m
      - name: Verify rollout
        run: |
          kubectl rollout status deployment/rasa-mantle -n "${NAMESPACE}" --timeout=15m
          kubectl get pods -n "${NAMESPACE}" -o wide
```

The model wait hides all head-object errors, including permission errors. A timeout is not proof the object is absent; check IAM if needed. Checking out the artifact SHA also loads the Helm values from that revision. During the earlier QA promotion design we changed configuration checkout to the current environment branch, then replaced the design with branch-specific builds.

### Version mismatch lesson

The first QA pipeline used3.21.0.dev5 while the code expected newer Mantle syntax. It failed validation with missing `llm:` even though DEV worked. The recorded developer correction was to use.dev8, not add a new `llm:` blindly. Later the supplied QA workflow and running PROD confirmed.dev11.

```bash
rg -n 'RASA_PRO_VERSION|rasa/rasa-pro:' Dockerfile .github/workflows
actionlint .github/workflows/*.yaml
```

Keep Dockerfile defaults and all build/train pins aligned. A merge can reintroduce an older workflow; fixing the pin on only one branch does not resolve workflow design divergence.

## 14. Branch promotion and first deployment review

Chosen direction: **DEV → QA → main**. `main` represents PROD, not a place to bypass QA simply to store files.

We created the feature branch from QA:

```bash
git fetch origin qa
git switch -c feature/mantle-prod-setup origin/qa
mkdir -p k8s/prod
cp -R k8s/qa/charts k8s/prod/
cp k8s/qa/qa-values.yaml k8s/prod/prod-values.yaml
cp k8s/qa/studio-values.yaml k8s/prod/
cp k8s/qa/kafka-values.yaml k8s/prod/
cp k8s/qa/*certificate.yaml k8s/prod/
cp k8s/qa/auto-ebs-sc-wffc.yaml k8s/prod/
```

After editing and reviewing, pushed branch `feature/mantle-prod-setup`. User had not created the PR at the last explicit statement. Final instruction was:

```bash
gh pr create \
  --base dev \
  --head feature/mantle-prod-setup \
  --title "Add Mantle PROD configuration and CI/CD" \
  --body "Adds production Helm configuration and a combined build, train, publish, and deploy workflow using Rasa Pro 3.21.0.dev11 and PROD OIDC access. The PROD workflow runs only on main."
```

Because the feature branch began from QA, inspect its entire diff against DEV before merge. It can contain more than the new PROD files. No evidence here confirms the subsequent PR number, approval, merges, or first automatic deployment.

### Pre-merge review

```bash
git fetch origin dev qa main
git diff --stat origin/dev...HEAD
git log --oneline origin/dev..HEAD
actionlint .github/workflows/*.yaml
git diff --cached --check
rg -n '534725115372|qa-rasa|dev-bcp|dva-dev|transfer-dev' k8s/prod --glob '*.yaml'
rg -n '534725115372|qa-rasa|k8s/qa|PROD_RASA_LICENSE' \
  .github/workflows/deploy-rasa-mantle-prod.yaml
```

Expected stale-environment scans return no matches. A broad pattern like `rasa\.cwmwrw6dbsxc` matched part of `qa-rasa...` in a previous scan; substring matches can be misleading. Review context, not just match count.

Adding the PROD workflow on DEV/QA does not itself trigger that PROD workflow. Other branch workflows may still trigger for other matching source changes in the merge. On `main`, matching path changes start PROD CI/CD. We recommended low traffic for the first automated PROD rollout because shared dependencies still exist; that is not a guarantee that no risk exists at low traffic.

## 15. Lag collector implementation

### Why copy the existing collector

We reused the known collector pattern rather than introducing a new monitoring stack. It is namespace-specific and publishes into the same CloudWatch metric namespace `RasaKafka`, with an extra `Namespace=rasa-mantle` dimension to distinguish it from legacy metrics.

Files were initially separate SA YAML, scripts JSON, and CronJob JSON. We combined them into a multi-document `k8s/prod/kafka-lag-metrics.yaml`. Three Kubernetes kinds in one file is normal; it is unrelated to Kafka's3 replicas.

The saved diff had12 physical lines because ConfigMap/CronJob were long JSON lines; JSON documents can be embedded as YAML documents. The appendix formats them as readable YAML. Terminal wrapping in the pasted diff was repaired for that rendering; it is not a new live export.

### Collector stages

1. Init container runs `kafka-consumer-groups.sh --describe --group studio-mantle`.
2. Awk selects rows for topic `rasa-mantle` with a numeric lag column.
3. Sums total lag, finds max partition lag, counts partitions and unique active consumers.
4. Writes metric JSON into shared emptyDir `/work`.
5. Publisher container calls `aws cloudwatch put-metric-data`.
6. If init fails, publisher never starts.

Metrics:

| Metric | Dimensions |
|---|---|
| ConsumerGroupTotalLag |ClusterName, Namespace, Topic, ConsumerGroup |
| ConsumerGroupMaxPartitionLag |Same |
| PartitionCount |Same |
| ActiveConsumerCount |Same |
| CollectorSuccess=1 |ClusterName, Namespace |

The dimensions form distinct CloudWatch time series. Existing dashboards/alarms using only the old dimensions will not automatically display the new series. The script does not publish `CollectorSuccess=0` on error; missing-data handling and job failure monitoring matter.

### IAM

SA `kafka-lag-metrics` uses role `RasaKafkaLagMetricsRole`. We extended EKS trust to preserve:

```text
system:serviceaccount:rasa:kafka-lag-metrics
system:serviceaccount:rasa-mantle:kafka-lag-metrics
```

Role policy `RasaKafkaLagMetricPublisher` allowed only `cloudwatch:PutMetricData` with `cloudwatch:namespace=RasaKafka`. No namespace-policy expansion was required because the CloudWatch namespace did not change. The Kubernetes namespace dimension is a metric dimension, not IAM's CloudWatch namespace condition.

### Client config secret creation — recorded recipe

```bash
kubectl --context "$PROD_CONTEXT" get secret kafka-user-passwords \
  -n rasa-mantle -o jsonpath='{.data.client-passwords}' |
base64 --decode | cut -d, -f1 |
python3 -c '
import json, sys
password = sys.stdin.read().rstrip("\n")
assert password, "Kafka password is empty"
password = password.replace("\\", "\\\\").replace("\"", "\\\"")
config = (
    "security.protocol=SASL_PLAINTEXT\n"
    "sasl.mechanism=PLAIN\n"
    "sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule "
    f"required username=\"kafka\" password=\"{password}\";\n"
)
json.dump({
    "apiVersion":"v1", "kind":"Secret",
    "metadata":{"name":"kafka-lag-client-config","namespace":"rasa-mantle"},
    "type":"Opaque", "stringData":{"client.properties":config}
}, sys.stdout)
' |
kubectl --context "$PROD_CONTEXT" create -f -
```

Secret created, then manifest applied and a manual job launched:

```bash
kubectl --context "$PROD_CONTEXT" apply -f k8s/prod/kafka-lag-metrics.yaml
JOB="kafka-lag-test-$(date +%s)"
kubectl --context "$PROD_CONTEXT" create job --from=cronjob/kafka-lag-metrics \
  "$JOB" -n rasa-mantle
kubectl --context "$PROD_CONTEXT" logs "job/$JOB" -n rasa-mantle -c collector
kubectl --context "$PROD_CONTEXT" logs "job/$JOB" -n rasa-mantle -c publisher
```

### Actual failure and meaning

Recorded job `kafka-lag-test-1792442333` failed in init:

```text
ERROR: No valid rows found for group=studio-mantle, topic=rasa-mantle
CURRENT-OFFSET=-  LOG-END-OFFSET=0  LAG=-
```

There were three assigned partitions with a consumer ID. Authentication, connectivity, and group membership worked. The collector expected numeric lag, but no committed offsets existed on the empty topic. This was not evidence of node pressure or a bad Kafka password.

We first kept the schedule suspended, then Rahul asked to enable it before traffic. The local saved diff shows `suspend:false`. Enabling did not fix missing offsets; it could produce repeated failed jobs until a conversation is processed. Do not publish fabricated lag0 to hide an unknown/uninitialized state.

Check local and cluster separately:

```bash
yq 'select(.kind == "CronJob") | .spec.suspend' k8s/prod/kafka-lag-metrics.yaml
kubectl --context "$PROD_CONTEXT" get cronjob kafka-lag-metrics -n rasa-mantle \
  -o jsonpath='{.spec.suspend}{"\n"}'
```

`yq '.spec.suspend'` across all 3 documents prints null/null/boolean because SA/CM do not have that field.

Enable (only if desired; this changes scheduling):

```bash
yq -i '(select(.kind == "CronJob") | .spec.suspend) = false' k8s/prod/kafka-lag-metrics.yaml
kubectl --context "$PROD_CONTEXT" apply -f k8s/prod/kafka-lag-metrics.yaml
```

Successful follow-up requires a real test conversation, numeric committed offsets, collector output, publisher success, and matching CloudWatch data. No successful publish was shown in this thread.

## 16. Jambonz routing and the failed-call investigation

### Base URLs versus call webhook

The first message to Jim supplied only the PROD hostname. That was insufficient to specify the custom HTTP entry point. Inspecting the channel code established:

```python
@classmethod
def name(cls) -> str:
    return "jambonz_stream"

def _construct_webhook_url(self, path: str) -> str:
    base_url = self.server_url if self.server_url.startswith("http") else f"https://{self.server_url}"
    return f"{base_url}/webhooks/{self.name()}{path}"

@blueprint.route("/webhook", methods=["POST"])
@requires_basic_auth(self.username, self.password)
async def webhook(request):
    # First entry point; returns the listen verb.
    ...
```

The derived route to configure is:

```text
POST https://mantle-assistant.rasa.brooke.ai/webhooks/jambonz_stream/webhook
```

Other observed routes:

| Route | Purpose |
|---|---|
| `/webhooks/jambonz_stream/` | Channel GET health route |
| `/webhooks/jambonz_stream/call_status` | POST call status callback |
| `/webhooks/jambonz_stream/webhook` | POST initial incoming call webhook |
| `/webhooks/jambonz_stream/transfer` | POST transfer hook |
| `/webhooks/jambonz_stream/verb` | POST verb hook |
| `/webhooks/jambonz_stream/websocket` | Derived audio streaming WebSocket path |

The channel builds `wss://` from a bare hostname or `https://` server_url. The selected PROD server_url was the bare hostname, yielding secure callback/stream URLs. The code uses a string replacement for an explicit HTTP(S) scheme; do not change scheme casually without comparing generated URLs.

The handlers have a Basic Auth decorator. Whether credentials are required depends on actual configured username/password and decorator behavior. No real auth credential pair was shown. Do not assume the Rasa API token is the Jambonz Basic Auth password or the outbound Jambonz API key.

### What actually passed

- Root HTTPS returned200.
- Ingress host resolved to the shared existing load balancer.
- Service `rasa-mantle` port5005 had3 pod endpoints.
- `/status` previously authenticated and returned the loaded model.
- GET to `/webhooks/jambonz_stream/webhook` returned405, consistent with the POST-only handler.

### What those tests do not prove

- A405 GET does not test a POST response, Basic Auth, Redis storage in the handler, or Jambonz's connection from its own host.
- An HTTP root200 does not validate the WebSocket handshake or audio.
- No application logs during a call does not alone prove no network request arrived; access logging may be disabled and failures may occur at gateway/channel levels.
- Healthy DB creation and /status do not prove reporting, ASR/TTS, or call metadata compatibility.
- We did not establish the carrier announcement's exact meaning from an approximate “msg6 us...” description.

### Commands used

```bash
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' --max-time 15 \
  https://mantle-assistant.rasa.brooke.ai/

kubectl --context "$PROD_CONTEXT" get ingress,svc,endpoints -n rasa-mantle

kubectl --context "$PROD_CONTEXT" logs -n rasa-mantle deployment/rasa-mantle \
  -c rasa --all-pods=true --prefix --since=5m --follow --max-log-requests=10

rg -n 'def name|route\(|webhook|Blueprint' channels/jambonz_verb.py
sed -n '575,590p' channels/jambonz_verb.py
sed -n '880,925p' channels/jambonz_verb.py
```

Kubernetes warned Endpoints is deprecated at this version. A follow-up uses:

```bash
kubectl --context "$PROD_CONTEXT" get endpointslices -n rasa-mantle \
  -l kubernetes.io/service-name=rasa-mantle
```

### Next investigation, in order

1. Confirm the test number is assigned to the intended PROD Jambonz application.
2. Confirm full URL, methodPOST, and channel auth settings; preserve working QA configuration except environment-specific host/credentials.
3. Obtain failed call SID, exact timestamp/timezone, Jambonz feature-server logs, and HTTP status/error for webhook delivery.
4. If the webhook succeeds, inspect returned WebSocket target, handshake, and audio setup.
5. Correlate Mantle errors, ingress access logs if enabled, and dependency errors.
6. Test conversation persistence in tracker/Studio and committed Kafka offsets.

Do not change the shared load balancer, security groups, or legacy call routes simply because a call failed. The observations did not identify a load-balancer fault.

## 17. Verification, controlled cutover, and rollback

### Read-only operating checks

```bash
aws sts get-caller-identity
kubectl --context "$PROD_CONTEXT" get nodes -l workload=rasa-mantle
kubectl --context "$PROD_CONTEXT" get pods -n rasa-mantle -o wide
kubectl --context "$PROD_CONTEXT" get pvc,hpa -n rasa-mantle
helm --kube-context "$PROD_CONTEXT" list -n rasa-mantle
helm --kube-context "$PROD_CONTEXT" status rasa-mantle -n rasa-mantle
kubectl --context "$PROD_CONTEXT" get certificates -n istio-system
kubectl --context "$PROD_CONTEXT" get events -n rasa-mantle --sort-by='.lastTimestamp'
kubectl --context "$PROD_CONTEXT" top nodes
kubectl --context "$PROD_CONTEXT" top pods -n rasa-mantle
```

Compare legacy namespace too; no baseline should assume untouched means healthy:

```bash
kubectl --context "$PROD_CONTEXT" get pods,hpa -n rasa
```

### Test gates before broad customer routing

- [ ] Intended image/model SHA loaded, expected Rasa Pro version.
- [ ] Controlled test number reaches the correct webhook.
- [ ] Audio both ways, expected language behavior, interruption/turn behavior.
- [ ] Expected bot flow, DVA calls and integration permissions.
- [ ] Transfer destination and completion correct.
- [ ] Hangup/session cleanup correct.
- [ ] Active-call behavior during planned pod termination tested in a controlled setting.
- [ ] Tracker persistence and Studio conversation view correct.
- [ ] No new DLQ failures; ingestion consumer healthy.
- [ ] Lag metrics publish and dashboards/alarms use the right dimensions.
- [ ] Resource capacity and HPA behavior tested for expected load.
- [ ] QA/users have the intended Studio access.
- [ ] Git configuration and runtime configuration match.
- [ ] Traffic rollback owner, application/number mapping, and decision criteria recorded.

These are remaining acceptance checks, not claims of execution.

### Cutover plan

1. Keep legacy bot/Studio/Kafka running.
2. Validate Mantle through a test number.
3. Agree with application/Jambonz owners on the exact number/application/dealer routing being changed.
4. Route the agreed new calls to Mantle.
5. Allow already active legacy calls to finish; avoid terminating them during routing changes.
6. Watch call success/audio/transfers, errors, lag, DLQ, and shared DB/Redis/node metrics.
7. Expand only after agreed acceptance.

A test number pointing to Mantle is not broad production cutover. Conversation history stays in old databases unless a separate data migration is planned.

### Rollback has two layers

**Call routing rollback:** have the Jambonz owner direct new calls to the previous application/webhook. Existing in-flight sessions require care; routing back does not magically transfer active calls between bots.

**Application release rollback:** inspect known-good Helm revision and retained image/model artifacts, then restore a reviewed revision if appropriate.

```bash
helm --kube-context "$PROD_CONTEXT" history rasa-mantle -n rasa-mantle
# Only after selecting a real known-good revision:
# helm --kube-context "$PROD_CONTEXT" rollback rasa-mantle <REVISION> -n rasa-mantle --wait --timeout 15m
```

Do not use Helm rollback to imply external DB migration reversal. Do not remove node groups, PVCs, or old databases as part of an urgent app rollback.

## 18. Troubleshooting lessons

| Symptom | What we found | Correct lesson |
|---|---|---|
| Invalid S3 bucket name empty | Unset shell variable | Assign and verify non-secret variables before command |
| EKS nodegroup invalid characters | Literal `<nodegroup-name-from-above>` used | Replace placeholders with real returned IDs |
| QA Kafka Pending with low CPU usage | CPU requests exhausted on eligible node; anti-affinity blocked others | Scheduler uses requests/constraints, not just top-node utilization |
| `set -- $entry` DB loop failed | zsh splitting difference | Use explicit arguments or Bash |
| psql password prompt unexpectedly | Empty/missing password variable | Check credential source, do not assume variable survived shell change |
| RDS network timeout on Mac | Private endpoint reachable inside cluster | Diagnose route/SG/client path before password changes |
| Reporting project empty | No project/data in views yet | Do not fabricate reporting rows to make a query nonempty |
| Studio nodeSelector null | Wrong `.global` keys | Inspect chart defaults/helpers and rendered pod spec |
| Studio still used app RDS | Wrong `.global.database.host` | Set `.config.database.host` |
| Certificate NotFound | Wrong resource name | Read metadata.name, do not infer from release |
| Initial TLS syscall error | Certificate not Ready | Wait and retest before replacing ingress |
| Missing secret key | RC18 expected RASA_LICENSE; legacy key rasaProLicense | Exact rendered references matter |
| PROD appeared to have Langfuse | Empty PROD_CONTEXT read QA | Explicit context guard |
| QA model validation differed from DEV | Older Rasa base version.dev5 | Align build/train/runtime versions; don't blindly edit model schema |
| Helm field conflict | kubectl-edit owned ConfigMap data.integrations | Compare live/Git before taking ownership |
| Kafka password not specified | Assumed env variable not populated | Read actual generated Secret |
| Lag Init:Error | No numeric lag on empty topic | Unknown/uncommitted is not measured lag0 |
| Telephone failure with HTTP200 | Base endpoint only was healthy | Inspect full webhook, auth, caller-side logs, WebSocket |
| GET webhook405 | Method mismatch | Configure POST; does not itself prove call delivery |

### DEV Helm ownership conflict in detail

Observed DEV release status failed revision26, while old pod stayed2/2. Helm4 server-side apply conflicted on ConfigMap `.data.integrations` owned by manager `kubectl-edit` from October14 at13:00:10Z. Managed fields identify a tool manager and timestamp, not the human who typed the edit.

```bash
kubectl --context "$DEV_CONTEXT" get configmap rasa-mantle-configmap \
  -n rasa-mantle -o json --show-managed-fields |
jq '.metadata.managedFields[] | select(.manager=="kubectl-edit") |
    {manager,operation,time,fieldsV1}'
```

We saved live integrations, rendered Git values, extracted with yq, and diffed:

```bash
kubectl --context "$DEV_CONTEXT" get configmap rasa-mantle-configmap \
  -n rasa-mantle -o jsonpath='{.data.integrations}' \
  > /tmp/dev-mantle-live-integrations.yaml

git show origin/dev:k8s/dev/dev-values.yaml > /tmp/dev-mantle-git-values.yaml
helm template rasa-mantle k8s/dev/charts/rasa-3.0.0-rc.18.tgz \
  -n rasa-mantle -f /tmp/dev-mantle-git-values.yaml > /tmp/dev-mantle-rendered.yaml

yq -r 'select(.kind=="ConfigMap" and .metadata.name=="rasa-mantle-configmap") | .data.integrations' \
  /tmp/dev-mantle-rendered.yaml > /tmp/dev-mantle-git-integrations.yaml

diff -u /tmp/dev-mantle-live-integrations.yaml /tmp/dev-mantle-git-integrations.yaml
```

First yq was missing; output redirection created an empty file and the diff misleadingly showed the entire live config removed. Installed yq, reran extraction, then interpreted the real diff.

Real differences included live OTLP/Langfuse tracing missing in Git, old filler settings replaced by engine background audio, and removed Jambonz parameters in Git. Applying Git was not just ownership metadata: it also replaced those live settings.

PR46 added `--force-conflicts` temporarily to DEV Helm upgrade. It succeeded at revision27; user subsequently stated the removal was done. It was not added as a permanent default to QA/PROD. Forcing ownership without reviewing the content can silently discard useful manual edits.

## 19. Remaining work and learning exercises

### Remaining at last recorded evidence

1. Finish reviewing/promoting PROD config/workflow DEV→QA→main and observe first automated PROD run.
2. Verify existing GitHub training license works for intended PROD build; retain selected existing secret reference.
3. Resolve failed PROD Jambonz test call and verify an end-to-end conversation.
4. Verify Studio reporting/project data, DLQ, numeric consumer offsets, and successful CloudWatch publishing.
5. Check lag dashboards/alarms and behavior when collector fails or offsets are absent.
6. Validate transfers, call drain, expected concurrency, and scale behavior.
7. Review rendered deployment placement and any desired availability-zone spread beyond initial node layout.
8. Document shared-dependency capacity and operating owners.
9. Perform approved routing cutover with rollback ready.

No successful call, first automated PROD build, or customer cutover should be marked complete based only on this workbook.

### Practice exercises

1. Explain why DEV and PROD can both have cluster name `rasa`.
2. Show the difference between Kubernetes SA `rasa-assistant` and QA IAM role `qa-rasa-assistant`.
3. Identify which RDS instance receives tracker writes versus Studio ingestion in PROD.
4. Explain why reporting_v1 is not renamed to bcp_reporting.
5. Render Studio and identify its3 DB_HOST entries.
6. Explain why a matching toleration alone is not a placement guarantee.
7. Distinguish RF 3, observed ISR 3, minISR 1, and partitions 3.
8. Explain why a pending pod can coexist with low actual CPU utilization.
9. Explain why a Studio license upload did not populate Kubernetes RASA_LICENSE.
10. Explain why `git diff --check` missed new untracked PROD files.
11. Trace the call from webhook POST to listen verb to secure WebSocket.
12. Interpret200 root,405 GET webhook,401 POST,404 wrong path, and a caller-side timeout without treating them as equivalent.
13. Explain why the collector has initContainers and a publisher rather than publishing after a failed collection.
14. Explain the difference between changing customer routing and rolling back Helm.
15. Explain why rebuilding in PROD is not byte-for-byte QA artifact promotion.

### Short daily/return-to-work routine

Set context/account → inspect branch/status → check pods/HPA/certificates → inspect latest jobs/logs → compare Git values with rendered/live state → act only on the identified failure → validate behavior → record evidence and remaining items.

## 20. Full configuration snapshots

The following Helm/manifest snapshots were recovered from the saved October19 staged diff. Long terminal-wrapped lines were rejoined. Empty lines/comments are preserved where possible. They are **historical source snapshots**, not guaranteed current production manifests. Sensitive values are represented by Secret references; none are decoded here.

The original snapshot retained some obsolete/ignored nested keys (`rasa.enabled`, `rasa.replicaCount`, `rasa.credentials`) and commented tracing examples. The chart's migration notes said root deployment settings are authoritative; the effective root replica count/HPA settings were verified. These historical leftovers are shown for fidelity, not recommended as new configuration.

The retention settings in these files are also historical: Studio DELETE_CONVERSATIONS_OLDER_THAN_HOURS=2160 (90 days), and a comment describes model-packaged90 day tracker retention. Those are not proof of the organization's current approved retention, nor proof cleanup executed. Legacy analytics120 day retention is a separate job. Any alignment is a separate reviewed task.

### Snapshot: `k8s/prod/auto-ebs-sc-wffc.yaml`

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: auto-ebs-sc-wffc
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  encrypted: "true"
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

### Snapshot: `k8s/prod/kafka-lag-metrics.yaml`

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kafka-lag-metrics
  namespace: rasa-mantle
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::451781105151:role/RasaKafkaLagMetricsRole
    eks.amazonaws.com/sts-regional-endpoints: 'true'
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: kafka-lag-metrics-scripts
  namespace: rasa-mantle
data:
  collect.sh: |
    #!/usr/bin/env bash
    set -Eeuo pipefail

    output_file=/work/metric-data.json
    : > "${output_file}"
    printf '[\n' >> "${output_file}"
    first_metric=true

    append_metric() {
      local metric_name="$1"
      local metric_value="$2"
      local dimensions="$3"

      if [ "${first_metric}" = false ]; then
        printf ',\n' >> "${output_file}"
      fi
      first_metric=false

      cat >> "${output_file}" <<EOF
      {
        "MetricName": "${metric_name}",
        "Dimensions": ${dimensions},
        "Value": ${metric_value},
        "Unit": "Count",
        "StorageResolution": 60
      }
    EOF
    }

    for group in ${CONSUMER_GROUPS}; do
      command_output="$(
        /opt/bitnami/kafka/bin/kafka-consumer-groups.sh \
          --bootstrap-server "${BOOTSTRAP_SERVER}" \
          --command-config /etc/kafka-client/client.properties \
          --describe \
          --group "${group}" 2>&1
      )" || {
        echo "ERROR: Kafka lag query failed for ${group}" >&2
        echo "${command_output}" >&2
        exit 1
      }

      parsed="$(
        printf '%s\n' "${command_output}" |
        awk -v group="${group}" -v topic="${TOPIC}" '
          $1 == group &&
          $2 == topic &&
          $3 ~ /^[0-9]+$/ &&
          $6 ~ /^[0-9]+$/ {
            lag = $6 + 0
            total += lag
            if (lag > max) max = lag
            partitions += 1
            if ($7 != "-" && !consumer_seen[$7]++) active_consumers += 1
          }
          END {
            if (partitions == 0) exit 2
            printf "%d %d %d %d", total, max, partitions, active_consumers
          }
        '
      )" || {
        echo "ERROR: No valid rows found for group=${group}, topic=${TOPIC}" >&2
        echo "${command_output}" >&2
        exit 1
      }

      read -r total_lag max_lag partition_count active_consumers <<< "${parsed}"

      echo "group=${group} total_lag=${total_lag} max_partition_lag=${max_lag} partitions=${partition_count} active_consumers=${active_consumers}"

      dimensions="[
        {\"Name\":\"ClusterName\",\"Value\":\"${CLUSTER_NAME}\"},
        {\"Name\":\"Namespace\",\"Value\":\"rasa-mantle\"},
        {\"Name\":\"Topic\",\"Value\":\"${TOPIC}\"},
        {\"Name\":\"ConsumerGroup\",\"Value\":\"${group}\"}
      ]"

      append_metric "ConsumerGroupTotalLag" "${total_lag}" "${dimensions}"
      append_metric "ConsumerGroupMaxPartitionLag" "${max_lag}" "${dimensions}"
      append_metric "PartitionCount" "${partition_count}" "${dimensions}"
      append_metric "ActiveConsumerCount" "${active_consumers}" "${dimensions}"
    done

    collector_dimensions="[
      {\"Name\":\"ClusterName\",\"Value\":\"${CLUSTER_NAME}\"},
        {\"Name\":\"Namespace\",\"Value\":\"rasa-mantle\"}
    ]"
    append_metric "CollectorSuccess" "1" "${collector_dimensions}"

    printf '\n]\n' >> "${output_file}"
    echo "Metric payload created at ${output_file}"
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: kafka-lag-metrics
  namespace: rasa-mantle
spec:
  concurrencyPolicy: Forbid
  failedJobsHistoryLimit: 5
  jobTemplate:
    metadata:
      creationTimestamp: null
    spec:
      activeDeadlineSeconds: 120
      backoffLimit: 1
      template:
        metadata:
          annotations:
            sidecar.istio.io/inject: 'false'
          creationTimestamp: null
          labels:
            app.kubernetes.io/name: kafka-lag-metrics
            sidecar.istio.io/inject: 'false'
        spec:
          containers:
          - command:
            - /bin/sh
            - -ec
            - |
              echo "Publishing metric payload:"
              cat /work/metric-data.json
              aws cloudwatch put-metric-data \
                --region "${AWS_REGION}" \
                --namespace "${CW_NAMESPACE}" \
                --metric-data file:///work/metric-data.json
              echo "CloudWatch publish succeeded"
            env:
            - name: AWS_REGION
              value: us-east-1
            - name: AWS_DEFAULT_REGION
              value: us-east-1
            - name: CW_NAMESPACE
              value: RasaKafka
            image: public.ecr.aws/aws-cli/aws-cli:2.36.8
            imagePullPolicy: IfNotPresent
            name: publisher
            resources:
              limits:
                cpu: 100m
                memory: 256Mi
              requests:
                cpu: 25m
                memory: 64Mi
            terminationMessagePath: /dev/termination-log
            terminationMessagePolicy: File
            volumeMounts:
            - mountPath: /work
              name: work
              readOnly: true
          dnsPolicy: ClusterFirst
          initContainers:
          - command:
            - /bin/bash
            - /scripts/collect.sh
            env:
            - name: BOOTSTRAP_SERVER
              value: kafka.rasa-mantle.svc.cluster.local:9092
            - name: CLUSTER_NAME
              value: rasa
            - name: TOPIC
              value: rasa-mantle
            - name: CONSUMER_GROUPS
              value: studio-mantle
            image: docker.io/bitnamilegacy/kafka:4.0.0-debian-12-r8
            imagePullPolicy: IfNotPresent
            name: collector
            resources:
              limits:
                cpu: 500m
                memory: 512Mi
              requests:
                cpu: 100m
                memory: 256Mi
            terminationMessagePath: /dev/termination-log
            terminationMessagePolicy: File
            volumeMounts:
            - mountPath: /scripts
              name: scripts
              readOnly: true
            - mountPath: /etc/kafka-client
              name: kafka-client
              readOnly: true
            - mountPath: /work
              name: work
          restartPolicy: Never
          schedulerName: default-scheduler
          securityContext: {}
          serviceAccount: kafka-lag-metrics
          serviceAccountName: kafka-lag-metrics
          terminationGracePeriodSeconds: 30
          volumes:
          - configMap:
              defaultMode: 365
              name: kafka-lag-metrics-scripts
            name: scripts
          - name: kafka-client
            secret:
              defaultMode: 292
              secretName: kafka-lag-client-config
          - emptyDir: {}
            name: work
          nodeSelector:
            workload: rasa-mantle
          tolerations:
          - key: workload
            operator: Equal
            value: rasa-mantle
            effect: NoSchedule
      ttlSecondsAfterFinished: 900
  schedule: '* * * * *'
  startingDeadlineSeconds: 60
  successfulJobsHistoryLimit: 3
  suspend: false
```

### Snapshot: `k8s/prod/kafka-values.yaml`

```yaml

broker:
  replicaCount: 0
controller:
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchLabels:
              app.kubernetes.io/component: controller-eligible
              app.kubernetes.io/instance: kafka
              app.kubernetes.io/name: kafka
          topologyKey: kubernetes.io/hostname
  controllerOnly: false
  heapOpts: -Xmx1024m -Xms1024m
  minId: 0
  pdb:
    create: true
    maxUnavailable: 1
  persistence:
    accessModes:
      - ReadWriteOnce
    enabled: true
    size: 30Gi
    storageClass: auto-ebs-sc-wffc
  replicaCount: 3
  resources:
    limits:
      cpu: "2"
      ephemeral-storage: 2Gi
      memory: 4Gi
    requests:
      cpu: "1"
      ephemeral-storage: 50Mi
      memory: 2Gi
  nodeSelector:
    workload: rasa-mantle
  tolerations:
    - key: workload
      operator: Equal
      value: rasa-mantle
      effect: NoSchedule
externalAccess:
  enabled: false
global:
  security:
    allowInsecureImages: true
image:
  pullPolicy: IfNotPresent
  registry: docker.io
  repository: bitnamilegacy/kafka
  tag: 4.0.0-debian-12-r10
listeners:
  client:
    protocol: SASL_PLAINTEXT
  controller:
    protocol: SASL_PLAINTEXT
  interbroker:
    protocol: SASL_PLAINTEXT
sasl:
  client:
    users:
      - kafka
  controller:
    user: controller_user
  controllerMechanism: PLAIN
  enabledMechanisms: PLAIN
  interBrokerMechanism: PLAIN
  interbroker:
    user: inter_broker_user
overrideConfiguration:
  default.replication.factor: 3
  min.insync.replicas: 1
  log.retention.hours: 168
  log.retention.bytes: -1
  unclean.leader.election.enable: false
```

### Snapshot: `k8s/prod/prod-values.yaml`

```yaml
image:
  repository: "451781105151.dkr.ecr.us-east-1.amazonaws.com/rasa-mantle"
  pullPolicy: Always
  tag: "b1bed9ad7e2b40886ca0d4faafdb26ee10f1005d"
serviceAccount:
  create: true
  name: rasa-assistant
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::451781105151:role/rasa-assistant
rasa:
  enabled: true
  logging:
    logLevel: INFO
  replicaCount: 2
  authToken:
    secretName: "rasa-secrets"
    secretKey: "authToken"
  jwtSecret: null
  environment: production
  enableApi: true
  credentials: null
  telemetry:
    enabled: true
    debug: false
  integrations:
    # No `llm:` here: rasa-pro 3.21.0.dev8+ rejects it. The orchestrator group is
    # named by agent.yml's `orchestrator.model_group` (packaged in the model).
    model_groups:
      - id: openai-latest
        models:
          - provider: openai
            model: gpt-5.2-2025-12-11
            api_base: https://api.openai.com/v1
            # rasa-pro 3.21.0.dev5+ rejects `api_key_env:`; OPENAI_API_KEY comes
            # from the rasa-secrets openaiApiKey entry in extraEnv below.
            api_key: ${OPENAI_API_KEY}
            timeout: 12
            max_tokens: 256
            temperature: 1.0
      - id: openai-gpt-4o
        models:
          - max_tokens: 256
            model: gpt-4o-2024-11-20
            provider: openai
            timeout: 12
      - id: openai-embeddings
        models:
          - model: text-embedding-3-small
            provider: openai
    channels:
      rest:
        enabled: true
      inspector:
        enabled: true
      channels.jambonz_verb.JambonzVerbInputChannel:
        server_url: mantle-assistant.rasa.brooke.ai
        #    silence_timeout: 9
        interruptions:
          enabled: true
          min_words: 3
        # Channel-layer turn merge (NET-1118): hold a finalized transcript and
        # concatenate a continuation after a short pause, so "Jack ... Black"
        # reaches the flow as one turn. mode: llm | buffer.
        turn_merge:
          enabled: true
          mode: llm
          turn_detection:
            model: openai/gpt-5.4-mini
            absolute_max_silence_ms: 4000
            model_timeout_ms: 2500
            model_temperature: 0.0
          # buffer-mode fallback (used when mode: buffer)
          window_ms: 3000
          hold_max_words: 4
          max_hold_ms: 4000
        asr:
          name: custom_asr.reconnecting_deepgram.ReconnectingDeepgramASR # was: connectors.deepgram.DeepgramASR
          endpoint: api.deepgram.com
          eot_threshold: 0.85
          eot_timeout_ms: 8000
          language_map:
            en:
              language: en
              model: flux-general-multi
            es:
              language: es
              model: flux-general-multi
        tts:
          name: connectors.elevenlabs_tts.ElevenLabsTTS
          model_id: eleven_v4_turbo
          language_map:
            en:
              voice: OZxMHsGaBmV5pjMIDIn0
            es:
              voice: OZxMHsGaBmV5pjMIDIn0 # placeholder, swap for a Spanish-appropriate voice
        # tts:
        #   name: deepgram
        #   language_map:
        #     en:
        #       language: en-US
        #       model: aura-2-thalia-en
        #       # speed: 1.1
        #     es:
        #       language: es-US
        #       model: aura-2-estrella-es
        # tts:
        #   name: deepgram
        #   endpoint: wss://api.deepgram.com/v2/speak
        #   language_map:
        #     en:
        #       language: en-US
        #       model: flux-haley-en
        #     es:
        #       language: es-US
        #       model: flux-haley-en
        shared_state:
          type: redis
          host: master.rasa-rasa-redis-group1.yaiset.use1.cache.amazonaws.com
          port: 6379
          username: assistant
          use_ssl: true
          key_prefix: jambonz-mantle
          transfer_ttl_seconds: 120
          session_ttl_seconds: 3600
        # Engine background audio (replaces v1's Jambonz dub-track filler);
        # same track and volume as v1. The file ships in the image (/app/audio).
        background_audio:
          source: audio/brooke_background_ambient_noise.mp3
          level: 0.32
      # Talk to the agent through the browser mic: `rasa inspect --voice`.
      # Requires DEEPGRAM_API_KEY in .env (one key covers both ASR and TTS).
      browser_audio:
        enabled: true
        server_url: localhost:5005
        asr:
          name: deepgram
          language_map:
            en-US:
              language: en
              model: flux-general-en
          eot_threshold: 0.8
        tts:
          name: deepgram
          language_map:
            en-US:
              model: aura-2-asteria-en
              #    tracing:
              #      - type: otlp
              #        endpoint: jaeger:4317
              #        insecure: true
              #        service_name: rasa-mantle
              #      - type: langfuse
              #        public_key: ${LANGFUSE_PUBLIC_KEY}
              #        private_key: ${LANGFUSE_PRIVATE_KEY}
              #        host: ${LANGFUSE_HOST}
    # interaction_handling:
    #   global_silence_timeout: 9    # seconds
    # Configure the assistant to use our PostgreSQL instance as the Tracker Store, which records the assistant's conversations.
    tracker_store:
      enabled: true
      type: sql
      dialect: postgresql
      url: rasa.ca5ecrqmcbhd.us-east-1.rds.amazonaws.com
      db: assistant_mantle
      username: assistant
      port: 5432
    # Configure the assistant to use Redis as the Rasa Lock Store.
    # This is needed when you have a high-load scenario that requires the Rasa server to be replicated across multiple instances. It ensures that even with multiple servers, the messages for each conversation are handled in the correct sequence without any loss or overlap.
    lock_store:
      enabled: true
      type: concurrent_redis
      port: 6379
      host: master.rasa-rasa-redis-group1.yaiset.use1.cache.amazonaws.com
      username: assistant
      use_ssl: true
      key_prefix: rasamantle
    timer_store:
      type: redis
      host: master.rasa-rasa-redis-group1.yaiset.use1.cache.amazonaws.com
      port: 6379
      username: assistant
      use_ssl: true
      key_prefix: timermantle
    # Configure the assistant to use the Kafka broker. This allows us to perform further processing on the messages, like using the Rasa Studio Conversation View or Rasa Pro Analytics.
    event_broker:
      enabled: true
      type: kafka
      security_protocol: SASL_PLAINTEXT
      sasl_mechanism: PLAIN
      topic: rasa-mantle
      partition_by_sender: true
      url: kafka.rasa-mantle.svc.cluster.local:9092
      sasl_username: ${KAFKA_USER}
      sasl_password: ${KAFKA_PASSWORD}
      ssl_check_hostname: false
      # Conversation retention (SYST-322) lives in agent.yml under
      # `privacy: tracker_store_settings` (90 days, nightly 02:30), packaged into the
      # model. rasa-pro 3.21.0.dev9+ ignores `privacy:` here in endpoints for Mantle.
extraArgs:
  - --inspect
  - --remote-storage
  - aws
  - --model
  - models/mantle/b1bed9ad7e2b40886ca0d4faafdb26ee10f1005d-model.tar.gz
livenessProbe:
  enabled: true
  httpGet:
    path: /
    port: 5005
    scheme: HTTP
  initialDelaySeconds: 15
  periodSeconds: 15
  successThreshold: 1
  timeoutSeconds: 10
  failureThreshold: 6
  terminationGracePeriodSeconds: 30
readinessProbe:
  enabled: true
  httpGet: null
  exec:
    command:
      - /bin/sh
      - -c
      - 'curl -f "http://localhost:5005/status?token=${AUTH_TOKEN}"'
  initialDelaySeconds: 15
  periodSeconds: 15
  successThreshold: 1
  timeoutSeconds: 10
  failureThreshold: 6
terminationGracePeriodSeconds: 240
lifecycle:
  preStop:
    exec:
      command:
        - python
        - -m
        - channels.jambonz_drain
        - --timeout
        - "180"
resources:
  requests:
    cpu: "500m"
    memory: "1Gi"
  limits:
    cpu: "2"
    memory: "2Gi"
extraEnv:
  - name: IAM_CLOUD_PROVIDER
    value: aws
  - name: ELASTICACHE_REDIS_AWS_IAM_ENABLED
    value: "true"
  - name: RDS_SQL_DB_AWS_IAM_ENABLED
    value: "true"
  - name: AWS_DEFAULT_REGION
    value: us-east-1
  - name: SQL_TRACKER_STORE_SSL_MODE
    value: require
  - name: BUCKET_NAME
    value: bcp-efnw-rasa-model
  - name: DB_HOST
    value: rasa.ca5ecrqmcbhd.us-east-1.rds.amazonaws.com
  - name: DB_DATABASE
    value: assistant_mantle
  - name: DB_USER
    value: assistant
  - name: KAFKA_PASSWORD
    valueFrom:
      secretKeyRef:
        name: rasa-secrets
        key: kafkaSslPassword
  - name: KAFKA_USER
    value: kafka
  - name: REDIS_HOST
    value: master.rasa-rasa-redis-group1.yaiset.use1.cache.amazonaws.com
  - name: REDIS_USER
    value: assistant
  - name: AWS_ELASTICACHE_CLUSTER_NAME
    value: rasa-rasa-redis-group1
  - name: DIGITAL_ASSISTANT_API_URL
    value: "https://dva.brooke.ai/api"
  - name: SIP_TRANSFER_DOMAIN
    value: "transfer.brooke.ai:5060"
  - name: JAMBONZ_API_URL
    value: "http://jambonz.brooke.ai/api/v1"
  - name: JAMBONZ_ACCOUNT_SID
    value: "c8d2608d-6d62-48eb-9758-a076b707d909"
  - name: JAMBONZ_API_KEY
    valueFrom:
      secretKeyRef:
        name: rasa-secrets
        key: jambonzApiKey
  - name: OPENAI_API_KEY
    valueFrom:
      secretKeyRef:
        key: openaiApiKey
        name: rasa-secrets
  - name: DIGITAL_ASSISTANT_CLIENT_ID
    valueFrom:
      secretKeyRef:
        key: digitalAssistantClientId
        name: rasa-secrets
  - name: DIGITAL_ASSISTANT_CLIENT_SECRET
    valueFrom:
      secretKeyRef:
        key: digitalAssistantClientSecret
        name: rasa-secrets
  - name: DEEPGRAM_API_KEY
    valueFrom:
      secretKeyRef:
        key: deepgramApiKey
        name: rasa-secrets
  - name: E11_TTS_API_KEY
    valueFrom:
      secretKeyRef:
        key: elevenlabsApiKey
        name: rasa-secrets
  - name: ELEVENLABS_API_KEY
    valueFrom:
      secretKeyRef:
        key: elevenlabsApiKey
        name: rasa-secrets
  # BCP reporting (bcp_reporting/): read-only login to Studio's reporting_v1
  # views in the studio-mantle database. STUDIO_PROJECT_ID is the uuid in the
  # Studio project URL. See docs/29-bcp-reporting-dev-rollout.md.
  - name: STUDIO_DB_HOST
    value: rasa-analytics.ca5ecrqmcbhd.us-east-1.rds.amazonaws.com
  - name: STUDIO_DB_PORT
    value: "5432"
  - name: STUDIO_DB_NAME
    value: studio-mantle
  - name: STUDIO_DB_USER
    value: bcp_reporting
  - name: STUDIO_DB_PASSWORD
    valueFrom:
      secretKeyRef:
        key: studioDbPassword
        name: rasa-secrets
  - name: STUDIO_PROJECT_ID
    value: "01a1555b-6fb8-734b-bbf5-940795664bc3"
replicaCount: 3
autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 6
  targetCPUUtilizationPercentage: 80
  # Define the environment variables that Rasa needs to function and interact with the above services.
  # Note here that some of the values are plaintext environment variables and some are configured to be pulled from the Kubernetes Secret we created earlier.
# ingress:
#   enabled: true
#   className: "istio"
#   rules:
#   - host: mantle-assistant.rasa.brooke.ai
#     http:
#       paths:
#         - backend:
#             service:
#               name: rasa
#               port:
#                 number: 5005
#           path: /
#           pathType: Prefix
#   tls:
#   - hosts:
#     - mantle-assistant.rasa.brooke.ai
#     secretName: rasa-mantle-tls
ingress:
  enabled: true
  className: "istio"
  hosts:
    - host: mantle-assistant.rasa.brooke.ai
      paths:
        - path: /
          pathType: Prefix
  tls:
    - hosts:
        - mantle-assistant.rasa.brooke.ai
      secretName: rasa-mantle-tls
nodeSelector:
  workload: rasa-mantle
tolerations:
  - key: workload
    operator: Equal
    value: rasa-mantle
    effect: NoSchedule
```

### Snapshot: `k8s/prod/rasa-mantle-certificate.yaml`

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: rasa-assistant-mantle
  namespace: istio-system
spec:
  commonName: mantle-assistant.rasa.brooke.ai
  dnsNames:
    - mantle-assistant.rasa.brooke.ai
  duration: 2160h
  renewBefore: 360h
  issuerRef:
    kind: ClusterIssuer
    name: letsencrypt
  secretName: rasa-mantle-tls
  usages:
    - server auth
    - client auth
```

### Snapshot: `k8s/prod/studio-mantle-certificate.yaml`

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: studio-mantle
  namespace: istio-system
spec:
  secretName: studio-mantle-tls
  commonName: studio-mantle.rasa.brooke.ai
  dnsNames:
    - studio-mantle.rasa.brooke.ai
  issuerRef:
    kind: ClusterIssuer
    name: letsencrypt
  privateKey:
    rotationPolicy: Always
  usages:
    - server auth
```

### Snapshot: `k8s/prod/studio-values.yaml`

```yaml
## Before installing add a 32+ character secret in studio-secrets with name AUTH_SECRET

repository: docker.io/rasa
tag: "2.0.0.dev3"
global:
  ingressHost: studio-mantle.rasa.brooke.ai
  ingressClassName: istio
  ingressAnnotations:
    kubernetes.io/ingress.class: istio
rasa:
  enabled: false
config:
  connectionType: "https"
  database:
    host: rasa-analytics.ca5ecrqmcbhd.us-east-1.rds.amazonaws.com
    port: "5432"
    username: "studio-mantle"
    password:
      secretName: "studio-secrets"
      secretKey: "DATABASE_PASSWORD"
    databaseName: "studio-mantle"
    queryParams: "sslmode=require"
    preferSSL: "true"
  nodeSelector:
    workload: rasa-mantle
  tolerations:
    - key: workload
      operator: Equal
      value: rasa-mantle
      effect: NoSchedule
eventIngestion:
  mode: separate
  kafkaClientId: kafka-python-rasa-mantle
  env:
    - name: KAFKA_BROKER_ADDRESS
      value: kafka.rasa-mantle.svc.cluster.local:9092
    - name: KAFKA_SASL_MECHANISM
      value: plain
    - name: KAFKA_SASL_USERNAME
      value: kafka
    - name: KAFKA_SASL_PASSWORD
      valueFrom:
        secretKeyRef:
          name: studio-secrets
          key: KAFKA_SASL_PASSWORD
    - name: KAFKA_TOPIC
      value: rasa-mantle
    - name: KAFKA_GROUP_ID
      value: studio-mantle
    - name: KAFKA_DLQ_TOPIC
      value: rasa-mantle-events-dlq
app:
  initialAdmin:
    email: "admin@bettercarpeople.com"
    password:
      secretName: "studio-secrets"
      secretKey: "studio-admin-password"
  webClient:
    config:
      MS_API_URL: "https://studio-mantle.rasa.brooke.ai"
  env:
    - name: DELETE_CONVERSATIONS_CRON_EXPRESSION
      value: 30 3 * * *
    - name: DELETE_CONVERSATIONS_OLDER_THAN_HOURS
      value: "2160"
  ingress:
    enabled: true
    tls:
      - hosts:
          - studio-mantle.rasa.brooke.ai
        secretName: studio-mantle-tls
```

### Repository layout at the recorded stage

```text
.github/workflows/
  build-publish-rasa-mantle-image.yaml
  train-publish-rasa-mantle-model.yaml
  deploy-rasa-mantle-dev.yaml
  deploy-rasa-mantle-qa.yaml
  deploy-rasa-mantle-prod.yaml
k8s/
  dev/
    charts/
    dev-values.yaml
    studio-values.yaml
    kafka-values.yaml
    auto-ebs-sc-wffc.yaml
    rasa-mantle-certificate.yaml
    studio-mantle-certificate.yaml
    jaeger.yml
  qa/
    charts/
    qa-values.yaml
    studio-values.yaml
    kafka-values.yaml
    auto-ebs-sc-wffc.yaml
    rasa-mantle-certificate.yaml
    studio-mantle-certificate.yaml
  prod/
    charts/
      kafka-32.4.3.tgz
      rasa-3.0.0-rc.18.tgz
      studio-3.0.0-rc.54.tgz
    prod-values.yaml
    studio-values.yaml
    kafka-values.yaml
    auto-ebs-sc-wffc.yaml
    rasa-mantle-certificate.yaml
    studio-mantle-certificate.yaml
    kafka-lag-metrics.yaml
```

### Learning glossary

| Term | Meaning in this deployment |
|---|---|
| Helm chart | Versioned templates/defaults used to render Kubernetes objects |
| Helm release | Named installation scoped to a namespace |
| Values | Inputs to chart templates, not necessarily accepted at arbitrary paths |
| ConfigMap | Non-secret application configuration; manual edits can create ownership conflicts |
| Secret | Namespaced credential/config object; base64 encoding is not itself encryption |
| IRSA | Kubernetes service-account OIDC identity used to assume an IAM role |
| GitHub OIDC | Short-lived federated runner access, separate from pod IRSA |
| EKS access entry | Mapping an AWS principal into cluster access/authentication |
| HPA | Scales workload replicas using configured metrics |
| PDB | Constrains eligible voluntary disruptions; not a global outage shield |
| StatefulSet | Stable pod identity and claim templates for Kafka |
| PVC | Request/binding for persistent storage |
| StorageClass | Provisioning parameters and binding/expansion policy |
| Topic | Kafka event stream split into partitions |
| Consumer group | Cooperating consumers assigned topic partitions |
| DLQ | Failed-event destination requiring investigation, not ordinary successful ingestion |
| Readiness | Whether traffic should be sent to the pod |
| Liveness | Whether kubelet should restart a container |
| PreStop | Shutdown hook inside pod termination grace period |
| SHA tag | Commit-based artifact identifier; not itself a package version or immutable provenance proof |
| Webhook | HTTP callback, including method/path/auth requirements |
| WebSocket | Persistent bidirectional connection used here for audio |

### Evidence index and boundaries

- Conversation: DEV/QA setup, build/train/deploy outputs, IAM/trust results, SQL grants, PROD nodes, image/model copies, successful rollout/status and failed-call debugging.
- User file: `Pasted text(20261019-205429).txt`, saved staged PROD diff. Used for full Helm/collector/certificate snapshots.
- QA workflow: full source pasted by Rahul October20; PROD reconstruction applies the recorded environment replacements.
- DEV deploy: historical source pasted in thread; reformatted without temporary force-conflicts. Exact current DEV build/train caller wiring is not available here.
- No fresh AWS/Kubernetes/GitHub execution occurred while writing this workbook. Commands are explanatory examples and recorded recipes, not evidence of a new change.
- Later operational changes and unrelated conversations are not silently incorporated. Re-verify current runtime and repository before using any historical version pin, node name, policy, project ID, or chart.

### Updating this workbook after the next milestone

Record the Git PR/merge SHA, workflow run ID, image digest, model filename, Helm revision, test call SID/time, Studio conversation result, consumer lag/publish result, and who approved routing. Add precise results rather than replacing “pending” with “done” based only on pod readiness.
