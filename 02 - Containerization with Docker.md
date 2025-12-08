## Understanding the Container Revolution

### The Evolution from Physical Servers to Containers

The journey to containers began with physical servers, where each application required its own dedicated hardware. This approach was wasteful—servers often ran at 10-20% capacity, yet organizations needed multiple machines for isolation and security. Virtual machines emerged as the first solution, allowing multiple "virtual servers" to run on single physical machines through hypervisors like VMware or VirtualBox.

While VMs solved the hardware waste problem, they introduced new challenges. Each VM needs its own complete operating system, consuming gigabytes of RAM and storage. Starting a VM takes minutes as it boots an entire OS. Running ten applications meant running ten full operating systems—a significant overhead that containers elegantly solve.

### How Containers Differ from Virtual Machines

Containers represent a fundamental architectural shift. Instead of virtualizing hardware like VMs do, containers virtualize at the operating system level. All containers on a host share the same OS kernel but run in isolated processes. 

To understand this better, imagine an apartment building versus individual houses. Virtual machines are like separate houses—each has its own foundation, plumbing, electrical system, and all the infrastructure needed to function independently. This independence provides strong isolation but requires duplicating everything for each house. Containers are like apartments in a single building—they share the core infrastructure (foundation, main water lines, electrical grid) but maintain complete privacy and isolation through walls and separate entrances. This shared infrastructure model explains why:

- **Size**: Containers measure in megabytes (typically 5-200MB) versus gigabytes for VMs (typically 1-20GB). The container only contains your application and its specific dependencies, not an entire OS.
- **Startup**: Containers launch in milliseconds versus minutes for VMs. There's no OS to boot—the container process starts almost instantly.
- **Density**: A server can run thousands of containers versus dozens of VMs. The reduced overhead means more applications per server.
- **Resource usage**: Containers add minimal overhead versus significant overhead for each VM. The shared kernel means less memory and CPU waste.

## Core Problems That Containers Solve

### 1. The "Works on My Machine" Syndrome

Every developer has experienced this frustrating scenario: code runs perfectly on their laptop but crashes in production. The root causes are environmental differences that are often subtle but critical:

- **Library versions**: Your laptop has Python 3.9.2, but production has 3.9.1 with a bug affecting your code
- **System libraries**: Different versions of underlying C libraries can cause unexpected behavior
- **Configuration files**: Database connection strings, API endpoints, or file paths differ between environments
- **Operating system differences**: Code developed on macOS behaves differently on Linux
- **Missing dependencies**: A tool installed globally on your machine isn't present in production

Containers solve this by packaging your application with its complete runtime environment. The container includes your code, the exact runtime version, all system tools, libraries, and settings. This package runs identically whether on a developer's laptop, test server, or production cloud. The phrase "works on my machine" becomes "works in my container"—and if it works in your container, it works everywhere.

### 2. Dependency Conflicts Between Applications

Consider this real scenario: Application A requires Python 3.8 with Django 2.2, while Application B needs Python 3.10 with Django 4.0. On a traditional server, you'd face a dilemma:

- Install both Python versions and manage complex virtual environments
- Use separate servers (expensive and wasteful)
- Force one application to use incompatible versions (likely causing bugs)
- Spend hours configuring workarounds that break with updates

Containers eliminate this problem entirely. Each application lives in its own isolated container with exactly the dependencies it needs. Container A has Python 3.8 and Django 2.2. Container B has Python 3.10 and Django 4.0. They coexist peacefully on the same server, unaware of each other's existence. No conflicts, no compromises, no complex workarounds.

### 3. Infrastructure Configuration Complexity

Traditional deployments require extensive documentation: "Install these 15 packages, edit these 7 configuration files, set these permissions, create these users, configure this service to start on boot..." This manual process is:

- **Error-prone**: One missed step or typo breaks everything
- **Time-consuming**: Hours spent configuring each server
- **Difficult to reproduce**: Even with documentation, subtle differences creep in
- **Hard to maintain**: Documentation becomes outdated quickly

With containers, infrastructure becomes code. A simple text file (Dockerfile) defines everything needed to run your application. This file is:

- **Version controlled**: Track every infrastructure change in Git
- **Reviewable**: Team members can review infrastructure changes like code
- **Reproducible**: Build identical environments every time
- **Self-documenting**: The Dockerfile IS the documentation

### 4. Resource Waste from VMs

A typical VM might allocate 4GB RAM and 20GB storage just for the operating system, before your application even starts. Running ten microservices means:

- 40GB of RAM just for operating systems
- 200GB of disk space for OS files
- CPU cycles wasted on redundant OS processes
- Network bandwidth for OS updates across all VMs

Containers share the host OS kernel, eliminating this duplication. Those same ten microservices might use just 1GB total, leaving more resources for your actual applications. This efficiency translates directly to cost savings—fewer servers needed, lower cloud bills, reduced data center footprint.

### 5. Slow Deployment and Scaling

VMs take minutes to boot because they start an entire operating system. This makes auto-scaling sluggish and deployments time-consuming. When Black Friday traffic hits your e-commerce site, waiting 5 minutes for new VMs to handle the load means lost sales.

Containers start in seconds or less, enabling:

- **Instant scaling**: Respond to traffic spikes immediately
- **Rapid deployments**: Push updates in seconds, not minutes
- **Quick rollbacks**: Revert problematic deployments instantly
- **Efficient development**: Developers don't wait for environments to start

## Container Architecture: How It Really Works

### Linux Kernel Features That Enable Containers

Containers aren't magic—they're isolated processes leveraging three key Linux kernel features that have existed for years. Understanding these features demystifies containers and explains their capabilities and limitations.

#### Namespaces: Creating Isolated Worlds

Namespaces are a Linux kernel feature that partitions system resources so different processes see different views of the system. Think of namespaces like virtual reality headsets—each process wearing a headset sees a different world, unaware that other worlds exist. Linux provides eight types of namespaces:

1. **PID namespace**: Controls what processes a container can see. Inside the container, your application might be PID 1 (like it's the only process running), but on the host, it might be PID 3847. The container can't see or interact with other processes on the host.

2. **Network namespace**: Gives each container its own network stack—network interfaces, IP addresses, routing tables, firewall rules. Container A might think it's listening on port 80, and Container B also thinks it's listening on port 80. Neither conflicts because they have separate network namespaces.

3. **Mount namespace**: Controls what parts of the filesystem a container can see. Each container has its own root filesystem and can't see or access files from other containers or the host (unless explicitly shared).

4. **UTS namespace**: Allows each container to have its own hostname and domain name. Container A can be "webserver" while Container B is "database" on the same host.

5. **IPC namespace**: Isolates inter-process communication mechanisms like shared memory and message queues. Processes in different containers can't accidentally share memory.

6. **User namespace**: Maps users inside the container to different users outside. Root inside the container might map to unprivileged user 1000 on the host, improving security.

7. **Cgroup namespace**: Isolates the view of control groups, hiding the host's cgroup hierarchy from the container.

8. **Time namespace**: Allows containers to have different system time views, useful for testing time-dependent code.

When you start a container, the kernel creates new namespaces for it. The containerized process believes it's running on a dedicated system—it sees only its own processes, network, and filesystem.

#### Control Groups (cgroups): Resource Management

Control groups manage and limit resources. They answer critical questions:

- How much CPU can this container use?
- How much memory is it allowed?
- What's its disk I/O priority?
- How much network bandwidth can it consume?

Cgroups work hierarchically. You might limit a group of containers to 4GB total memory, then subdivide that among individual containers. The kernel enforces these limits strictly:

- **Memory limits**: If a container tries to use more memory than allowed, the kernel's Out-Of-Memory (OOM) killer terminates processes within that container to free memory
- **CPU limits**: The kernel's scheduler ensures a container limited to 0.5 CPUs gets exactly half the CPU time of an unlimited container
- **I/O limits**: The kernel can limit read/write speeds to prevent one container from monopolizing disk access
- **Network limits**: Traffic shaping ensures containers don't exceed bandwidth allocations

These limits prevent "noisy neighbor" problems where one container consumes all resources, starving others.

#### Union Filesystems: Efficient Layer Management

Union filesystems enable Docker's layer architecture—one of its most clever innovations. Here's how it works:

Imagine transparencies stacked on an overhead projector. Each transparency can add content, and when you look down through the stack, you see the combined image. Union filesystems work similarly:

1. **Base layers** (read-only): The operating system and common dependencies. Like printed transparencies that can't be modified.

2. **Application layers** (read-only): Your application code and specific dependencies. More transparencies stacked on top.

3. **Container layer** (read-write): A blank transparency on top where runtime changes are written.

When you read a file, the filesystem looks down through the layers until it finds the file. When you write, it uses "copy-on-write"—copying the file to the top layer before modifying it. The original remains unchanged in lower layers.

This architecture provides massive storage savings. If you run 100 containers from the same nginx image, the base nginx layers exist only once on disk. Each container just adds its own thin writable layer for runtime changes. A 200MB base image + 100 containers might use just 201MB total (200MB base + 1MB of changes across all containers) instead of 20GB.

### The Container Lifecycle: From Image to Running Container

Understanding what happens when you type `docker run nginx` helps demystify containers:

1. **Image Resolution**: Docker first checks if the nginx image exists locally. If not, it contacts the configured registry (Docker Hub by default) and downloads the image layer by layer. Each layer is compressed for transfer and cached locally.

2. **Storage Preparation**: Docker prepares the filesystem by:
   - Extracting each layer to the storage driver location
   - Creating a union filesystem mount combining all read-only layers
   - Adding a new read-write layer on top for the container
   - Setting up mount points for any volumes

3. **Namespace Creation**: The kernel creates isolated namespaces:
   - New PID namespace (container gets its own process tree)
   - New network namespace (container gets virtual network interface)
   - New mount namespace (container sees its own filesystem)
   - Other namespaces as configured

4. **Cgroup Configuration**: Docker configures control groups:
   - Creates a new cgroup for the container
   - Sets memory limits, CPU shares, I/O weights
   - Registers the container's process with the cgroup

5. **Network Setup**: Docker configures networking:
   - Creates virtual ethernet pair (veth)
   - Attaches one end to container namespace
   - Attaches other end to docker bridge
   - Assigns IP address from bridge subnet
   - Sets up NAT rules for port mapping

6. **Security Configuration**: Docker applies security policies:
   - Drops dangerous Linux capabilities
   - Applies AppArmor or SELinux profiles
   - Sets up seccomp filters to limit system calls
   - Configures user namespace mapping if enabled

7. **Process Launch**: Finally, Docker:
   - Executes the container's entrypoint/command
   - Attaches stdin/stdout/stderr as configured
   - Monitors the process for exit

This entire process typically completes in milliseconds, which is why containers start so quickly compared to VMs.

## Docker Fundamentals: Hands-On Learning

### Initial Setup and Verification

Before diving into Docker commands, let's understand what we're working with. Docker consists of several components working together:

```bash
# Check Docker version - shows both client and server versions
docker --version

# View detailed Docker system information
# This shows configuration, storage driver, network details, and more
docker info

# Test your installation with the hello-world image
# This command does several things:
# 1. Docker client contacts the Docker daemon
# 2. Daemon pulls the "hello-world" image from Docker Hub
# 3. Daemon creates a new container from that image
# 4. Daemon streams output to the Docker client
# 5. Client sends it to your terminal
docker run --rm hello-world
```

### Understanding Docker's Architecture

Docker uses a client-server model that's important to understand:

1. **Docker Client**: The `docker` command you type. It's just a CLI tool that sends requests to the Docker daemon. The client can connect to local or remote daemons.

2. **Docker Daemon** (dockerd): The background service doing all the work—building images, running containers, managing networks and volumes. It exposes a REST API that the client uses.

3. **Docker Registry**: Storage for images. Docker Hub is the default public registry, but you can use private registries like AWS ECR, Google Container Registry, or self-hosted registries.

When you type a Docker command, the client sends an API request to the daemon, which performs the action and returns results. This architecture allows remote Docker management—your client can control Docker daemons on other machines.

## Working with Docker Images

### Image Basics and Management

Docker images are read-only templates for creating containers. Think of an image like a class in programming, and containers as instances of that class. Images are built in layers, with each layer representing a set of filesystem changes. This layered approach enables sharing and efficiency.

```bash
# Pull an image from Docker Hub
# This downloads all layers of the Ubuntu 22.04 image
docker pull ubuntu:22.04

# Pull latest version (latest tag is default if not specified)
# Note: 'latest' doesn't mean most recent - it's just a tag name
docker pull alpine

# List all local images
# Shows repository, tag, image ID, creation time, and size
docker images

# Search Docker Hub for images
# Shows official images, stars (popularity), and descriptions
docker search redis --limit 5

# Remove a specific image
# Fails if containers are using this image
docker rmi ubuntu:22.04

# Force remove (even if containers exist)
docker rmi -f ubuntu:22.04

# Remove all unused images
# -a flag removes all images not used by containers
docker image prune -a

# Get detailed image information
# Shows layers, environment variables, command, architecture, etc.
docker inspect alpine

# See how an image was built (layer history)
# Each line represents a layer and the command that created it
docker history alpine

# More readable history format
docker history --human --no-trunc alpine
```

### Understanding Image Layers

Each instruction in a Dockerfile creates a new layer. Docker caches layers and reuses them when possible, making builds faster and storage more efficient:

```bash
# View the layers of an image
# Each layer has a size and command that created it
docker history nginx:alpine --no-trunc

# See actual storage usage
# Shows how much space images, containers, and volumes use
docker system df

# See detailed storage by image
# -v flag provides verbose output with individual container sizes
docker system df -v
```

Layers are immutable—once created, they never change. When you update an image, Docker creates new layers with the changes. This immutability enables sharing: multiple images can reference the same base layers without duplicating storage.

### Image Tagging Strategy

Tags help manage image versions. A tag is a human-readable label pointing to a specific image ID:

```bash
# Tag an image (creates alias, doesn't copy)
# Format: docker tag SOURCE_IMAGE[:TAG] TARGET_IMAGE[:TAG]
docker tag nginx:alpine mycompany/nginx:v1.0

# Multiple tags can point to same image ID
# This is common for marking stable versions
docker tag nginx:alpine mycompany/nginx:latest
docker tag nginx:alpine mycompany/nginx:stable

# View all tags (they'll have same IMAGE ID)
docker images | grep mycompany

# Tags are important for versioning:
# - latest: Conventionally the newest (but not guaranteed)
# - stable: Current stable release
# - v1.0, v1.1: Specific versions
# - dev: Development version
```

## Container Lifecycle Management

### Running Containers: The Basics

Containers are running instances of images. The `docker run` command creates and starts a container in one operation:

```bash
# Simple run - container runs, prints, then exits
# --rm flag removes container after it exits
docker run --rm alpine echo "Hello Docker"

# Interactive terminal session
# -i: Keep stdin open
# -t: Allocate pseudo-TTY
# You get a shell inside the container
docker run -it --rm ubuntu:22.04 /bin/bash
# Try these commands inside:
# pwd                  # See current directory
# ps aux              # See processes (very few!)
# cat /etc/os-release # Confirm you're in Ubuntu
# exit                # Leave container

# Run in background (detached)
# -d: Run in background
# --name: Give container a friendly name
docker run -d --name my-nginx nginx:alpine

# With environment variables
# -e: Set environment variable
docker run --rm -e APP_ENV=production -e DEBUG=false alpine env

# With port mapping (host:container)
# -p: Publish container port to host
docker run -d -p 8080:80 --name webserver nginx:alpine
# Visit http://localhost:8080 in your browser

# Clean up our containers
docker rm -f my-nginx webserver
```

### Container State Management

Containers have several states throughout their lifecycle: created, running, paused, stopped, dead. Understanding these states helps troubleshoot issues:

```bash
# Create a long-running container for testing
docker run -d --name test-container nginx:alpine

# View running containers
# Shows container ID, image, command, creation time, status, ports, names
docker ps

# View ALL containers (including stopped)
# -a flag shows all containers regardless of state
docker ps -a

# Stop container gracefully
# Sends SIGTERM, waits 10 seconds, then SIGKILL if needed
docker stop test-container

# Start stopped container
# Resumes with same configuration
docker start test-container

# Restart container (stop then start)
docker restart test-container

# Pause container (freeze all processes)
# Useful for debugging or temporary resource relief
docker pause test-container
docker ps  # Notice the (Paused) status

# Unpause (resume processes)
docker unpause test-container

# Kill container immediately (SIGKILL)
# Use when stop doesn't work
docker kill test-container

# Remove container
docker rm test-container

# Remove running container forcefully
docker rm -f test-container
```

### Interacting with Running Containers

Once a container is running, you often need to inspect it, debug issues, or copy files:

```bash
# Start a container for interaction
docker run -d --name interactive-test alpine sleep 3600

# Execute commands inside running container
docker exec interactive-test ls -la /
docker exec interactive-test ps aux

# Interactive shell session in running container
# This is how you debug running containers
docker exec -it interactive-test /bin/sh
# Inside container:
# touch /tmp/test-file
# echo "Hello from container" > /tmp/message
# cat /proc/1/status  # See main process details
# exit

# Verify our changes persist
docker exec interactive-test cat /tmp/message

# Copy files TO container
echo "File from host" > host-file.txt
docker cp host-file.txt interactive-test:/tmp/
docker exec interactive-test cat /tmp/host-file.txt

# Copy FROM container to host
docker cp interactive-test:/tmp/message container-message.txt
cat container-message.txt

# View container logs
# Shows stdout/stderr from main process
docker logs interactive-test

# Follow logs in real-time (like tail -f)
# docker logs -f interactive-test  # Ctrl+C to stop

# Show last 10 lines
docker logs --tail 10 interactive-test

# Show logs since specific time
docker logs --since 10m interactive-test  # Last 10 minutes

# Inspect container configuration
# Returns JSON with all container details
docker inspect interactive-test | head -30

# View specific values using format
docker inspect --format='{{.State.Status}}' interactive-test
docker inspect --format='{{.NetworkSettings.IPAddress}}' interactive-test

# View resource usage
# Shows CPU, memory, network, and disk I/O
docker stats --no-stream interactive-test

# Stream stats (like top)
# docker stats interactive-test  # Ctrl+C to stop

# Clean up
docker rm -f interactive-test
rm -f host-file.txt container-message.txt
```

### Resource Limits and Constraints

Preventing containers from consuming all system resources is crucial for stability. Docker uses cgroups to enforce limits:

```bash
# Memory limit (container killed if exceeded)
# --memory or -m: Set memory limit
docker run -d --memory="256m" --name mem-limited nginx:alpine

# Memory + swap limit
# Total memory+swap available to container
docker run -d --memory="256m" --memory-swap="512m" --name swap-limited nginx:alpine

# CPU limits
# --cpus: Number of CPUs (can be fractional)
docker run -d --cpus="0.5" --name cpu-limited nginx:alpine

# CPU shares (relative weight)
# Default is 1024, half that gets half CPU when contended
docker run -d --cpu-shares=512 --name cpu-shares nginx:alpine

# Verify limits are applied
docker stats --no-stream mem-limited swap-limited cpu-limited cpu-shares

# Test memory limit (this will cause container to be killed)
# Container tries to allocate 100MB but only has 10MB limit
docker run --rm --memory="10m" alpine sh -c "dd if=/dev/zero of=/tmp/file bs=1M count=100"
# You'll see it gets killed

# Check container status after OOM kill
docker run -d --name oom-test --memory="10m" alpine sh -c "sleep 2 && dd if=/dev/zero of=/tmp/file bs=1M count=100"
sleep 5
docker inspect oom-test --format='{{.State.OOMKilled}}'  # Should show true

# Clean up
docker rm -f mem-limited swap-limited cpu-limited cpu-shares oom-test
```

## Data Persistence with Volumes

### Understanding Volume Types

Containers are ephemeral—when removed, their data disappears. This is problematic for databases, user uploads, or any persistent state. Docker provides three mechanisms for data persistence:

1. **Named Volumes**: Docker manages these in a special directory (/var/lib/docker/volumes/ on Linux). They're the best choice for production because:
   - Docker handles permissions and paths
   - Easy to backup and migrate
   - Work on all platforms consistently
   - Can be shared between containers safely

2. **Bind Mounts**: Map host directories directly into containers. Perfect for development because:
   - Changes on host immediately visible in container
   - Easy to edit files with host tools
   - Can mount source code for live reloading
   - But: Permission issues possible, not portable

3. **tmpfs Mounts**: Exist only in memory, never touch disk. Ideal for:
   - Sensitive data (passwords, keys)
   - Temporary cache files
   - Performance-critical temporary data
   - But: Data lost when container stops

### Working with Named Volumes

Named volumes are Docker's recommended way to persist data. Docker handles all the complexity:

```bash
# Create a named volume
docker volume create app-data

# List all volumes
docker volume ls

# Inspect volume details (shows mount point, driver, options)
docker volume inspect app-data

# Use volume in container
# -v volume_name:container_path
docker run -d \
  --name postgres-db \
  -v app-data:/var/lib/postgresql/data \
  -e POSTGRES_PASSWORD=secret \
  postgres:13-alpine

# Write data to volume
docker exec postgres-db psql -U postgres -c "CREATE DATABASE testdb;"

# Data persists even after container removal
docker rm -f postgres-db

# New container can use same data
docker run -d \
  --name postgres-db-new \
  -v app-data:/var/lib/postgresql/data \
  -e POSTGRES_PASSWORD=secret \
  postgres:13-alpine

# Verify data still exists
docker exec postgres-db-new psql -U postgres -c "\l" | grep testdb

# Backup a volume
# Use a temporary container to tar the volume contents
docker run --rm \
  -v app-data:/data \
  -v $(pwd):/backup \
  alpine tar czf /backup/app-data-backup.tar.gz -C /data .

# Clean up
docker rm -f postgres-db-new
docker volume rm app-data
rm -f app-data-backup.tar.gz
```

### Bind Mounts for Development

Bind mounts are perfect for development workflows where you want code changes to reflect immediately:

```bash
# Create a development directory
mkdir -p ~/dev-site
cd ~/dev-site

# Create a simple website
# File: index.html
echo '<!DOCTYPE html>
<html>
<head>
    <title>Dev Site</title>
    <style>
        body { font-family: Arial; margin: 40px; }
        h1 { color: #333; }
    </style>
</head>
<body>
    <h1>Development Website</h1>
    <p>Edit this file and refresh browser!</p>
    <p>Time: <span id="time"></span></p>
    <script>
        document.getElementById("time").innerText = new Date().toLocaleTimeString();
    </script>
</body>
</html>' > index.html

# Run nginx with bind mount
# -v $(pwd):/usr/share/nginx/html:ro
# $(pwd) expands to current directory
# :ro makes it read-only in container
docker run -d \
  --name dev-server \
  -p 8080:80 \
  -v $(pwd):/usr/share/nginx/html:ro \
  nginx:alpine

echo "Visit http://localhost:8080"
echo "Edit index.html and refresh browser to see changes"

# Make a change to demonstrate live updates
echo '<p style="color: blue;">This line was added while container is running!</p>' >> index.html
echo "Refresh your browser to see the new content"

# Bind mounts work with any directory
mkdir -p config
echo "server_name example.com;" > config/custom.conf

# Mount multiple directories
docker run -d \
  --name dev-server-multi \
  -p 8081:80 \
  -v $(pwd):/usr/share/nginx/html:ro \
  -v $(pwd)/config:/etc/nginx/conf.d:ro \
  nginx:alpine

# Clean up
docker rm -f dev-server dev-server-multi
cd ~
rm -rf ~/dev-site
```

### tmpfs Mounts for Sensitive Data

tmpfs mounts provide memory-only storage that never touches disk—perfect for sensitive data:

```bash
# Create container with tmpfs mount
# --tmpfs /path:options
docker run -d \
  --name secure-app \
  --tmpfs /app/secrets:size=10m \
  alpine sh -c "echo 'sensitive-password-123' > /app/secrets/key.txt && sleep 3600"

# Verify it's in memory (tmpfs filesystem)
docker exec secure-app df -h /app/secrets
# Shows tmpfs filesystem type

# Data exists while container runs
docker exec secure-app cat /app/secrets/key.txt

# But it's only in RAM - stop container and data is gone
docker stop secure-app
docker start secure-app
docker exec secure-app ls /app/secrets/  # Empty!

# tmpfs with specific options
docker run -d \
  --name cache-app \
  --tmpfs /cache:size=100m,mode=1777 \
  alpine sh -c "echo 'cache data' > /cache/data.txt && sleep 3600"

# Practical example: Redis with memory-only data
docker run -d \
  --name redis-mem \
  --tmpfs /data:size=100m \
  redis:alpine redis-server --save ""

# Write data
docker exec redis-mem redis-cli SET key1 "value1"
docker exec redis-mem redis-cli GET key1

# Clean up
docker rm -f secure-app cache-app redis-mem
```

## Container Networking

### Network Types in Docker

Docker networking is crucial for container communication. Docker provides several network drivers, each serving different purposes:

1. **bridge** (default): Creates an isolated network segment for containers. Containers can communicate with each other and the host can reach them, but they're isolated from external networks unless you publish ports. This is perfect for single-host applications.

2. **host**: Removes network isolation—container uses the host's network stack directly. The container shares the host's IP address and ports. Fast but less secure, used when you need maximum network performance.

3. **none**: No network access at all. The container has only a loopback interface. Used for maximum isolation or containers that don't need network.

4. **overlay**: Enables communication between containers across multiple Docker hosts. Used in Docker Swarm for distributed applications.

5. **macvlan**: Assigns a MAC address to container, making it appear as a physical device on the network. Used when containers need to appear as physical hosts on the network.

### Default Bridge Network

When you don't specify a network, containers use the default bridge. This has limitations:

```bash
# Containers on default bridge can communicate via IP only
docker run -d --name app1 nginx:alpine
docker run -d --name app2 nginx:alpine

# Get container IPs
APP1_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' app1)
APP2_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' app2)
echo "App1 IP: $APP1_IP"
echo "App2 IP: $APP2_IP"

# Containers can ping by IP
docker exec app2 ping -c 2 $APP1_IP

# But NOT by name (this will fail)
docker exec app2 ping -c 2 app1 2>/dev/null || echo "Cannot resolve by name on default bridge"

# This is a limitation of default bridge - no automatic DNS

# View network details
docker network inspect bridge

# Clean up
docker rm -f app1 app2
```

### Custom Bridge Networks (Recommended)

Custom networks provide automatic DNS resolution between containers—a major advantage:

```bash
# Create custom network
docker network create my-network --driver bridge

# Can specify subnet and gateway
docker network create my-network2 \
  --driver bridge \
  --subnet 172.20.0.0/16 \
  --gateway 172.20.0.1

# View network details
docker network inspect my-network

# Run containers on custom network
docker run -d --name web --network my-network nginx:alpine
docker run -d --name api --network my-network alpine sleep 3600

# Containers can resolve each other by name!
# Docker provides automatic DNS for custom networks
docker exec api ping -c 2 web
docker exec web ping -c 2 api

# Can also use full container name
docker exec api ping -c 2 web.my-network

# Connect running container to network
docker run -d --name database alpine sleep 3600
docker network connect my-network database

# Container is now on both networks (bridge and my-network)
docker inspect database --format='{{json .NetworkSettings.Networks}}' | python3 -m json.tool

# Can communicate with containers on custom network
docker exec api ping -c 2 database

# Disconnect from network
docker network disconnect my-network database

# Create isolated networks for security
docker network create frontend
docker network create backend

docker run -d --name web-server --network frontend nginx:alpine
docker run -d --name app-server --network backend alpine sleep 3600
docker run -d --name db-server --network backend alpine sleep 3600

# Connect app-server to both networks (it's the bridge)
docker network connect frontend app-server

# Now web can reach app, app can reach db, but web cannot reach db
docker exec web-server ping -c 1 app-server  # Works
docker exec app-server ping -c 1 db-server   # Works
docker exec web-server ping -c 1 db-server 2>/dev/null || echo "Web cannot reach DB (good isolation!)"

# Clean up
docker rm -f web api database web-server app-server db-server
docker network rm my-network my-network2 frontend backend
```

### Port Publishing

Publishing ports makes container services accessible from outside Docker:

```bash
# Publish specific port
# -p host_port:container_port
docker run -d -p 8080:80 --name web1 nginx:alpine
echo "Access at http://localhost:8080"

# Publish on specific interface only
# 127.0.0.1: means localhost only (not accessible externally)
docker run -d -p 127.0.0.1:8081:80 --name web2 nginx:alpine
echo "Access at http://127.0.0.1:8081 (localhost only)"

# Publish to random port
# -P publishes all exposed ports to random ports
docker run -d -P --name web3 nginx:alpine
docker port web3
RANDOM_PORT=$(docker port web3 80 | cut -d: -f2)
echo "Access at http://localhost:$RANDOM_PORT"

# Multiple port mappings
docker run -d \
  -p 8082:80 \
  -p 4443:443 \
  --name web4 \
  nginx:alpine

# UDP port mapping
docker run -d \
  -p 5353:53/udp \
  --name dns \
  alpine sleep 3600

# View all port mappings
docker port web4

# Clean up
docker rm -f web1 web2 web3 web4 dns
```

## Building Custom Images with Dockerfiles

### Dockerfile Basics

A Dockerfile is a text document containing instructions that Docker uses to build an image. Each instruction creates a new layer in the image. Think of it as a recipe that precisely defines your application's environment:

```bash
# Create a working directory
mkdir -p ~/docker-project && cd ~/docker-project

# Create a simple Python application
# File: app.py
echo 'from flask import Flask, request
import os
import socket

app = Flask(__name__)

@app.route("/")
def hello():
    html = "<h3>Hello {name}!</h3>"
    html += "<b>Hostname:</b> {hostname}<br/>"
    html += "<b>IP:</b> {ip}<br/>"
    html += "<b>Environment:</b> {env}<br/>"
    return html.format(
        name=os.getenv("NAME", "World"),
        hostname=socket.gethostname(),
        ip=socket.gethostbyname(socket.gethostname()),
        env=os.getenv("APP_ENV", "development")
    )

@app.route("/health")
def health():
    return "OK", 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)' > app.py

# Create requirements file
# File: requirements.txt
echo 'flask==2.3.0
werkzeug==2.3.0' > requirements.txt

# Create Dockerfile with detailed comments
# File: Dockerfile
echo '# Start from official Python image
# Using slim variant for smaller size
FROM python:3.9-slim

# Set working directory inside container
# All subsequent commands run from here
WORKDIR /app

# Copy requirements first (for better layer caching)
# If requirements don not change, this layer is reused
COPY requirements.txt .

# Install Python dependencies
# --no-cache-dir reduces image size by not storing pip cache
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
# This is separate so code changes do not invalidate pip install layer
COPY app.py .

# Document the port (informational only, does not publish)
EXPOSE 5000

# Set environment variables
# These can be overridden at runtime
ENV NAME=Docker
ENV APP_ENV=production

# Define health check
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:5000/health')" || exit 1

# Run the application
# CMD is the default command, can be overridden at runtime
CMD ["python", "app.py"]' > Dockerfile

# Build the image
# -t tags the image with a name:tag
docker build -t my-flask-app:v1 .

# The build process:
# 1. Sends build context to daemon
# 2. Runs each instruction, creating a layer
# 3. Tags the final image

# Run the container
docker run -d -p 5000:5000 --name flask-app my-flask-app:v1

# Test it
sleep 2
curl http://localhost:5000
echo ""
curl http://localhost:5000/health

# View logs
docker logs flask-app

# Check health status
docker inspect --format='{{.State.Health.Status}}' flask-app

# Clean up
docker rm -f flask-app
cd ~ && rm -rf ~/docker-project
```

### Multi-Stage Builds for Smaller Images

Multi-stage builds are a powerful feature that creates smaller, more secure production images by separating build dependencies from runtime:

```bash
# Create project directory
mkdir -p ~/multistage-demo && cd ~/multistage-demo

# Create a Go application
# File: main.go
echo 'package main

import (
    "fmt"
    "log"
    "net/http"
    "os"
)

func handler(w http.ResponseWriter, r *http.Request) {
    hostname, _ := os.Hostname()
    fmt.Fprintf(w, "Hello from Go multi-stage build!\nHostname: %s\nPath: %s\n", 
                hostname, r.URL.Path)
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
    w.WriteHeader(http.StatusOK)
    fmt.Fprint(w, "healthy")
}

func main() {
    http.HandleFunc("/", handler)
    http.HandleFunc("/health", healthHandler)
    
    port := os.Getenv("PORT")
    if port == "" {
        port = "8080"
    }
    
    fmt.Printf("Server starting on :%s\n", port)
    log.Fatal(http.ListenAndServe(":"+port, nil))
}' > main.go

# Create multi-stage Dockerfile
# File: Dockerfile
echo '# Build stage - contains compiler and build tools
# This stage is only used for building, not in final image
FROM golang:1.19-alpine AS builder

# Install build dependencies
RUN apk add --no-cache git

WORKDIR /build

# Copy go mod files first for better caching
# COPY go.mod go.sum ./
# RUN go mod download

# Copy source code
COPY main.go .

# Build the binary
# CGO_ENABLED=0 creates static binary
# -ldflags="-s -w" strips debug info for smaller size
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o server main.go

# Production stage - minimal image with just the binary
FROM alpine:latest

# Add ca-certificates for HTTPS connections
RUN apk --no-cache add ca-certificates

# Create non-root user for security
RUN addgroup -g 1000 appuser && \
    adduser -D -u 1000 -G appuser appuser

WORKDIR /app

# Copy only the binary from build stage
# --from=builder references the previous stage
COPY --from=builder --chown=appuser:appuser /build/server .

# Switch to non-root user
USER appuser

# Expose port (informational)
EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=3s \
  CMD wget --no-verbose --tries=1 --spider http://localhost:8080/health || exit 1

# Run the binary
CMD ["./server"]' > Dockerfile

# Build the image
docker build -t go-server:multi .

# Create single-stage Dockerfile for comparison
# File: Dockerfile.single
echo 'FROM golang:1.19-alpine
WORKDIR /app
COPY main.go .
RUN go build -o server main.go
EXPOSE 8080
CMD ["./server"]' > Dockerfile.single

docker build -f Dockerfile.single -t go-server:single .

# Compare image sizes - multi-stage is much smaller!
echo "=== Image Size Comparison ==="
docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}" | grep go-server

# The size difference is dramatic:
# - Single-stage: ~300MB (includes Go compiler, tools)
# - Multi-stage: ~15MB (just binary and Alpine)

# Run the optimized version
docker run -d -p 8080:8080 --name go-app go-server:multi
sleep 2
curl http://localhost:8080
curl http://localhost:8080/health

# Verify it is running as non-root
docker exec go-app whoami

# Clean up
docker rm -f go-app
docker rmi go-server:multi go-server:single
cd ~ && rm -rf ~/multistage-demo
```

### Build Arguments and Environment Variables

Build arguments and environment variables serve different purposes. Build args are only available during build, while env vars are available at runtime:

```bash
# Create project
mkdir -p ~/build-args-demo && cd ~/build-args-demo

# Create application
# File: app.js
echo 'console.log("=== Application Info ===");
console.log("Build Date:", process.env.BUILD_DATE || "unknown");
console.log("Version:", process.env.APP_VERSION || "unknown");
console.log("Environment:", process.env.NODE_ENV || "development");
console.log("Port:", process.env.PORT || "3000");

// Simple HTTP server
const http = require("http");
const server = http.createServer((req, res) => {
  res.writeHead(200, {"Content-Type": "application/json"});
  res.end(JSON.stringify({
    buildDate: process.env.BUILD_DATE,
    version: process.env.APP_VERSION,
    environment: process.env.NODE_ENV,
    port: process.env.PORT
  }));
});

const port = process.env.PORT || 3000;
server.listen(port, () => {
  console.log(`Server running on port ${port}`);
});' > app.js

# Dockerfile with build arguments
# File: Dockerfile
echo '# Build arguments - available during build only
ARG NODE_VERSION=18
ARG BUILD_DATE
ARG APP_VERSION=1.0.0

# Use build arg in FROM
FROM node:${NODE_VERSION}-alpine

# Build args must be redeclared after FROM to use them
ARG BUILD_DATE
ARG APP_VERSION

# Convert build args to env vars (to persist at runtime)
# Build args are not available at runtime unless converted
ENV BUILD_DATE=${BUILD_DATE}
ENV APP_VERSION=${APP_VERSION}
ENV NODE_ENV=production
ENV PORT=3000

# Labels for image metadata
LABEL version="${APP_VERSION}"
LABEL build_date="${BUILD_DATE}"
LABEL description="Demo app showing build args vs env vars"

WORKDIR /app

# Copy application
COPY app.js .

# Show build args during build (for demonstration)
RUN echo "Building version ${APP_VERSION} on ${BUILD_DATE}"

CMD ["node", "app.js"]' > Dockerfile

# Build with default arguments
docker build -t app:default .

# Build with custom arguments
docker build \
  --build-arg NODE_VERSION=16 \
  --build-arg APP_VERSION=2.0.0 \
  --build-arg BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ") \
  -t app:custom .

# Run both versions
echo "=== Default Build ==="
docker run --rm app:default

echo -e "\n=== Custom Build ==="
docker run --rm app:custom

# Override environment variable at runtime
echo -e "\n=== Runtime Override ==="
docker run --rm -e NODE_ENV=development -e PORT=8080 app:custom

# Run as server and test
docker run -d -p 3000:3000 --name app-server app:custom
sleep 2
echo -e "\n=== Server Response ==="
curl http://localhost:3000

# View image labels
echo -e "\n=== Image Labels ==="
docker inspect app:custom --format='{{json .Config.Labels}}' | python3 -m json.tool

# Clean up
docker rm -f app-server
docker rmi app:default app:custom
cd ~ && rm -rf ~/build-args-demo
```

### Container Health Checks

Health checks tell Docker how to test if your container is working correctly. Docker can restart unhealthy containers automatically:

```bash
# Create app with health endpoint
mkdir -p ~/health-demo && cd ~/health-demo

# Create Node.js app with health endpoint
# File: app.js
echo 'const http = require("http");

let healthy = true;
let readyTime = Date.now() + 10000; // Ready after 10 seconds

const server = http.createServer((req, res) => {
  if (req.url === "/health") {
    // Liveness check - is the app running?
    if (healthy) {
      res.writeHead(200);
      res.end("OK");
    } else {
      res.writeHead(503);
      res.end("Service Unavailable");
    }
  } else if (req.url === "/ready") {
    // Readiness check - is the app ready to serve traffic?
    if (Date.now() > readyTime) {
      res.writeHead(200);
      res.end("Ready");
    } else {
      res.writeHead(503);
      res.end("Not Ready");
    }
  } else if (req.url === "/toggle") {
    healthy = !healthy;
    res.writeHead(200);
    res.end(`Health toggled to: ${healthy}\n`);
  } else {
    res.writeHead(200);
    res.end("Application is running\n");
  }
});

server.listen(3000, () => {
  console.log("Server started on port 3000");
  console.log("Endpoints:");
  console.log("  / - Main application");
  console.log("  /health - Liveness check");
  console.log("  /ready - Readiness check");
  console.log("  /toggle - Toggle health status");
});' > app.js

# Dockerfile with health check
# File: Dockerfile
echo 'FROM node:18-alpine

# Install curl for health checks
RUN apk add --no-cache curl

WORKDIR /app
COPY app.js .

# Define health check
# --interval: How often to check
# --timeout: How long to wait for response
# --start-period: Grace period during startup
# --retries: How many failures before marking unhealthy
HEALTHCHECK --interval=10s \
            --timeout=3s \
            --start-period=15s \
            --retries=3 \
  CMD curl -f http://localhost:3000/health || exit 1

EXPOSE 3000
CMD ["node", "app.js"]' > Dockerfile

# Build and run
docker build -t health-app .
docker run -d -p 3000:3000 --name health-demo health-app

# Wait for container to start
echo "Waiting for container to be healthy..."
sleep 15

# Check health status
echo "=== Health Status ==="
docker inspect --format='{{.State.Health.Status}}' health-demo

# Test the endpoints
echo -e "\n=== Testing Endpoints ==="
echo "Main app:"
curl http://localhost:3000
echo "Health check:"
curl http://localhost:3000/health
echo -e "\nReadiness check:"
curl http://localhost:3000/ready

# Toggle health to unhealthy
echo -e "\n=== Making app unhealthy ==="
curl http://localhost:3000/toggle

# Wait and check status again
sleep 15
echo -e "\n=== Health Status After Toggle ==="
docker inspect --format='{{.State.Health.Status}}' health-demo

# View health check history
echo -e "\n=== Health Check History ==="
docker inspect --format='{{json .State.Health}}' health-demo | python3 -m json.tool

# Clean up
docker rm -f health-demo
docker rmi health-app
cd ~ && rm -rf ~/health-demo
```

## Docker Compose: Multi-Container Applications

### Basic Compose Application

Docker Compose simplifies running multi-container applications. Instead of remembering multiple `docker run` commands with all their parameters, you define your entire stack in a YAML file:

```bash
# Create project directory
mkdir -p ~/compose-app && cd ~/compose-app

# Create a Python web application
# File: app.py
echo 'from flask import Flask, render_template_string
import redis
import os
import socket

app = Flask(__name__)

# Connect to Redis
cache = redis.Redis(
    host=os.getenv("REDIS_HOST", "redis"),
    port=6379,
    decode_responses=True
)

@app.route("/")
def hello():
    try:
        visits = cache.incr("counter")
    except redis.RedisError:
        visits = "Cannot connect to Redis"
    
    html = """
    <html>
    <head>
        <title>Docker Compose Demo</title>
        <style>
            body { font-family: Arial; margin: 40px; }
            .info { background: #f0f0f0; padding: 20px; border-radius: 5px; }
        </style>
    </head>
    <body>
        <h1>Hello from Docker Compose!</h1>
        <div class="info">
            <p><strong>Visit Count:</strong> {visits}</p>
            <p><strong>Hostname:</strong> {hostname}</p>
            <p><strong>Environment:</strong> {env}</p>
        </div>
    </body>
    </html>
    """
    
    return html.format(
        visits=visits,
        hostname=socket.gethostname(),
        env=os.getenv("ENVIRONMENT", "development")
    )

@app.route("/health")
def health():
    try:
        cache.ping()
        return "healthy", 200
    except:
        return "unhealthy", 503

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True)' > app.py

# Create requirements
# File: requirements.txt
echo 'flask==2.3.0
redis==4.5.0
werkzeug==2.3.0' > requirements.txt

# Create Dockerfile
# File: Dockerfile
echo 'FROM python:3.9-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

EXPOSE 5000

CMD ["python", "app.py"]' > Dockerfile

# Create docker-compose.yml
# File: docker-compose.yml
echo '
# Services define the containers to run
services:
  # Web application service
  web:
    # Build from Dockerfile in current directory
    build: .
    # Restart policy
    restart: unless-stopped
    # Port mapping - host:container
    ports:
      - "5000:5000"
    # Environment variables
    environment:
      - ENVIRONMENT=production
      - REDIS_HOST=redis
    # Dependencies - wait for redis to start first
    depends_on:
      - redis
    # Mount current directory for development
    volumes:
      - .:/app
    # Connect to custom network
    networks:
      - app-network
    # Health check
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5000/health"]
      interval: 30s
      timeout: 10s
      retries: 3

  # Redis database service
  redis:
    # Use official Redis image
    image: redis:7-alpine
    # Restart policy
    restart: unless-stopped
    # Run Redis with persistence
    command: redis-server --appendonly yes
    # Named volume for data persistence
    volumes:
      - redis-data:/data
    # Connect to custom network
    networks:
      - app-network
    # Health check
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5

# Named volumes
volumes:
  redis-data:
    driver: local

# Custom network for service communication
networks:
  app-network:
    driver: bridge' > docker-compose.yml

# Start the application
# -d runs in background
docker compose up -d

# Wait for services to be healthy
echo "Waiting for services to start..."
sleep 5

# View running services
docker compose ps

# Test the application multiple times
echo "Testing application..."
curl -s http://localhost:5000 | grep "Visit Count"
curl -s http://localhost:5000 | grep "Visit Count"
curl -s http://localhost:5000 | grep "Visit Count"

# View logs from all services
docker compose logs

# View logs from specific service
docker compose logs web

# Follow logs in real-time
# docker compose logs -f

# Execute command in service container
docker compose exec redis redis-cli GET counter

# Scale the web service (create multiple instances)
docker compose up -d --scale web=3

# View scaled services
docker compose ps

# Stop services (containers are not removed)
docker compose stop

# Start services again
docker compose start

# Stop and remove everything
docker compose down

# Remove volumes too
docker compose down -v

# Clean up
cd ~ && rm -rf ~/compose-app
```

## Security Best Practices

### Running as Non-Root User

Running containers as root is a security risk. If an attacker breaks out of your application, they have root access to the container and potentially the host:

```bash
# Create secure app example
mkdir -p ~/secure-app && cd ~/secure-app

# Create Node.js application
# File: app.js
echo 'const http = require("http");
const os = require("os");

const server = http.createServer((req, res) => {
  res.writeHead(200, {"Content-Type": "text/plain"});
  res.end(`Running as:
User ID: ${process.getuid()}
Group ID: ${process.getgid()}
Username: ${os.userInfo().username}
Hostname: ${os.hostname()}
`);
});

const port = process.env.PORT || 3000;
server.listen(port, () => {
  console.log(`Server running on port ${port}`);
  console.log(`User: ${os.userInfo().username} (${process.getuid()})`);
});' > app.js

# Insecure Dockerfile (runs as root)
# File: Dockerfile.insecure
echo 'FROM node:18-alpine

WORKDIR /app
COPY app.js .

EXPOSE 3000
CMD ["node", "app.js"]' > Dockerfile.insecure

# Secure Dockerfile (runs as non-root)
# File: Dockerfile.secure
echo 'FROM node:18-alpine

# Create non-root user and group
# Using specific UID/GID for consistency
RUN addgroup -g 1001 -S nodejs && \
    adduser -S nodejs -u 1001 -G nodejs

# Create app directory and set ownership
RUN mkdir -p /app && chown -R nodejs:nodejs /app

# Set working directory
WORKDIR /app

# Copy files with correct ownership
# --chown flag sets ownership during copy
COPY --chown=nodejs:nodejs app.js .

# Switch to non-root user
USER nodejs

# Expose port (>1024 since non-root cannot bind to privileged ports)
EXPOSE 3000

# Run application
CMD ["node", "app.js"]' > Dockerfile.secure

# Build both versions
docker build -f Dockerfile.insecure -t app:insecure .
docker build -f Dockerfile.secure -t app:secure .

# Run and test both
docker run -d -p 3001:3000 --name insecure-app app:insecure
docker run -d -p 3002:3000 --name secure-app app:secure

sleep 2
echo "=== Insecure app (running as root) ==="
curl http://localhost:3001
echo ""

echo "=== Secure app (running as non-root) ==="
curl http://localhost:3002
echo ""

# Try to write to system directories (will fail in secure container)
echo "=== Testing write permissions ==="
docker exec insecure-app sh -c "touch /etc/test 2>&1 && echo 'Could write to /etc (BAD\!)' || echo 'Cannot write to /etc (expected)'"
docker exec secure-app sh -c "touch /etc/test 2>&1 && echo 'Could write to /etc (BAD\!)' || echo 'Cannot write to /etc (GOOD\!)'"

# Clean up
docker rm -f insecure-app secure-app
docker rmi app:insecure app:secure
cd ~ && rm -rf ~/secure-app
```

### Using .dockerignore

The .dockerignore file prevents unnecessary or sensitive files from being included in your image. This reduces image size and prevents accidental exposure of secrets:

```bash
# Create project with various files
mkdir -p ~/dockerignore-demo && cd ~/dockerignore-demo

# Create application
# File: app.js
echo 'console.log("Application running");' > app.js

# Create various files that should not be in image
echo "node_modules/" > .gitignore
echo "SECRET_KEY=super-secret-key-12345" > .env
echo "DATABASE_PASSWORD=MyP@ssw0rd!" > .env.production
echo "# My Application" > README.md
echo "# TODO: Fix security issue" > TODO.md
mkdir -p node_modules/.bin
echo "module.exports = {}" > node_modules/large-module.js
mkdir -p .git/objects
echo "git data" > .git/objects/abc123
mkdir -p test
echo "test file" > test/test.js

# Create .dockerignore
# File: .dockerignore
echo '# Version control
.git
.gitignore

# Dependencies (will be installed fresh in image)
node_modules
npm-debug.log
yarn-error.log

# Environment files with secrets
.env
.env.*
*.env

# Documentation
*.md
docs/
LICENSE

# Development files
.vscode/
.idea/
*.swp
*.swo
.DS_Store

# Test files
test/
tests/
*.test.js
*.spec.js

# Build artifacts
dist/
build/
*.log

# Temporary files
tmp/
temp/
*.tmp' > .dockerignore

# Create Dockerfile
# File: Dockerfile
echo 'FROM node:18-alpine

WORKDIR /app

# Copy everything (except dockerignored files)
COPY . .

# List files to show what was copied
RUN echo "Files in image:" && \
    ls -la && \
    echo "Checking for files that should be excluded:" && \
    ls .env 2>/dev/null && echo ".env found (BAD!)" || echo ".env not found (good)" && \
    ls -d node_modules 2>/dev/null && echo "node_modules found (BAD!)" || echo "node_modules not found (good)" && \
    ls -d .git 2>/dev/null && echo ".git found (BAD!)" || echo ".git not found (good)" && \
    ls README.md 2>/dev/null && echo "README.md found (BAD!)" || echo "README.md not found (good)"

CMD ["node", "app.js"]' > Dockerfile

# Build image (excluded files will not be copied)
echo "=== Building image with .dockerignore ==="
docker build -t ignore-demo .

# Verify only necessary files were included
echo -e "\n=== Files in the image ==="
docker run --rm ignore-demo ls -la

# Show build context size
echo -e "\n=== Build context size ==="
tar -czf - . | wc -c | awk '{print "With all files: " $1 " bytes"}'
tar -czf - --exclude-from=.dockerignore . | wc -c | awk '{print "With .dockerignore: " $1 " bytes"}'

# Clean up
docker rmi ignore-demo
cd ~ && rm -rf ~/dockerignore-demo
```

## Docker Swarm: Native Orchestration

### Understanding Docker Swarm

Docker Swarm is Docker's built-in clustering and orchestration solution. It turns a group of Docker hosts into a single, virtual Docker host. While Kubernetes has become more popular for large-scale orchestration, Swarm remains valuable for its simplicity and tight Docker integration. Swarm provides:

- **High availability**: Services automatically restart on healthy nodes if a node fails
- **Load balancing**: Requests are distributed across service replicas
- **Rolling updates**: Deploy new versions without downtime
- **Scaling**: Easily scale services up or down
- **Secret management**: Securely distribute sensitive data to services

### Initialize and Manage Swarm

```bash
# Initialize swarm mode
# This node becomes a manager
docker swarm init

# View swarm information
docker info | grep -A 15 "Swarm:"

# View nodes in swarm (just one for now)
docker node ls

# Get join token for workers (in multi-node setup)
docker swarm join-token worker

# Get join token for managers (in multi-node setup)
docker swarm join-token manager
```

### Create and Manage Services

Services are the key abstraction in Swarm. A service defines how containers should run across the swarm:

```bash
# Create a service with 3 replicas
docker service create \
  --name web-service \
  --replicas 3 \
  --publish published=8080,target=80 \
  --mount type=volume,source=web-data,destination=/usr/share/nginx/html \
  --constraint 'node.role==manager' \
  --update-delay 10s \
  --update-parallelism 1 \
  nginx:alpine

# List services
docker service ls

# View service details
docker service inspect web-service --pretty

# View service tasks (individual containers)
docker service ps web-service

# View logs from all service replicas
docker service logs web-service

# Scale service up
docker service scale web-service=5

# View updated tasks
docker service ps web-service

# Update service image (rolling update)
docker service update \
  --image nginx:latest \
  --update-delay 30s \
  --update-parallelism 2 \
  web-service

# Watch rolling update progress
docker service ps web-service

# Rollback to previous version
docker service rollback web-service

# Remove service
docker service rm web-service

# Create service with secrets (for sensitive data)
# First create a secret
echo "MySecretPassword123" | docker secret create db_password -

# Use secret in service
docker service create \
  --name app \
  --secret db_password \
  --env DB_PASSWORD_FILE=/run/secrets/db_password \
  alpine sleep 3600

# Clean up
docker service rm app
docker secret rm db_password

# Leave swarm
docker swarm leave --force
```

## Troubleshooting Guide

### Common Issues and Solutions

Understanding common Docker issues and their solutions saves hours of debugging. Here are the most frequent problems and how to resolve them:

```bash
# === Container won't start ===
# First, always check logs
docker logs <container-name>

# Common causes and solutions:
# 1. Port already in use
netstat -tulpn | grep :8080  # Find what's using port
lsof -i :8080                 # Alternative command
# Solution: Use different port or stop conflicting service

# 2. Image not found
docker images  # Check if image exists locally
docker pull <image-name>  # Pull if missing

# 3. Invalid command or entrypoint
docker inspect <image> | grep -A 5 -E "Cmd|Entrypoint"
# Solution: Override with correct command
docker run <image> /bin/sh  # Override entrypoint

# === Permission denied errors ===
# File ownership issues
docker exec <container> ls -la /problem/directory
# Solution: Fix ownership in Dockerfile
# COPY --chown=user:group source dest

# === Cannot connect to Docker daemon ===
# Check if Docker is running
systemctl status docker       # Linux with systemd
service docker status         # Older Linux
docker version               # Should show client and server

# Restart Docker
sudo systemctl restart docker  # Linux with systemd
sudo service docker restart    # Older Linux

# Check Docker socket permissions
ls -la /var/run/docker.sock
# Solution: Add user to docker group
sudo usermod -aG docker $USER
# Then log out and back in

# === Out of disk space ===
# Check Docker disk usage
docker system df

# Clean up unused resources
docker container prune  # Remove stopped containers
docker image prune     # Remove unused images
docker volume prune    # Remove unused volumes
docker network prune   # Remove unused networks
docker system prune -a # Remove everything unused

# === Container exits immediately ===
# Check exit code
docker ps -a  # Look at STATUS column

# Common exit codes:
# 0: Success (container completed its task)
# 1: General errors
# 125: Docker daemon error
# 126: Container command not executable
# 127: Container command not found

# Debug by keeping container running
docker run -d <image> sleep 3600  # Keep alive for debugging
docker exec -it <container> /bin/sh  # Get shell to investigate

# === DNS resolution issues ===
# Test DNS inside container
docker run --rm alpine nslookup google.com

# Custom DNS servers
docker run --rm --dns 8.8.8.8 --dns 8.8.4.4 alpine nslookup google.com

# Check Docker daemon DNS settings
cat /etc/docker/daemon.json

# === Memory issues ===
# Check if container was OOM killed
docker inspect <container> --format='{{.State.OOMKilled}}'

# Monitor memory usage
docker stats <container>

# === Slow builds ===
# Use build cache effectively
docker build --cache-from <image>:latest -t <image>:new .

# Multi-stage builds for smaller images
# See multi-stage section above

# === Container networking issues ===
# Inspect network configuration
docker network ls
docker network inspect bridge

# Test connectivity between containers
docker exec <container1> ping <container2>

# Check port bindings
docker port <container>
netstat -tulpn | grep docker

# === Debugging running containers ===
# Get shell access
docker exec -it <container> /bin/sh
docker exec -it <container> /bin/bash

# Run commands as root (if container runs as non-root)
docker exec -u 0 <container> command

# Copy files for analysis
docker cp <container>:/path/to/file ./local-file

# === View container processes ===
docker top <container>

# === Inspect container filesystem changes ===
docker diff <container>  # Shows what files changed
```

## Quick Command Reference

### Essential Docker Commands

Here's a comprehensive reference of the most important Docker commands organized by category:

```bash
# === Image Commands ===
docker pull <image>:<tag>           # Download image from registry
docker images                        # List all local images
docker image ls                      # Same as above
docker rmi <image>                   # Remove image
docker image rm <image>              # Same as above
docker build -t <name>:<tag> .       # Build image from Dockerfile
docker build -f <file> -t <n> .      # Build from specific Dockerfile
docker history <image>               # Show image layers and commands
docker inspect <image>               # Display detailed image information
docker tag <source> <target>         # Create image tag/alias
docker push <image>                  # Push image to registry
docker save <image> > file.tar       # Export image to tar file
docker load < file.tar               # Import image from tar file
docker image prune                   # Remove unused images
docker image prune -a                # Remove all unused images

# === Container Commands ===
docker run <image>                   # Create and start container
docker run -d <image>                # Run in background (detached)
docker run -it <image> /bin/sh       # Run with interactive shell
docker run --rm <image>              # Remove container after exit
docker run --name <n> <image>        # Run with specific name
docker run -p 8080:80 <image>        # Map port host:container
docker run -v /host:/container <img> # Mount volume
docker run -e VAR=value <image>      # Set environment variable
docker run --memory=256m <image>     # Set memory limit
docker run --cpus=0.5 <image>        # Set CPU limit

docker ps                            # List running containers
docker ps -a                         # List all containers
docker ps -q                         # List only container IDs

docker stop <container>              # Stop container gracefully
docker start <container>             # Start stopped container
docker restart <container>           # Restart container
docker pause <container>             # Pause container processes
docker unpause <container>           # Resume container processes
docker kill <container>              # Force stop container

docker rm <container>                # Remove stopped container
docker rm -f <container>             # Force remove running container
docker container prune               # Remove all stopped containers

docker logs <container>              # View container logs
docker logs -f <container>           # Follow logs (tail -f)
docker logs --tail 50 <container>    # Last 50 lines
docker logs --since 10m <container>  # Logs from last 10 minutes

docker exec <container> <command>    # Run command in container
docker exec -it <container> /bin/sh  # Interactive shell in container
docker exec -u 0 <container> <cmd>   # Run as root user

docker cp <src> <container>:<dest>   # Copy to container
docker cp <container>:<src> <dest>   # Copy from container

docker inspect <container>           # Display detailed info
docker stats                         # Show resource usage (live)
docker stats --no-stream             # Show resource usage (snapshot)
docker top <container>               # Show running processes
docker diff <container>              # Show filesystem changes
docker port <container>              # Show port mappings

# === Volume Commands ===
docker volume create <name>          # Create named volume
docker volume ls                     # List volumes
docker volume rm <name>              # Remove volume
docker volume inspect <name>         # Display volume details
docker volume prune                  # Remove unused volumes

# === Network Commands ===
docker network create <name>         # Create network
docker network ls                    # List networks
docker network rm <name>             # Remove network
docker network inspect <name>        # Display network details
docker network connect <net> <cnt>   # Connect container to network
docker network disconnect <net> <cnt># Disconnect from network
docker network prune                 # Remove unused networks

# === Docker Compose Commands ===
docker compose up                    # Start services
docker compose up -d                 # Start in background
docker compose up --build            # Rebuild images and start
docker compose down                  # Stop and remove services
docker compose down -v               # Also remove volumes
docker compose ps                    # List services
docker compose logs                  # View all logs
docker compose logs <service>        # View specific service logs
docker compose logs -f               # Follow logs
docker compose exec <service> <cmd>  # Run command in service
docker compose build                 # Build/rebuild images
docker compose pull                  # Pull images
docker compose restart               # Restart services
docker compose stop                  # Stop services
docker compose start                 # Start services
docker compose config                # Validate compose file
docker compose top                   # Display running processes

# === System Commands ===
docker system df                     # Show disk usage
docker system prune                  # Remove unused data
docker system prune -a --volumes     # Remove ALL unused data
docker system info                   # Display system info
docker info                          # Same as above
docker version                       # Show Docker version
docker events                        # Monitor Docker events

# === Registry Commands ===
docker login                         # Log in to Docker Hub
docker login <registry>              # Log in to specific registry
docker logout                        # Log out from registry
docker search <term>                 # Search Docker Hub
docker pull <registry>/<image>       # Pull from specific registry
docker push <registry>/<image>       # Push to specific registry

# === Swarm Commands (Orchestration) ===
docker swarm init                    # Initialize swarm
docker swarm join                    # Join swarm as worker/manager
docker swarm leave                   # Leave swarm
docker swarm leave --force           # Force leave (manager)

docker service create <options>      # Create service
docker service ls                    # List services
docker service ps <service>          # List service tasks
docker service logs <service>        # View service logs
docker service scale <svc>=<num>     # Scale service
docker service update <service>      # Update service
docker service rm <service>          # Remove service

docker node ls                       # List swarm nodes
docker node inspect <node>           # Inspect node
docker node update <node>            # Update node
docker node rm <node>                # Remove node

# === Useful Combinations ===
# Remove all containers
docker rm $(docker ps -aq)

# Remove all images
docker rmi $(docker images -q)

# Stop all containers
docker stop $(docker ps -q)

# Follow logs with timestamps
docker logs -ft <container>

# Export container filesystem
docker export <container> > container.tar

# Import as image
docker import container.tar <image>

# View image layers with size
docker history --human --no-trunc <image>

# Run temporary container for testing
docker run --rm -it alpine /bin/sh

# Debug network issues
docker run --rm --network <net> alpine ping <container>

# Backup volume
docker run --rm -v <volume>:/data -v $(pwd):/backup alpine tar czf /backup/backup.tar.gz -C /data .

# Restore volume
docker run --rm -v <volume>:/data -v $(pwd):/backup alpine tar xzf /backup/backup.tar.gz -C /data
```