docker build -t ml8s/fe:v1 -f src/images/Dockerfile.fe .
docker run --rm ml8s/fe:v2

docker build -t ml8s/train:v1 -f src/images/Dockerfile.train .
docker run --rm ml8s/train:v2
