docker run -d -p 9000:9000 -p 9001:9001 \
--name minio \
-e "MINIO_ROOT_USER=minioadmin" \
-e "MINIO_ROOT_PASSWORD=minioadmin123" \
-v /mnt/data:/data \
quay.io/minio/minio server /data --console-address ":9001"

git clone https://github.com/yandex-cloud/csi-s3.git
cd csi-s3/deploy/kubernetes
kubectl apply -f .

https://kubernetes-csi.github.io/docs/node-driver-registrar.html