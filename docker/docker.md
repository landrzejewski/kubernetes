Get help for a command
```
docker help ps
```
List available images
```
docker images
```
Pull an image into the local image store (REGISTRYHOST:PORT/USERNAME/NAME:TAG)
```
docker pull landrzejewski/echo-server
```
Run a container
```
docker run [--name] [--detach] busybox echo "Hello"
```
List running containers
```
docker ps
```
List all containers, including stopped ones
```
docker ps -a
```
Stop a container
```
docker stop id/name
```
Remove a stopped container
```
docker rm id/name
```
Remove all containers
```
docker rm $(docker ps -a -q)
```
Run a container with port forwarding
```
docker run -p 8080:8080 landrzejewski/echo-server
```
Show logs
```
docker logs id/name
```
Run a process in a running container
```
docker exec [-it] id/name command
```
Restart a container
```
docker restart id/name
```
Create a container without starting it
```
docker create [--cidfile file-name] image
```
Start a created container
```
docker start id/name 
```
Show container details
```
docker inspect id/name
```
Export an image to a tar file
```
docker save -o file-name.tar image-name:tag
```
Remove an image from the local image store
```
docker rmi id/name
```
Import an image into the local image store
```
docker load -i file-name.tar
```
Run a container image registry
```
docker run -d -p 5000:5000 --restart always --name registry registry:2
```
Add a tag/alias to an image
```
docker tag image-name registry-host:port/image-name
```
Push an image to a remote registry
```
docker push registry-host:port/image-name
```
Pull an image from a remote registry
```
docker pull registry-host:port/image-name
```
Mount a volume (bind type)
```
docker run -p 8080:8080 --mount type=bind,src=/home/k8s/data,dst=/app/data,readonly=true landrzejewski/echo-server
```
Mount a volume (tmpfs type)
```
docker run -p 8080:8080 --mount type=tmpfs,dst=/app/data landrzejewski/echo-server
```
Set environment variables / configure a container from the outside
```
docker run -p 5432:5432 \
    -e POSTGRES_DB=training \
    -e POSTGRES_USER=admin \
    -e POSTGRES_PASSWORD=admin \
    -e PGDATA=/var/lib/postgresql/data/pgdata \
    --mount type=bind,src=/home/k8s/data/db,dst=/var/lib/postgresql/data/pgdata \
    postgres
```
Create a named volume
```
docker volume create --driver local --label training storage
```
```
docker volume inspect storage
```
```
docker run -p 5432:5432 \
    -e POSTGRES_DB=training \
    -e POSTGRES_USER=admin \
    -e POSTGRES_PASSWORD=admin \
    -e PGDATA=/var/lib/postgresql/data/pgdata \
    --volume storage:/var/lib/postgresql/data/pgdata \
    postgres
```
Create a network
```
docker network create \
    --driver bridge \
    --subnet 10.0.1.0/24 \
    --attachable \
    training
```
```
docker run -p 8080:8080 --network training landrzejewski/echo-server
```
```
docker network create \
    --driver bridge \
    --subnet 10.0.2.0/24 \
    --attachable \
    training2
```
```
docker network connect training2 70e5472bffd4
```
Create an image by working inside a container and modifying an existing image
```
docker run -d landrzejewski/echo-server
```
```
docker exec -it id/name sh
```
Make changes (e.g. install additional packages), then save the result as a new image
```
docker container commit id/name new_image_name
```
Build an image from a Dockerfile
```
docker image build --tag landrzejewski/echo .
```
Services (Docker Swarm)
```
docker swarm init
```
```
docker swarm join --token SWMTKN-1-60racgd05909k8iq873t43x6cjn0397nq2lqxj1sidqxg6z159-45wzkndc3ejsub3a0wpkmn7iq 192.168.1.100:2377
```
```
docker service create -p 8080:8080 --name echo-server landrzejewski/echo-server
```
```
docker service ps echo-server
```
```
docker service scale echo-server=3
```
```
docker service update --image landrzejewski/echo-server:v1 --update-order stop-first --update-parallelism 1 --update-delay 30s echo-server
```
Services (declarative)
```
docker compose up [service-name]
```
```
docker compose down
```
```
docker stack deploy --compose-file docker-compose.yml my-stack
```
```
docker stack rm my-stack
```
```
docker build --platform linux/x86_64 --tag landrzejewski/platform .
```
