#!/usr/bin/env bash
dir=$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )

set -ex

source "${dir}/../../examples/kubernetes/env-kube.sh"

TEST_NET="cilium"
NETPERF_IMAGE="noironetworks/netperf"
K8S_PATH="/home/vagrant/kubernetes"

function start_k8s {
    if [ ! -d "${K8S_PATH}" ]; then
        exit 1
    fi
    echo "Starting kubernetes..."
    "${K8S_PATH}/hack/local-up-cluster.sh" &
}

function cleanup {
    echo "Cleaning up"
    sleep 3s
    sudo killall -9 etcd || true
    sudo killall -9 kubelet || true
    sudo killall -9 kube-scheduler || true
    sudo killall -9 kube-controller-manager || true
    sudo killall -9 kube-proxy || true
    sudo killall -9 kube-apiserver || true
    docker rm -f `docker ps -aq --filter=name=k8s` 2> /dev/null || true
    if [ -e "/etc/init/cilium-net-daemon.conf.bak" ]; then
        sudo mv "/etc/init/cilium-net-daemon.conf.bak" "/etc/init/cilium-net-daemon.conf"
        sudo service cilium-net-daemon restart
        sleep 3s
    fi
}

function reset_trace {
    if [ -d "/sys/kernel/debug/tracing/" ]; then
        sudo cp /dev/null /sys/kernel/debug/tracing/trace
    fi
}

function abort {
    echo "$*"
    echo "Tracing output:"
    sudo cat /sys/kernel/debug/tracing/trace
    exit 1
}

trap cleanup EXIT
sudo cp "/etc/init/cilium-net-daemon.conf" "/etc/init/cilium-net-daemon.conf.bak"
sudo su -c 'echo "exec cilium -D daemon -d eth1 --disable-policy" > /etc/init/cilium-net-daemon.conf'
sudo service cilium-net-daemon restart
sleep 3s

reset_trace

start_k8s

sudo cilium -D policy import "${dir}/policy"

"${dir}/../../examples/kubernetes/1-dns.sh" 300
"${dir}/../../examples/kubernetes/2-guestbook.sh" 300
"${dir}/wait-for-docker.sh" k8s_guestbook 100
"${dir}/wait-for-docker.sh" k8s_redis-slave 100
"${dir}/wait-for-docker.sh" k8s_redis-master 100

docker exec -ti `docker ps -aq --filter=name=k8s_guestbook` sh -c 'sleep 60 && ping6 -c 5 redis-master' || {
    abort "Unable to ping redis-slave"
}

sudo cilium -D policy delete io.cilium
