docker run -d --name silo -p 9000:9000 -p 9001:9001 \
-e MINIO_ROOT_USER=minioadmin \
-e MINIO_ROOT_PASSWORD=minioadmin123 \
-v "$PWD/data:/data" \
docker.io/pgsty/silo:RELEASE.2026-10-26T00-00-00Z server /data --console-address ":9001"

git clone https://github.com/yandex-cloud/k8s-csi-s3.git
cd k8s-csi-s3/deploy/kubernetes
kubectl apply -f .

https://kubernetes-csi.github.io/docs/node-driver-registrar.html