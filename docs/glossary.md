# Glossary

Every technical word used in this repository, in plain English. Sorted A to Z.

| Word | Meaning |
| --- | --- |
| active / standby (OpenBao) | Of the 3 OpenBao pods, one is active and answers all requests. The other two are standbys: they wait and take over if the active one stops. |
| age | A small encryption tool with one key pair: a public key to lock, a private key to unlock. SOPS uses it here. |
| Alertmanager | The program that receives alerts from Prometheus and would send them on (mail, chat). Here no receiver is configured, so alerts are only visible. |
| alert rule | A condition Prometheus checks again and again, for example "an OpenBao pod is sealed for 2 minutes". When it is true, the alert fires. |
| Barman Cloud plugin | An add-on for CloudNativePG. It runs inside each PostgreSQL pod and copies backups and WAL files to S3. |
| CA (certificate authority) | The one certificate that signs all other certificates. Whoever trusts the CA trusts everything it signed. Here: the demo CA `demo-root-ca`. |
| cert-manager | A Kubernetes tool that creates TLS certificates and renews them before they expire. |
| Certificate (cert-manager) | A Kubernetes object that says "I want a certificate for these names". cert-manager then creates it and stores it in a Secret. |
| CloudNativePG | A Kubernetes operator that runs PostgreSQL: it starts the 3 instances, picks the primary, does failover and backups. |
| ClusterIssuer | A cert-manager object that can sign certificates in every namespace. Here: `selfsigned-bootstrap` and `demo-ca`. |
| ClusterSecretStore | An ESO object that says where the secret store is and how to log in. Here: `openbao`. |
| Codespace | A virtual machine from GitHub with a code editor. The whole demo cluster runs inside one Codespace. |
| CRD (custom resource definition) | A new object type added to Kubernetes by a tool, for example `ExternalSecret` or `PodMonitor`. |
| default-deny | A NetworkPolicy that blocks every incoming connection to the pods of a namespace. Allow rules then open single ports. |
| ExternalSecret | An ESO object for the pull direction: "copy this value from OpenBao into this Kubernetes Secret". |
| failover | When the primary or active copy fails and another copy takes over by itself. |
| Flux | The GitOps tool. It runs inside the cluster, fetches this repository and applies it. |
| GitOps | A way of working: the wanted state of the cluster is written in Git, and a tool (here Flux) makes the cluster match it. Changes go through Git, not by hand. |
| Helm, HelmRelease | Helm installs a ready-made package (a chart) into Kubernetes. A HelmRelease is the Flux object that says which chart and version to install, with which settings. |
| Ingress | A Kubernetes object that says which outside address (here `openbao.demo.local`) goes to which Service. Traefik reads it. |
| instance manager | A small program that CloudNativePG runs inside each PostgreSQL pod. It starts PostgreSQL and answers status questions on port 8000. |
| kind | "Kubernetes in Docker": a tool that runs a whole Kubernetes cluster as Docker containers. Here: 1 control plane and 3 workers. |
| kube-state-metrics | A program that turns the state of Kubernetes objects (pod ready, node ready) into numbers for Prometheus. |
| kubelet | The Kubernetes agent on every node. It starts the pods and puts Secrets into them as files. |
| Kustomization (Flux) | A Flux object for one layer: which folder of the repo to apply, and which layers must be healthy first (`dependsOn`). |
| KV v2 | OpenBao's key-value secret storage, version 2: every write keeps the older versions. Mounted at `secret/`. |
| namespace | A named area inside the cluster that groups related objects, for example `openbao` or `databases`. |
| NetworkPolicy | A Kubernetes rule that says which pods may connect to which pods, on which port. |
| node | One machine in the cluster. Here each node is a Docker container made by kind. |
| operator (Kubernetes) | A program that runs inside the cluster and manages one kind of software for you, for example CloudNativePG for PostgreSQL. |
| PITR (point-in-time recovery) | Restoring a database to an exact moment in the past: start from a base backup, then replay the WAL up to that moment. |
| pod | The smallest unit Kubernetes runs: one or a few containers that belong together. |
| PodMonitor | A Prometheus Operator object that tells Prometheus which pods to measure, on which port. Used here for OpenBao, PostgreSQL and ESO. |
| policy (OpenBao) | A list of paths a token may read or write. Here: `eso-read`, `eso-write`, `demo-write` in `openbao/policies/`. |
| port-forward | `kubectl port-forward`: opens a local port on your machine that leads into one pod or Service, for as long as the command runs. |
| primary / replica (PostgreSQL) | The primary accepts writes. The replicas copy every change from it and can become primary. |
| Prometheus | The program that collects numbers (metrics) from the platform every 30 s and checks the alert rules. |
| PrometheusRule | A Prometheus Operator object that holds alert rules. |
| PushSecret | An ESO object for the push direction: "copy this Kubernetes Secret into OpenBao". |
| root token | OpenBao's all-powerful login, created at init. Used only to configure OpenBao; should be revoked afterwards. |
| S3 | A common way to store files over HTTP, first made by Amazon. Here SeaweedFS provides it inside the cluster. |
| scrape | One visit of Prometheus to a target to read its metrics. |
| seal / sealed | OpenBao's sealed state: its data is encrypted and it cannot read it. Every OpenBao pod starts sealed. |
| Secret (Kubernetes) | A Kubernetes object that holds a small piece of secret data, for example a password. Pods can read it as a file or an environment variable. |
| service account | The identity a pod has inside Kubernetes. ESO logs in to OpenBao as the service account `external-secrets/external-secrets`. |
| ServiceMonitor | Like a PodMonitor, but finds the pods through a Kubernetes Service. Not used here: PodMonitors need no extra Service. |
| Shamir share (key share) | One piece of the unseal key. OpenBao splits the key into 5 shares; any 3 together unseal it, fewer than 3 reveal nothing. |
| SOPS | A tool that encrypts only the values in a file, so the file can be stored in Git. Here every `*.sops.yaml` file. |
| StatefulSet | A Kubernetes object that runs pods with fixed names (`openbao-0`, `openbao-1`, `openbao-2`). |
| switchover | A planned change of the primary or active copy, started on purpose (unlike a failover). |
| target | One endpoint Prometheus scrapes, for example `https://<pod IP>:9101/v1/sys/metrics`. |
| TLS | The encryption behind HTTPS. A TLS certificate proves the name of a server. |
| TokenRequest | A Kubernetes API call that gives a short-lived token for a service account. ESO asks for a 10-minute token before it logs in. |
| TokenReview | A Kubernetes API call that answers "is this token real, and whose is it?". OpenBao uses it to check ESO's login. |
| Traefik | The HTTPS entry point of the cluster: it receives requests for `openbao.demo.local` and sends them to the active OpenBao pod. |
| unseal | Giving OpenBao 3 of the 5 key shares so it can decrypt its data and start answering. Done by `scripts/openbao-unseal.sh`. |
| WAL (write-ahead log) | PostgreSQL's running record of every change, written before the change itself. Archived continuously to S3 for PITR. |
| webhook (ESO) | A small ESO server that Kubernetes asks to check every new or changed ESO object before it is saved (port 10250). |
