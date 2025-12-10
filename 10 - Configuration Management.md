
## Understanding Configuration Management Philosophy

### The Foundation of Cloud-Native Configuration

Configuration management represents one of the most critical aspects of running applications in Kubernetes. When we deploy containerized applications, we face a fundamental challenge: how do we handle environment-specific settings, credentials, and operational parameters without rebuilding container images for each change or environment? Kubernetes solves this through a sophisticated configuration management system that externalizes configuration from application code.

The core principle driving Kubernetes configuration management is the separation of concerns. This means keeping configuration data separate from container images, allowing the same image to run across development, staging, and production environments with different configurations. This separation provides multiple benefits: it enhances security by keeping sensitive data out of version-controlled code, simplifies deployment processes, and enables configuration changes without rebuilding or redeploying applications.

Consider a typical application that needs database connection strings, API keys, feature flags, and environment-specific settings. Without proper configuration management, these values would be hardcoded into the application or built into the container image, creating rigid, environment-specific images that are difficult to maintain and pose security risks.

### Configuration Best Practices

Successful Kubernetes deployments rely on well-established configuration practices that have emerged from years of production experience:

Version Control Integration: Every configuration file should exist in a version control system before being applied to the cluster. This creates an immutable record of what was deployed and when, enabling rapid rollback capabilities and supporting audit requirements. This practice forms the foundation of GitOps methodologies, where Git repositories become the single source of truth for both application code and configuration.

Principle of Minimalism: Configuration files should contain only the essential parameters required for the specific use case. Kubernetes provides sensible defaults for most settings, and explicitly setting values that match defaults adds unnecessary complexity and potential for errors. Each configuration parameter should exist for a clear reason, documented either through comments or external documentation.

YAML as the Standard Format: While Kubernetes supports JSON for configuration, the community has standardized on YAML for its superior readability and support for comments. YAML's structure makes it easier to understand complex configurations at a glance, and the ability to add comments directly in configuration files aids in documentation and maintenance.

Immutable Configuration Strategy: Marking ConfigMaps and Secrets as immutable prevents accidental or unauthorized modifications after creation. This approach treats configuration as versioned artifacts rather than mutable state, improving both security and performance. When changes are needed, new immutable resources are created rather than modifying existing ones.

### Benefits of External Configuration

The externalization of configuration provides substantial operational advantages:

Environment Portability: A single container image can run unchanged across all environments, from developer laptops to production clusters. The only difference lies in the configuration provided at runtime.

Enhanced Security: Sensitive data such as passwords, API keys, and certificates remain separate from application code and container images. This prevents accidental exposure through version control systems or container registries.

Operational Flexibility: Operations teams can modify configuration without involving development teams or rebuilding applications. This separation of responsibilities accelerates deployment cycles and reduces dependencies between teams.

Independent Version Control: Configuration changes can be tracked, reviewed, and rolled back independently of application code changes. This granular control improves troubleshooting and change management.

Runtime Updates: Applications designed to reload configuration can pick up changes without restarting, enabling zero-downtime configuration updates for supported parameters.

Comprehensive Audit Trail: Every configuration change leaves a record in the Kubernetes API server's audit log, providing complete visibility into who changed what and when.

## ConfigMaps - Managing Non-Sensitive Configuration

ConfigMaps serve as Kubernetes' primary mechanism for storing non-confidential configuration data. Think of them as dictionaries or hash maps that store configuration information in key-value pairs. The values can range from simple strings to complete configuration files, making ConfigMaps versatile enough to handle various configuration scenarios.

### ConfigMap Structure and Capabilities

A ConfigMap consists of two main data storage fields that serve different purposes:

The data field stores UTF-8 encoded text strings. This field handles the majority of configuration use cases, from simple key-value pairs like `database_port: "5432"` to complete configuration files such as `nginx.conf` or `application.yaml`. The UTF-8 encoding requirement means this field is perfect for human-readable configuration but cannot store binary data directly.

The binaryData field stores base64-encoded binary content. This field handles non-text configuration data such as images, certificates in binary format, or compiled configuration files. The base64 encoding increases the data size by approximately 33%, but allows binary content to be stored safely in the Kubernetes API.

Each ConfigMap can store up to 1 MiB of data total across both fields. This limit prevents excessive memory consumption in the API server and etcd while being sufficient for most configuration needs. If you need more configuration data, you can split it across multiple ConfigMaps.

### Configuration Consumption Patterns

Applications can consume ConfigMaps through several mechanisms, each suited to different architectural patterns and application requirements:

Environment Variables provide the most straightforward integration method. Configuration values are injected into the container's environment at startup, making them immediately available to the application. This pattern works particularly well for twelve-factor applications that expect configuration through environment variables. However, environment variables set from ConfigMaps remain static throughout the pod's lifecycle, requiring pod recreation to pick up configuration changes.

Volume Mounts create files within the container's filesystem, with each key in the ConfigMap becoming a file. This method proves invaluable for applications expecting configuration files at specific paths, such as web servers looking for configuration in `/etc/nginx/` or applications reading from `/etc/config/`. Volume-mounted ConfigMaps support automatic updates when the ConfigMap changes, though the update propagation time depends on the kubelet's sync period.

Projected Volumes allow combining multiple ConfigMaps, Secrets, and other data sources into a single directory structure. This advanced pattern simplifies configuration management for complex applications that need configuration from multiple sources.

### Dynamic Configuration Updates

One of ConfigMaps' most powerful features is their ability to update configuration dynamically. When a ConfigMap is mounted as a volume, changes to the ConfigMap eventually propagate to all pods using it. The update mechanism works through the kubelet's cache synchronization:

The kubelet maintains a local cache of ConfigMaps used by pods on its node. By default, this cache synchronizes with the API server every minute, though this period is configurable. When a ConfigMap updates, the kubelet detects the change during its next sync and updates the mounted files in the pod. The entire update process typically completes within two minutes but can vary based on cluster configuration.

Applications must be designed to detect and reload configuration file changes to benefit from dynamic updates. Many modern applications support configuration reloading through file watchers or periodic re-reading of configuration files. Applications that cannot reload configuration still require pod restarts to pick up changes.

## Secrets - Protecting Sensitive Information

Secrets provide Kubernetes' mechanism for managing sensitive data that requires additional protection beyond what ConfigMaps offer. While structurally similar to ConfigMaps, Secrets incorporate security features designed to minimize the risk of accidental exposure of sensitive information such as passwords, OAuth tokens, SSH keys, and TLS certificates.

### Secret Types and Use Cases

Kubernetes provides several built-in Secret types, each tailored for specific security scenarios and enforcing particular data structures:

Opaque Secrets serve as the general-purpose Secret type, offering maximum flexibility for storing arbitrary sensitive data. When you create a Secret without specifying a type, Kubernetes creates an Opaque Secret. These Secrets place no constraints on the data structure, making them suitable for any sensitive information that doesn't fit other specialized types.

ServiceAccount Token Secrets historically provided long-lived authentication credentials for ServiceAccounts. However, Kubernetes now recommends using the TokenRequest API for generating short-lived tokens instead. These legacy Secrets remain for backward compatibility but should be avoided in new deployments.

Docker Registry Secrets streamline authentication with private container registries. These Secrets automatically format credentials in the JSON structure required by Docker and other OCI-compliant registries. The kubelet uses these credentials when pulling images from private registries.

TLS Secrets enforce the presence of `tls.crt` and `tls.key` data keys, ensuring proper structure for TLS configurations. This type validation prevents common configuration errors when setting up HTTPS endpoints or mutual TLS authentication.

Basic Authentication Secrets require `username` and `password` fields, providing a standardized format for HTTP basic authentication credentials.

SSH Authentication Secrets require an `ssh-privatekey` field, standardizing SSH key storage for applications needing SSH access to remote systems.

### Security Model and Limitations

Understanding Secrets' security model is crucial for properly protecting sensitive data:

Storage Encryption: By default, Secrets are stored unencrypted in etcd, making encryption at rest configuration critical for production clusters. Kubernetes supports various encryption providers, from simple AES-CBC encryption to integration with external key management services. Without encryption at rest, anyone with direct access to etcd could read Secret values.

Access Control: Role-Based Access Control (RBAC) provides the primary security mechanism for Secrets. Since anyone with API access to read Secrets can retrieve their plaintext values, implementing fine-grained RBAC policies becomes paramount. The principle of least privilege should guide all Secret access policies, granting read access only to ServiceAccounts and users that absolutely require it.

Node-Level Security: Kubernetes implements several node-level protections for Secrets. Secrets are only sent to nodes running pods that reference them, reducing the attack surface. The kubelet stores Secret data in tmpfs (RAM-backed filesystem) rather than on disk, ensuring Secret data isn't persisted to node storage. When pods using a Secret are deleted, the kubelet removes its local copy of the Secret data.

Network Transmission: All communication between Kubernetes components uses TLS encryption, protecting Secrets during transmission between the API server and nodes. However, Secrets are transmitted in plaintext (base64 decoded) to the pods that use them.

### Consumption Patterns

Secrets can be consumed using the same patterns as ConfigMaps, but with additional security considerations:

Volume Mounts represent the most secure consumption method for Secrets. Secret data appears as files in the container's filesystem, with the kubelet ensuring these files are backed by tmpfs and never written to persistent storage. The files receive restrictive permissions by default (0644), though these can be further restricted using the `defaultMode` field.

Environment Variables work identically to ConfigMaps but require careful consideration. Environment variables may be logged by applications, exposed through process listings, or included in error reports. Use environment variables for Secrets only when the application requires it and you've evaluated the exposure risks.

ImagePullSecrets provide a specialized mechanism for container image authentication. Pods reference these Secrets in their `imagePullSecrets` field, and the kubelet automatically uses them when pulling images from private registries. This mechanism keeps registry credentials separate from application configuration.

### Core Security Practices

Encryption at Rest should be considered mandatory for production clusters. Configure the API server to encrypt Secret data before storing it in etcd. Kubernetes supports multiple encryption providers, from simple secretbox encryption to integration with cloud provider key management services. Regular key rotation further enhances security.

Role-Based Access Control (RBAC) provides fine-grained control over who can read, create, and modify ConfigMaps and Secrets. Implement the principle of least privilege by granting minimum necessary permissions. Avoid using wildcard permissions for Secrets, and regularly audit access policies to ensure they remain appropriate.

Network Policies add an additional security layer by controlling pod-to-pod communication at the network level. Even if an attacker gains access to one pod, network policies can prevent lateral movement to pods containing sensitive configuration.

ServiceAccount Management requires careful attention since ServiceAccounts can access Secrets. Avoid using the default ServiceAccount for workloads, create dedicated ServiceAccounts with minimal permissions, and disable ServiceAccount token auto-mounting when not needed.

Credential Rotation should be implemented as a regular practice. Establish processes for rotating passwords, API keys, and certificates regularly. Automation through operators or external secret management systems reduces the operational burden of rotation.

### External Secret Management Integration

For enhanced security, many organizations integrate Kubernetes with external secret management systems:

External secret managers provide advanced features like automatic rotation, detailed audit logging, and fine-grained access control. Popular solutions include HashiCorp Vault, AWS Secrets Manager, Azure Key Vault, and Google Secret Manager.

The Secrets Store CSI Driver enables mounting secrets from external systems as volumes, providing a standardized integration method. This approach keeps sensitive data in specialized systems while maintaining familiar Kubernetes consumption patterns.

External secret operators synchronize secrets from external systems to Kubernetes Secrets, providing a bridge between external secret management and native Kubernetes workflows. These operators handle authentication, synchronization, and rotation automatically.

## Workshop: Comprehensive ConfigMaps and Secrets Practice

This hands-on workshop demonstrates practical configuration management patterns you'll use in production Kubernetes deployments. 

### Working with ConfigMaps

#### Creating ConfigMaps from Literals

Let's start by creating ConfigMaps using literal values, the simplest method for small amounts of configuration:

```bash
# Create a ConfigMap with multiple configuration values
kubectl create configmap app-config \
  --from-literal=database_host=postgres.example.com \
  --from-literal=database_port=5432 \
  --from-literal=log_level=info \
  --from-literal=feature_flag=enabled

# Verify the ConfigMap was created
kubectl get configmap app-config

# Examine the ConfigMap details
kubectl describe configmap app-config

# View the complete ConfigMap in YAML format
kubectl get configmap app-config -o yaml
```

The output shows how Kubernetes stores the configuration data:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  database_host: postgres.example.com
  database_port: "5432"
  log_level: info
  feature_flag: enabled
```

Notice that all values are stored as strings, even numeric values like the port number.

#### Creating ConfigMaps from Files

Real applications often require complete configuration files. Let's create ConfigMaps from files:

```bash
# Create a properties file for a Java application
cat > application.properties << EOF
server.port=8080
spring.profiles.active=production
database.pool.size=10
cache.enabled=true
connection.timeout=30000
max.threads=200
EOF

# Create a database configuration file
cat > database.conf << EOF
host=postgresql.local
port=5432
database=myapp
max_connections=100
ssl_mode=require
connection_pool_size=20
statement_timeout=30000
EOF

# Create a ConfigMap from a single file
kubectl create configmap app-properties \
  --from-file=application.properties

# Create a ConfigMap from multiple files
kubectl create configmap app-configs \
  --from-file=application.properties \
  --from-file=database.conf

# Create a directory with configuration files
mkdir -p config-files
cp application.properties config-files/
cp database.conf config-files/
echo "worker_processes=4" > config-files/nginx.conf

# Create a ConfigMap from an entire directory
kubectl create configmap dir-config \
  --from-file=config-files/

# Examine the structure of file-based ConfigMaps
kubectl describe configmap app-configs
kubectl get configmap app-configs -o yaml
```

When creating ConfigMaps from files, the filename becomes the key and the file contents become the value.

#### Creating ConfigMaps from Environment Files

Environment files provide a convenient way to manage environment variables:

```bash
# Create an environment file with key-value pairs
cat > app.env << EOF
DATABASE_HOST=postgres.example.com
DATABASE_PORT=5432
LOG_LEVEL=debug
FEATURE_TOGGLE=true
CACHE_SIZE=100
WORKER_THREADS=10
API_TIMEOUT=5000
EOF

# Create a ConfigMap from the environment file
kubectl create configmap env-config \
  --from-env-file=app.env

# View the resulting ConfigMap
kubectl get configmap env-config -o yaml
```

Environment files are parsed differently than regular files. Each line becomes a separate key-value pair in the ConfigMap.

#### Declarative ConfigMap Creation

For production use, declarative YAML files provide better reproducibility and version control:

```yaml
# Save this as configmap-declarative.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: manual-config
  labels:
    app: myapp
    environment: production
data:
  # Simple key-value pairs
  database_url: "postgresql://localhost:5432/mydb"
  cache_size: "100"
  debug_mode: "false"
  api_endpoint: "https://api.example.com/v1"
  
  # Complete application configuration file
  application.yml: |
    server:
      port: 8080
      context-path: /api
      compression:
        enabled: true
        mime-types: application/json,application/xml
    logging:
      level:
        root: INFO
        com.example: DEBUG
      pattern:
        console: "%d{yyyy-MM-dd HH:mm:ss} - %msg%n"
    database:
      url: postgresql://localhost:5432/mydb
      pool:
        size: 10
        timeout: 30000
      hibernate:
        ddl-auto: validate
        show-sql: false
    cache:
      type: redis
      redis:
        host: redis.local
        port: 6379
        timeout: 2000
  
  # Nginx configuration file
  nginx.conf: |
    server {
        listen 80;
        server_name example.com;
        
        location / {
            proxy_pass http://backend:8080;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_connect_timeout 30s;
            proxy_send_timeout 30s;
            proxy_read_timeout 30s;
        }
        
        location /health {
            access_log off;
            return 200 "healthy\n";
            add_header Content-Type text/plain;
        }
        
        location /metrics {
            proxy_pass http://backend:8080/actuator/prometheus;
            access_log off;
        }
    }
```

Apply the declarative ConfigMap:

```bash
kubectl apply -f configmap-declarative.yaml

# Verify the ConfigMap was created correctly
kubectl describe configmap manual-config
```

### Working with Secrets

Secrets require additional care due to their sensitive nature. Let's explore different Secret types and creation methods.

#### Creating Generic (Opaque) Secrets

Opaque Secrets are the most flexible Secret type:

```bash
# Create a Secret with database credentials
kubectl create secret generic db-credentials \
  --from-literal=username=dbadmin \
  --from-literal=password='MySecureP@ssw0rd!' \
  --from-literal=host=database.internal \
  --from-literal=port=5432

# Create files with sensitive data
echo -n 'admin' > username.txt
echo -n 'SuperSecretPassword123!' > password.txt
echo -n 'apikey-xyz-123-abc' > apikey.txt

# Create a Secret from files
kubectl create secret generic file-secret \
  --from-file=username.txt \
  --from-file=password.txt \
  --from-file=apikey.txt

# View Secret (note values are base64 encoded)
kubectl get secret db-credentials -o yaml

# Decode specific Secret values for verification
kubectl get secret db-credentials \
  -o jsonpath='{.data.username}' | base64 -d
echo  # Add newline

kubectl get secret db-credentials \
  -o jsonpath='{.data.password}' | base64 -d
echo  # Add newline

# Clean up temporary files
rm -f username.txt password.txt apikey.txt
```

#### Creating TLS Secrets

TLS Secrets store certificates and private keys:

```bash
# Generate a self-signed certificate for testing
# In production, use certificates from a trusted CA
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key -out tls.crt \
  -subj "/CN=myapp.example.com/O=MyOrganization" \
  -addext "subjectAltName = DNS:myapp.example.com,DNS:www.myapp.example.com"

# Create a TLS Secret
kubectl create secret tls tls-secret \
  --cert=tls.crt \
  --key=tls.key

# Examine the TLS Secret structure
kubectl describe secret tls-secret
kubectl get secret tls-secret -o yaml

# Clean up certificate files
rm -f tls.key tls.crt
```

#### Creating Docker Registry Secrets

Registry Secrets authenticate with private container registries:

```bash
# Create a Docker registry Secret
# Replace with your actual registry credentials
kubectl create secret docker-registry registry-secret \
  --docker-server=registry.example.com \
  --docker-username=myuser \
  --docker-password='RegistryP@ssw0rd' \
  --docker-email=user@example.com

# For Docker Hub, use docker.io as the server
kubectl create secret docker-registry dockerhub-secret \
  --docker-server=docker.io \
  --docker-username=dockerhubuser \
  --docker-password='DockerHubP@ssw0rd' \
  --docker-email=dockeruser@example.com

# View the registry Secret structure
kubectl get secret registry-secret -o yaml
```

#### Creating Other Secret Types

```bash
# Create a basic authentication Secret
kubectl create secret generic basic-auth \
  --from-literal=username=basicuser \
  --from-literal=password='BasicP@ssw0rd' \
  --type=kubernetes.io/basic-auth

# Generate an SSH key pair for testing
ssh-keygen -t rsa -b 2048 -f ssh-privatekey -N "" -q -C "test@example.com"

# Create an SSH authentication Secret
kubectl create secret generic ssh-key-secret \
  --from-file=ssh-privatekey \
  --type=kubernetes.io/ssh-auth

# View the Secret structures
kubectl describe secret basic-auth
kubectl describe secret ssh-key-secret

# Clean up SSH keys
rm -f ssh-privatekey ssh-privatekey.pub
```

### Using ConfigMaps and Secrets in Pods

Now let's see how applications consume configuration data.

#### Environment Variables from ConfigMap

Create a pod that uses ConfigMap values as environment variables:

```yaml
# Save as pod-configmap-env.yaml
apiVersion: v1
kind: Pod
metadata:
  name: configmap-env-pod
  labels:
    app: config-demo
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["/bin/sh"]
    args:
    - -c
    - |
      echo "Starting application with ConfigMap environment variables"
      echo "================================================"
      echo "Individual environment variables:"
      echo "  DATABASE_HOST: $DATABASE_HOST"
      echo "  DATABASE_PORT: $DATABASE_PORT"
      echo "  LOG_LEVEL: $LOG_LEVEL"
      echo ""
      echo "All APP_ prefixed variables:"
      env | grep ^APP_ | sort
      echo ""
      echo "Application running. Sleeping..."
      sleep 3600
    env:
    # Individual values from ConfigMap
    - name: DATABASE_HOST
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: database_host
    - name: DATABASE_PORT
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: database_port
    - name: LOG_LEVEL
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: log_level
    # All values from ConfigMap with prefix
    envFrom:
    - configMapRef:
        name: app-config
        prefix: APP_
```

Apply and test:

```bash
kubectl apply -f pod-configmap-env.yaml
kubectl wait --for=condition=Ready pod/configmap-env-pod
kubectl logs configmap-env-pod
```

#### Environment Variables from Secrets

Create a pod that uses Secret values as environment variables:

```yaml
# Save as pod-secret-env.yaml
apiVersion: v1
kind: Pod
metadata:
  name: secret-env-pod
  labels:
    app: config-demo
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["/bin/sh"]
    args:
    - -c
    - |
      echo "Starting application with Secret environment variables"
      echo "================================================"
      echo "Database connection info:"
      echo "  Username: $DB_USERNAME"
      echo "  Password length: ${#DB_PASSWORD} characters"
      echo "  Host: $SECRET_host"
      echo "  Port: $SECRET_port"
      echo ""
      echo "Note: Password not displayed for security"
      echo "Application running. Sleeping..."
      sleep 3600
    env:
    # Individual values from Secret
    - name: DB_USERNAME
      valueFrom:
        secretKeyRef:
          name: db-credentials
          key: username
    - name: DB_PASSWORD
      valueFrom:
        secretKeyRef:
          name: db-credentials
          key: password
    # All values from Secret with prefix
    envFrom:
    - secretRef:
        name: db-credentials
        prefix: SECRET_
```

Apply and test:

```bash
kubectl apply -f pod-secret-env.yaml
kubectl wait --for=condition=Ready pod/secret-env-pod
kubectl logs secret-env-pod
```

#### Volume Mounts from ConfigMap

Mount ConfigMaps as files in the container filesystem:

```yaml
# Save as pod-configmap-volume.yaml
apiVersion: v1
kind: Pod
metadata:
  name: configmap-volume-pod
  labels:
    app: config-demo
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["/bin/sh"]
    args:
    - -c
    - |
      echo "ConfigMap mounted as volume"
      echo "============================"
      echo "Files in /etc/config:"
      ls -la /etc/config/
      echo ""
      echo "Content of application.properties:"
      cat /etc/config/application.properties
      echo ""
      echo "Content of database.conf:"
      cat /etc/config/database.conf
      echo ""
      echo "Application running. Sleeping..."
      sleep 3600
    volumeMounts:
    - name: config-volume
      mountPath: /etc/config
      readOnly: true
  volumes:
  - name: config-volume
    configMap:
      name: app-configs
      # Optional: set file permissions
      defaultMode: 0644
```

Apply and test:

```bash
kubectl apply -f pod-configmap-volume.yaml
kubectl wait --for=condition=Ready pod/configmap-volume-pod
kubectl logs configmap-volume-pod

# Interactive exploration
kubectl exec -it configmap-volume-pod -- sh
# Inside the pod:
# ls -la /etc/config/
# cat /etc/config/application.properties
# exit
```

#### Volume Mounts from Secrets

Mount Secrets as files with appropriate permissions:

```yaml
# Save as pod-secret-volume.yaml
apiVersion: v1
kind: Pod
metadata:
  name: secret-volume-pod
  labels:
    app: config-demo
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["/bin/sh"]
    args:
    - -c
    - |
      echo "Secret mounted as volume"
      echo "========================"
      echo "Files in /etc/secrets:"
      ls -la /etc/secrets/
      echo ""
      echo "Username: $(cat /etc/secrets/username)"
      echo "Password length: $(cat /etc/secrets/password | wc -c) characters"
      echo "Host: $(cat /etc/secrets/host)"
      echo "Port: $(cat /etc/secrets/port)"
      echo ""
      echo "Note: Actual password not displayed for security"
      echo "Application running. Sleeping..."
      sleep 3600
    volumeMounts:
    - name: secret-volume
      mountPath: /etc/secrets
      readOnly: true
  volumes:
  - name: secret-volume
    secret:
      secretName: db-credentials
      # Restrictive permissions for security
      defaultMode: 0400
```

Apply and test:

```bash
kubectl apply -f pod-secret-volume.yaml
kubectl wait --for=condition=Ready pod/secret-volume-pod
kubectl logs secret-volume-pod

# Verify file permissions
kubectl exec secret-volume-pod -- ls -la /etc/secrets/
```

#### Selective Key Mounting

Sometimes you need only specific keys from ConfigMaps or Secrets:

```yaml
# Save as pod-selective-mount.yaml
apiVersion: v1
kind: Pod
metadata:
  name: selective-mount-pod
  labels:
    app: config-demo
spec:
  containers:
  - name: nginx
    image: nginx:1.24-alpine
    ports:
    - containerPort: 80
    command: ["/bin/sh"]
    args:
    - -c
    - |
      echo "Starting nginx with custom configuration"
      # Verify configuration files are mounted
      ls -la /etc/nginx/
      ls -la /etc/ssl/certs/
      ls -la /etc/ssl/private/
      # Start nginx
      nginx -g 'daemon off;'
    volumeMounts:
    # Mount only nginx.conf from ConfigMap
    - name: config-volume
      mountPath: /etc/nginx/nginx.conf
      subPath: nginx.conf
      readOnly: true
    # Mount TLS certificate
    - name: tls-volume
      mountPath: /etc/ssl/certs/tls.crt
      subPath: tls.crt
      readOnly: true
    # Mount TLS key with restrictive permissions
    - name: tls-volume
      mountPath: /etc/ssl/private/tls.key
      subPath: tls.key
      readOnly: true
  volumes:
  - name: config-volume
    configMap:
      name: manual-config
      items:
      - key: nginx.conf
        path: nginx.conf
        mode: 0644
  - name: tls-volume
    secret:
      secretName: tls-secret
      items:
      - key: tls.crt
        path: tls.crt
        mode: 0644
      - key: tls.key
        path: tls.key
        mode: 0600
```

Apply and verify:

```bash
kubectl apply -f pod-selective-mount.yaml
kubectl wait --for=condition=Ready pod/selective-mount-pod --timeout=60s

# Check that nginx started successfully
kubectl logs selective-mount-pod

# Verify mounted files
kubectl exec selective-mount-pod -- ls -la /etc/nginx/
kubectl exec selective-mount-pod -- ls -la /etc/ssl/certs/
kubectl exec selective-mount-pod -- ls -la /etc/ssl/private/
```
