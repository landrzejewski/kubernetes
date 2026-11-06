## Docker

- [Docker CLI Reference](https://docs.docker.com/reference/cli/docker) – Complete guide to Docker commands and usage.
- [Dockerfile Reference](https://docs.docker.com/reference/dockerfile) – Syntax and best practices for building images.

## Books

- [Docker in Practice (2nd Edition)](https://www.manning.com/books/docker-in-practice-second-edition) – Practical patterns and tips for Docker.
- [Docker in Action (2nd Edition)](https://www.manning.com/books/docker-in-action-second-edition) – Hands-on guide to Docker workflows.
- [Kubernetes in Action (2nd Edition)](https://www.manning.com/books/kubernetes-in-action-second-edition) – Comprehensive guide to Kubernetes deployments.
- [Istio in Action](https://www.manning.com/books/istio-in-action) – Covers Istio service mesh fundamentals.

### Additional Popular Kubernetes Books
- Kubernetes Up & Running – Brendan Burns, Joe Beda, Kelsey Hightower & Lachlan Evenson – Practical guide from Kubernetes pioneers.
- Getting Started with Kubernetes – Jonathan Baier & Jesse White – Beginner-friendly approach to core concepts and workflows.
- Kubernetes Patterns – Bilgin Ibryam & Roland Huß – Design patterns and best practices for cloud-native apps.
- Kubernetes Cookbook – Sébastien Goasguen & Michael Hausenblas – Recipes for solving common Kubernetes problems.
- Production Kubernetes – Josh Rosso, Rich Lander, Alex Brand, & John Harris – Operating Kubernetes clusters at scale.
- Managing Kubernetes – Brendan Burns & Craig Tracey – Insights on day-2 operations and advanced management.
- Kubernetes Security – Liz Rice & Michael Hausenblas – Deep dive into securing Kubernetes clusters.
- Cloud Native DevOps with Kubernetes – John Arundel & Justin Domingus – Implementing DevOps workflows with Kubernetes.

## Practice & Troubleshooting Tools

- [killer.sh](https://killer.sh) – Interactive Kubernetes certification practice exams.
- [k8s-issues.purutuladhar.com](https://k8s-issues.purutuladhar.com/) – Troubleshooting Kubernetes issues.

---

# Kubernetes Resources and Useful Links

## 1. Official Documentation & Learning Resources
- [Kubernetes Documentation](https://kubernetes.io/docs/home) – Main hub for concepts, setup guides, API reference, and tutorials.
- [Kubernetes Concepts Overview](https://kubernetes.io/docs/concepts/overview) – Introduction to Kubernetes features and design.
- [Learning Tutorials](https://kubernetes.io/docs/tutorials) – Hands-on and advanced tutorials.
- [Kubectl Quick Reference](https://kubernetes.io/docs/reference/kubectl/quick-reference) – Common command reference.

## 2. Cheat Sheets & Command References
- [Spacelift Kubectl Cheat Sheet](https://spacelift.io/blog/kubernetes-cheat-sheet) – Quick guide to core commands.
- [Mirantis Kubernetes Cheat Sheet](https://www.mirantis.com/blog/kubernetes-cheat-sheet) – Includes troubleshooting and Lens IDE tips.
- [Glukhov Kubernetes Cheatsheet](https://www.glukhov.org/post/2024/10/kubernetes-cheatsheet) – Covers installation and debugging commands.

## 3. Aggregated Resources & Community Collections
- [Awesome Kubernetes Resources](https://github.com/tomhuang12/awesome-k8s-resources) – Curated links for tutorials, Helm, CI/CD, and security.

## 4. Contributor & API Navigation Tools
- [Contributor Cheat Sheet](https://www.kubernetes.dev/docs/contributor-cheatsheet) – For contributing to the Kubernetes project.
- [API Navigation Guide](https://www.reddit.com/r/kubernetes/comments/1j3d3fc/basic_understanding_of_how_to_navigate_the_k8s) – Tips for exploring available APIs and resources.

## 5. Platform-Specific Documentation
- [Google Kubernetes Engine (GKE)](https://cloud.google.com/kubernetes-engine/docs) – Setup, security, and best practices for GKE.

## 6. Visualization & Security Research
- [KubeDiagrams](https://arxiv.org/abs/2505.22879) – Tool to convert manifests into architecture diagrams.
- [XI Commandments of Kubernetes Security](https://arxiv.org/abs/2006.15275) – Best practices for Kubernetes security.
- [Interactive Network Policy Editor](https://editor.networkpolicy.io/?id=YEpqGqaXrbFg1r7R) – Visual editor for Kubernetes network policies.

## 7. Package Management (module 13)
- [Helm Documentation](https://helm.sh/docs/) – Charts, templates, values, OCI registries and the `helm` CLI.
- [Chart Template Guide](https://helm.sh/docs/chart_template_guide/) – Go templates, built-in objects and helper functions.
- [Artifact Hub](https://artifacthub.io/) – Search engine for Helm charts and other cloud-native packages.
- [Kustomize Reference](https://kubectl.docs.kubernetes.io/references/kustomize/) – All `kustomization.yaml` fields (patches, replacements, components, generators).

## 8. Cluster Administration and Monitoring (module 14)
- [Upgrading kubeadm clusters](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/) – Official upgrade procedure.
- [Operating etcd clusters](https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/) – Backup, restore and security of etcd.
- [Certificate management with kubeadm](https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/) – Expiration checks and renewal.
- [Encrypting Secret Data at Rest](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/) – EncryptionConfiguration and key rotation.
- [kube-prometheus-stack chart](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) – Prometheus Operator, Prometheus, Alertmanager and Grafana.
- [PromQL basics](https://prometheus.io/docs/prometheus/latest/querying/basics/) – The Prometheus query language.
- [Grafana Loki](https://grafana.com/docs/loki/latest/) and [LogQL](https://grafana.com/docs/loki/latest/query/) – Log storage and queries.
- [Grafana Alloy](https://grafana.com/docs/alloy/latest/) – Telemetry collector (successor of Promtail and Grafana Agent).

## 9. API Extensions (module 15)
- [Custom Resources](https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/) and [CRD validation rules (CEL)](https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/#validation-rules).
- [Validating Admission Policy](https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/) and [Mutating Admission Policy](https://kubernetes.io/docs/reference/access-authn-authz/mutating-admission-policy/).
- [Kubebuilder Book](https://book.kubebuilder.io/) – Writing controllers and operators in Go.
- [Operator SDK](https://sdk.operatorframework.io/) – Framework for building operators (Go, Ansible, Helm).

## 10. GitOps (module 16)
- [OpenGitOps principles](https://opengitops.dev/) – The four GitOps principles.
- [Argo CD Documentation](https://argo-cd.readthedocs.io/en/stable/) – Applications, sync options, waves/hooks, ApplicationSets, RBAC.
- [Argo CD Image Updater](https://argocd-image-updater.readthedocs.io/) – Automatic image tag updates written back to Git.
- [Sealed Secrets](https://github.com/bitnami/sealed-secrets) – Encrypted Secrets that are safe to store in Git.
- [External Secrets Operator](https://external-secrets.io/) – Sync secrets from Vault and cloud secret managers.
- [Gitea Documentation](https://docs.gitea.com/) – The self-hosted Git server used in the labs.
