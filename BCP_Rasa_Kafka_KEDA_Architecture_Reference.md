# BCP Rasa / Kafka / KEDA Architecture Reference

> **Purpose:** A practical reference for the BCP Rasa platform so we can quickly answer architecture, scaling, Kafka, and KEDA questions without reconstructing the design from memory.

---

## Table of contents

1. [High-level architecture](#1-high-level-architecture)
2. [What each component does](#2-what-each-component-does)
3. [Kafka brokers/controllers vs topic partitions](#3-kafka-brokerscontrollers-vs-topic-partitions)
4. [Kafka replication factor, leaders, followers, and ISR](#4-kafka-replication-factor-leaders-followers-and-isr)
5. [Current `rasa` topic layout](#5-current-rasa-topic-layout)
6. [How Rasa Pro Services consumes Kafka](#6-how-rasa-pro-services-consumes-kafka)
7. [Partitions vs consumers](#7-partitions-vs-consumers)
8. [Why 6 partitions can work with 3-6 consumers](#8-why-6-partitions-can-work-with-3-6-consumers)
9. [What KEDA scales](#9-what-keda-scales)
10. [What KEDA does not scale](#10-what-keda-does-not-scale)
11. [Current DEV scaling design](#11-current-dev-scaling-design)
12. [Future 3-to-6 Rasa Pro Services design](#12-future-3-to-6-rasa-pro-services-design)
13. [Main Rasa application HPA](#13-main-rasa-application-hpa)
14. [KEDA authentication and Kafka connection](#14-keda-authentication-and-kafka-connection)
15. [Git / Helm / CI/CD ownership](#15-git--helm--cicd-ownership)
16. [KEDA platform ownership](#16-keda-platform-ownership)
17. [DEV / QA / PROD rollout model](#17-dev--qa--prod-rollout-model)
18. [Useful validation commands](#18-useful-validation-commands)
19. [Troubleshooting guide](#19-troubleshooting-guide)
20. [Quick reference](#20-quick-reference)

---

## 1. High-level architecture

```text
                                  EKS
                                   |
                +------------------+------------------+
                |                                     |
                |                                     |
          MAIN RASA APP                         KAFKA CLUSTER
                |                                     |
     Deployment/rasa                            3 Kafka nodes
       min 4 / max 6                                  |
       CPU HPA 80%                                    |
                |                               Topic: rasa
                |                                     |
                |                       +-------------+-------------+
                |                       |             |             |
                |                      P0            P1            P2
                |                                     |
                |                              consumer-group lag
                |                                     |
                |                                    KEDA
                |                                     |
                |                                     v
                |                     Deployment/rasa-rasa-pro-services
                |                              currently 3 pods
                |                                  KEDA-owned HPA
                |
       NOT controlled by KEDA
```

The most important separation is:

- **Main Rasa application pods** are scaled by the existing CPU HPA.
- **Rasa Pro Services pods** consume the Kafka `rasa` topic and are the workload KEDA scales.
- **Kafka brokers/controllers** are not scaled by KEDA.
- **Kafka topic partitions** define the maximum useful parallelism for a consumer group.

---

## 2. What each component does

| Component | Role |
|---|---|
| `Deployment/rasa` | Main Rasa application workload |
| `Deployment/rasa-rasa-pro-services` | Rasa Pro Services / Kafka analytics consumers |
| `kafka-controller-0/1/2` | Kafka processes that host topic data and participate in broker/controller duties |
| Topic `rasa` | Kafka stream consumed by Rasa Pro Services |
| `rasa-analytics-group` | Kafka consumer group used by Rasa Pro Services |
| KEDA | Reads Kafka lag and drives an HPA for Rasa Pro Services |
| Kubernetes HPA | Performs the actual replica-count scaling |
| Cluster Autoscaler | Adds/removes EKS nodes when pods cannot/can be scheduled |

---

## 3. Kafka brokers/controllers vs topic partitions

These are different concepts.

### Kafka nodes

Current Kafka pods:

```text
kafka-controller-0
kafka-controller-1
kafka-controller-2
```

Think of these as **Kafka servers**.

### Kafka topic partitions

Current `rasa` topic:

```text
Partition 0
Partition 1
Partition 2
```

Think of partitions as **logical work lanes / shards** inside the topic.

You do **not** need one Kafka node per partition.

For example, this is valid:

```text
3 Kafka nodes
6 topic partitions
Replication Factor = 3
```

The three Kafka nodes can host copies of all six partitions.

---

## 4. Kafka replication factor, leaders, followers, and ISR

Current configuration:

```text
Topic: rasa
PartitionCount: 3
ReplicationFactor: 3
```

`ReplicationFactor: 3` means **each logical partition has three copies** stored across Kafka nodes.

Example:

```text
Partition 0
Leader: 2
Replicas: 2,0,1
```

means:

```text
kafka-controller-2 -> Partition 0 leader
kafka-controller-0 -> Partition 0 follower
kafka-controller-1 -> Partition 0 follower
```

### Leader

The leader is the active partition copy.

Conceptually:

```text
Producer / Consumer
        |
        v
   P0 LEADER
```

### Followers

Followers replicate the leader's data:

```text
                  +--> P0 follower on broker 0
P0 leader --------|
                  +--> P0 follower on broker 1
```

If the leader broker fails, an in-sync follower can become the new leader.

### ISR

**ISR = In-Sync Replicas**

Healthy output should show all expected replicas in ISR.

Example:

```text
Replicas: 2,0,1
ISR:      2,1,0
```

Order does not matter. What matters is that all expected broker IDs are present.

### Critical distinction

```text
Replication Factor -> durability / availability
Partition Count    -> parallelism
```

Three partitions with RF=3 is still only **three consumer work lanes**, not nine.

---

## 5. Current `rasa` topic layout

Observed DEV layout:

```text
Topic: rasa
Partitions: 3
Replication Factor: 3

Partition 0 -> Leader 2 -> Replicas 2,0,1
Partition 1 -> Leader 0 -> Replicas 0,1,2
Partition 2 -> Leader 1 -> Replicas 1,2,0
```

Visual view:

```text
                    KAFKA CLUSTER

kafka-controller-0
+-----------------------------+
| P0 follower                 |
| P1 LEADER                   |
| P2 follower                 |
+-----------------------------+

kafka-controller-1
+-----------------------------+
| P0 follower                 |
| P1 follower                 |
| P2 LEADER                   |
+-----------------------------+

kafka-controller-2
+-----------------------------+
| P0 LEADER                   |
| P1 follower                 |
| P2 follower                 |
+-----------------------------+
```

The partition leaders are nicely distributed:

```text
Broker 0 -> leader for P1
Broker 1 -> leader for P2
Broker 2 -> leader for P0
```

---

## 6. How Rasa Pro Services consumes Kafka

Current Kafka consumer group:

```text
rasa-analytics-group
```

Current topic:

```text
rasa
```

Current Rasa Pro Services deployment:

```text
Deployment/rasa-rasa-pro-services
```

Observed current state:

```text
3 Kafka partitions
3 Rasa Pro Services pods
```

Kafka assigns partitions to consumers in the same consumer group.

Conceptually:

```text
P0 -> Rasa Pro consumer A
P1 -> Rasa Pro consumer B
P2 -> Rasa Pro consumer C
```

This is **not**:

```text
kafka-controller-0 -> Rasa Pro pod 1
kafka-controller-1 -> Rasa Pro pod 2
kafka-controller-2 -> Rasa Pro pod 3
```

Consumer assignment happens at the **partition** level, not the Kafka-node level.

---

## 7. Partitions vs consumers

The number of partitions does **not** have to equal the number of consumers at all times.

Kafka's practical rule is:

> Within one consumer group, one partition can be actively consumed by at most one consumer at a time.

A consumer can own multiple partitions.

Example with six partitions:

| Consumers | Typical assignment |
|---:|---|
| 1 | 6 |
| 2 | 3 + 3 |
| 3 | 2 + 2 + 2 |
| 4 | 2 + 2 + 1 + 1 |
| 5 | 2 + 1 + 1 + 1 + 1 |
| 6 | 1 + 1 + 1 + 1 + 1 + 1 |
| 7 | 6 active + 1 idle |

Therefore:

> **Maximum useful consumer count should not exceed the partition count.**

It is perfectly valid to have fewer consumers than partitions.

---

## 8. Why 6 partitions can work with 3-6 consumers

A future design can use:

```text
Kafka topic partitions: 6
Rasa Pro Services min:  3
Rasa Pro Services max:  6
```

### Normal load: 3 consumers

```text
P0 + P1 -> Rasa Pro 1
P2 + P3 -> Rasa Pro 2
P4 + P5 -> Rasa Pro 3
```

Each consumer handles approximately two partitions.

### Load increases: KEDA scales to 4

Kafka rebalances:

```text
Rasa Pro 1 -> P0,P1
Rasa Pro 2 -> P2,P3
Rasa Pro 3 -> P4
Rasa Pro 4 -> P5
```

### Load increases further: 5 consumers

Example:

```text
Rasa Pro 1 -> P0,P1
Rasa Pro 2 -> P2
Rasa Pro 3 -> P3
Rasa Pro 4 -> P4
Rasa Pro 5 -> P5
```

### Peak: 6 consumers

```text
P0 -> Rasa Pro 1
P1 -> Rasa Pro 2
P2 -> Rasa Pro 3
P3 -> Rasa Pro 4
P4 -> Rasa Pro 5
P5 -> Rasa Pro 6
```

This is the maximum partition-level parallelism for a six-partition topic.

### Important

You do **not** need six Kafka brokers for six partitions.

A valid design is:

```text
3 Kafka brokers
6 topic partitions
RF = 3
3-6 Rasa Pro Services consumers
```

---

## 9. What KEDA scales

In this architecture, KEDA scales only:

```text
Deployment/rasa-rasa-pro-services
```

The ScaledObject target is conceptually:

```yaml
scaleTargetRef:
  name: rasa-rasa-pro-services
```

KEDA watches:

```text
Topic:          rasa
Consumer group: rasa-analytics-group
Metric:         consumer-group lag
```

Flow:

```text
Kafka lag increases
       |
       v
      KEDA
       |
       v
KEDA-generated HPA
       |
       v
rasa-rasa-pro-services replicas increase
```

---

## 10. What KEDA does not scale

KEDA does **not** scale the main Rasa application:

```text
Deployment/rasa
```

KEDA also does **not** scale Kafka brokers/controllers:

```text
kafka-controller-0
kafka-controller-1
kafka-controller-2
```

And KEDA does not directly scale EKS nodes.

Those responsibilities remain separate:

```text
Main Rasa pods         -> CPU HPA
Rasa Pro Services      -> KEDA / Kafka lag
Kafka brokers          -> separate Kafka capacity design
EKS nodes              -> Cluster Autoscaler
```

---

## 11. Current DEV scaling design

Current proven DEV configuration:

```text
KEDA version:             2.20.2
Topic:                    rasa
Partitions:               3
Replication Factor:       3
Consumer group:           rasa-analytics-group
Rasa Pro Services pods:   3
KEDA minReplicaCount:     3
KEDA maxReplicaCount:     3
KEDA lagThreshold:        10
allowIdleConsumers:       false
```

This is intentionally a **validation-only 3 -> 3 configuration**.

It proves:

- KEDA is installed.
- KEDA can authenticate to Kafka.
- KEDA can read consumer-group lag.
- Kubernetes external metrics are working.
- KEDA can generate/manage the HPA.
- KEDA does not unexpectedly change Rasa Pro Services capacity.

Observed healthy metric:

```text
0/10 (avg)
```

This means:

```text
Current Kafka lag = 0
Target lag        = 10
```

It does **not** mean KEDA is broken.

---

## 12. Future 3-to-6 Rasa Pro Services design

If the desired maximum Rasa Pro Services parallelism is six, the recommended sequence is:

```text
Current:
3 partitions
3 consumers
KEDA min=3 max=3

        |
        v

Increase topic partition count deliberately

        |
        v

Future:
6 partitions
KEDA min=3
KEDA max=6
```

The intended behavior becomes:

```text
Normal load  -> 3 consumers
Medium load  -> 4-5 consumers
High load    -> 6 consumers
```

### Guardrail

The Helm chart intentionally prevents:

```text
maxReplicas > kafkaPartitionCount
```

unless that mismatch is explicitly acknowledged.

That protects against accidentally running consumers that cannot get partition assignments.

---

## 13. Main Rasa application HPA

The main Rasa workload is separate.

Observed configuration:

```text
Deployment: rasa
minReplicas: 4
maxReplicas: 6
metric: CPU
target: 80%
```

Conceptually:

```text
Application CPU rises
       |
       v
Existing Kubernetes HPA
       |
       v
Deployment/rasa
4 -> 5 -> 6
```

Kafka lag does **not** drive this HPA.

So the platform has two different autoscaling signals:

```text
CPU
 |
 v
Main Rasa application

Kafka lag
 |
 v
Rasa Pro Services
```

---

## 14. KEDA authentication and Kafka connection

Observed DEV Kafka settings:

```text
bootstrapServers:
  kafka-controller-headless.rasa.svc.cluster.local:9092

topic:
  rasa

consumerGroup:
  rasa-analytics-group

Kafka SASL mechanism:
  PLAIN

Kafka security protocol:
  SASL_PLAINTEXT
```

KEDA representation:

```yaml
sasl: plaintext
tls: disable
```

### TriggerAuthentication

The KEDA TriggerAuthentication does not store the actual password in Git.

It references:

```text
Username:
KAFKA_SASL_USERNAME from the rasa-pro-services container environment

Password:
Kubernetes Secret rasa-secrets
key kafkaSslPassword
```

Conceptually:

```text
Rasa workload env / Secret
           |
           v
TriggerAuthentication
           |
           v
KEDA Kafka scaler
```

Do not commit Kafka passwords into Git.

---

## 15. Git / Helm / CI/CD ownership

The long-term source of truth is Git.

Common chart:

```text
k8s/charts/rasa-scaling/
```

Environment values:

```text
k8s/dev/rasa-scaling-values.yaml
k8s/qa/rasa-scaling-values.yaml
k8s/prod/rasa-scaling-values.yaml
```

Shared deployment implementation:

```text
k8s/scripts/deploy-rasa-scaling.sh
```

Existing Scaling CI/CD workflow:

```text
.github/workflows/rasa-scaling-validate.yaml
```

### Why this structure

We intentionally avoid creating separate implementations such as:

```text
deploy-keda-dev.sh
deploy-keda-qa.sh
deploy-keda-prod.sh
```

The same chart and shared script should be reused across environments.

Only environment inputs differ:

```text
AWS credentials
EKS cluster
environment values
```

---

## 16. KEDA platform ownership

The KEDA operator is treated as **cluster infrastructure**, not as an application resource.

Cluster-level KEDA resources include:

```text
KEDA operator
KEDA metrics API server
KEDA admission webhook
KEDA CRDs
```

The Rasa Scaling CI/CD pipeline does **not** install or upgrade the KEDA operator.

It manages only application-level KEDA resources in the `rasa` namespace:

```text
ScaledObject
TriggerAuthentication
KEDA-generated HPA
```

### Why this separation exists

The application CI identity can manage resources in the `rasa` namespace, but it should not require broader permissions in the `keda` namespace.

The original failed deployment demonstrated this boundary:

```text
dev_ci_cd -> rasa namespace secrets                  yes
dev_ci_cd -> rasa ScaledObjects                      yes
dev_ci_cd -> rasa TriggerAuthentications             yes
dev_ci_cd -> keda namespace secrets                  no
```

This is expected and desirable.

The failure was **not** caused by GitHub Actions `${{ secrets.* }}`.

It occurred because Helm tried to read Kubernetes Helm-release Secrets in the `keda` namespace.

---

## 17. DEV / QA / PROD rollout model

The goal is to use the **same code** in all environments.

```text
                   Common Helm chart
                          |
                   Common deploy script
                          |
             +------------+------------+
             |            |            |
            DEV           QA          PROD
             |            |            |
         env values    env values    env values
```

### Current rollout state

```text
DEV:
KEDA application scaling enabled for validation

QA:
KEDA application scaling remains disabled

PROD:
KEDA application scaling remains disabled
```

Promotion sequence:

```text
DEV validation
     |
     v
Controlled DEV scaling test
     |
     v
Enable same configuration in QA
     |
     v
QA validation
     |
     v
Controlled PROD rollout
```

QA and PROD should not require a new KEDA implementation.

---

## 18. Useful validation commands

### Check KEDA installation

```bash
helm list -n keda

kubectl get pods -n keda

kubectl get crd | grep keda

kubectl get apiservice v1beta1.external.metrics.k8s.io
```

### Check application KEDA objects

```bash
kubectl get scaledobject -n rasa

kubectl get triggerauthentication -n rasa

kubectl describe scaledobject rasa-pro-kafka-lag -n rasa
```

### Check KEDA HPA

```bash
kubectl get hpa -n rasa

kubectl describe hpa keda-hpa-rasa-pro-kafka-lag -n rasa
```

Healthy example:

```text
ScalingActive = True
Reason        = ValidMetricFound
Metric        = 0/10
```

### Check Rasa Pro Services

```bash
kubectl get deploy rasa-rasa-pro-services -n rasa

kubectl get pods -n rasa | grep rasa-rasa-pro-services
```

### Check Kafka topic

Using an authenticated Kafka client:

```bash
kafka-topics.sh \
  --bootstrap-server kafka-controller-headless.rasa.svc.cluster.local:9092 \
  --command-config /tmp/client.properties \
  --describe \
  --topic rasa
```

### Check consumer lag

```bash
kafka-consumer-groups.sh \
  --bootstrap-server kafka-controller-headless.rasa.svc.cluster.local:9092 \
  --command-config /tmp/client.properties \
  --describe \
  --group rasa-analytics-group
```

### Check under-replicated partitions

```bash
kafka-topics.sh \
  --bootstrap-server kafka-controller-headless.rasa.svc.cluster.local:9092 \
  --command-config /tmp/client.properties \
  --describe \
  --under-replicated-partitions
```

No output is the healthy case.

### Check CI identity permissions

```bash
kubectl auth can-i create scaledobjects.keda.sh \
  -n rasa \
  --as=dev_ci_cd

kubectl auth can-i create triggerauthentications.keda.sh \
  -n rasa \
  --as=dev_ci_cd

kubectl auth can-i list secrets \
  -n rasa \
  --as=dev_ci_cd
```

---

## 19. Troubleshooting guide

### KEDA ScaledObject says `Ready=True`, `Active=False`

This can be completely healthy.

If lag is zero:

```text
Ready  = True
Active = False
```

means KEDA is configured correctly but there is currently no active scaling pressure.

Check:

```bash
kubectl get hpa keda-hpa-rasa-pro-kafka-lag -n rasa
```

If the metric is:

```text
0/10
```

and `ScalingActive=True / ValidMetricFound`, the metric path is healthy.

---

### HPA metric shows `<unknown>`

Investigate:

```text
Kafka connectivity
SASL authentication
consumer group name
topic name
KEDA operator logs
external.metrics API
```

Commands:

```bash
kubectl describe scaledobject rasa-pro-kafka-lag -n rasa

kubectl describe hpa keda-hpa-rasa-pro-kafka-lag -n rasa

kubectl logs -n keda deploy/keda-operator --since=10m
```

---

### More consumers than partitions

Example:

```text
3 partitions
6 consumers
```

Only three consumers can actively own partitions.

The remaining consumers will not add useful Kafka parallelism.

Recommended rule:

```text
max useful consumers <= partition count
```

---

### More partitions than consumers

This is normal.

Example:

```text
6 partitions
3 consumers
```

Kafka assigns approximately two partitions per consumer.

This is a good design when KEDA needs headroom to scale from 3 to 6.

---

### Consumer imbalance

With six partitions and four consumers, an assignment such as:

```text
2 + 2 + 1 + 1
```

is normal because six cannot divide evenly by four.

A more important question is whether **message traffic is evenly distributed across partitions**.

Even with one consumer per partition, a hot partition can create workload imbalance.

---

### `secrets is forbidden` in the `keda` namespace

This refers to **Kubernetes Secret resources**, not GitHub `${{ secrets.* }}`.

The application CI pipeline should not manage the KEDA Helm release.

KEDA operator lifecycle belongs to the cluster/platform ownership layer.

---

## 20. Quick reference

### Current DEV

```text
EKS namespace:
rasa

Kafka nodes:
3

Kafka topic:
rasa

Topic partitions:
3

Replication Factor:
3

Consumer group:
rasa-analytics-group

Rasa Pro Services:
3 replicas

KEDA:
installed and validated

KEDA min:
3

KEDA max:
3

lagThreshold:
10

Main Rasa application:
4-6 replicas via CPU HPA

KEDA controls main Rasa:
NO

KEDA controls Rasa Pro Services:
YES

KEDA controls Kafka brokers:
NO

KEDA controls EKS nodes:
NO
```

### Future candidate design

```text
Kafka nodes:
3

rasa topic partitions:
6

Replication Factor:
3

Rasa Pro Services:
min 3 / max 6

Normal load:
3 consumers, approximately 2 partitions each

Peak load:
6 consumers, 1 partition each
```

---

## Mental model

If there is only one section to remember, use this:

```text
Kafka brokers/controllers
= WHERE Kafka data is hosted

Kafka topic partitions
= HOW the topic is divided into parallel work lanes

Replication Factor
= HOW MANY copies of each partition exist for durability

Partition leader
= active copy of a partition

Partition followers
= redundant synchronized copies

Rasa Pro Services
= WHO consumes the rasa topic partitions

Consumer group
= coordinates partition ownership across Rasa Pro Services pods

Kafka lag
= HOW FAR the consumer group is behind

KEDA
= decides HOW MANY Rasa Pro Services consumers should run

Main Rasa HPA
= separate CPU-based autoscaling for Deployment/rasa

Cluster Autoscaler
= ensures enough EKS node capacity exists for scheduled pods
```

---

## Design rules

1. **Do not use Kafka consumer lag to scale the main Rasa application.**
2. **Use Kafka lag to scale Rasa Pro Services because it consumes `rasa-analytics-group`.**
3. **Do not scale useful consumers above the topic partition count.**
4. **Fewer consumers than partitions is normal and supported.**
5. **Replication Factor does not increase consumer parallelism.**
6. **Kafka broker count does not need to equal partition count.**
7. **Keep one common scaling Helm chart for DEV/QA/PROD.**
8. **Keep one shared deployment implementation instead of copying environment logic.**
9. **Keep the KEDA operator lifecycle separate from application-level KEDA resources.**
10. **Never store Kafka passwords directly in Git.**
