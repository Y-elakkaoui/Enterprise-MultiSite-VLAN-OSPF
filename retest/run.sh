#!/usr/bin/env bash
# Concept retest: the same addressing and design, with FRRouting and Linux bridges
# instead of Cisco routers. PC3 moves to a new VLAN 60 so that it has a gateway at HQ.
set -uo pipefail
cd "$(dirname "$0")"
mkdir -p evidence

PASS=0; FAIL=0
check() { # check "<description>" <command...>
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "PASS  $d"; PASS=$((PASS+1)); else echo "FAIL  $d"; FAIL=$((FAIL+1)); fi
}
check_not() { # check_not "<description>" <command...>
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "FAIL  $d"; FAIL=$((FAIL+1)); else echo "PASS  $d"; PASS=$((PASS+1)); fi
}
finish() { echo; echo "Result: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; }

sudo apt-get update -qq && sudo apt-get install -y -qq iptables >/dev/null
IMAGE=quay.io/frrouting/frr:10.2.1
ns() { local n="$1"; shift; sudo ip netns exec "$n" "$@"; }
sudo mkdir -p /var/run/netns

for r in r1 r2; do
  docker run -d --name $r --privileged --network none \
    -v "$PWD/$r.conf:/etc/frr/frr.conf:ro" $IMAGE \
    sh -c "sed -i 's/^ospfd=no/ospfd=yes/' /etc/frr/daemons; /usr/lib/frr/docker-start" >/dev/null
  sudo ln -sf /proc/$(docker inspect -f '{{.State.Pid}}' $r)/ns/net /var/run/netns/$r
  ns $r sysctl -qw net.ipv4.ip_forward=1
done
for n in hqsw brsw pc1 pc2 pc3 srv branch guest; do sudo ip netns add $n; ns $n ip link set lo up; done
for s in hqsw brsw; do
  ns $s ip link add br0 type bridge vlan_filtering 1
  ns $s ip link set br0 up
done

access() { # access <switch> <pc> <vlan> <addr/len> <gateway>
  sudo ip link add v-$2 type veth peer name p-$2
  sudo ip link set v-$2 netns $2; sudo ip link set p-$2 netns $1
  ns $1 ip link set p-$2 master br0; ns $1 ip link set p-$2 up
  ns $1 bridge vlan del dev p-$2 vid 1
  ns $1 bridge vlan add dev p-$2 vid $3 pvid untagged
  ns $2 ip addr add $4 dev v-$2; ns $2 ip link set v-$2 up
  ns $2 ip route add default via $5
}
trunk() { # trunk <switch> <router> <vlans...> : router-on-a-stick
  local s=$1 r=$2; shift 2
  sudo ip link add t-$r type veth peer name p-$r
  sudo ip link set t-$r netns $r; sudo ip link set p-$r netns $s
  ns $s ip link set p-$r master br0; ns $s ip link set p-$r up
  ns $r ip link set t-$r up
  for v in "$@"; do
    ns $s bridge vlan add dev p-$r vid $v
    ns $r ip link add link t-$r name t-$r.$v type vlan id $v
    ns $r ip addr add 192.168.$v.1/24 dev t-$r.$v
    ns $r ip link set t-$r.$v up
  done
}
trunk hqsw r1 10 20 50 60
trunk brsw r2 30 40
access hqsw pc1 10 192.168.10.10/24 192.168.10.1
access hqsw pc2 20 192.168.20.10/24 192.168.20.1
access hqsw pc3 60 192.168.60.10/24 192.168.60.1
access hqsw srv 50 192.168.50.10/24 192.168.50.1
access brsw branch 30 192.168.30.20/24 192.168.30.1
access brsw guest 40 192.168.40.10/24 192.168.40.1
sudo ip link add wan1 type veth peer name wan2
sudo ip link set wan1 netns r1; sudo ip link set wan2 netns r2
ns r1 ip addr add 10.0.0.1/30 dev wan1; ns r1 ip link set wan1 up
ns r2 ip addr add 10.0.0.2/30 dev wan2; ns r2 ip link set wan2 up
ns r1 ip -br addr > evidence/r1-interfaces.txt
ns r2 ip -br addr > evidence/r2-interfaces.txt

for i in $(seq 1 30); do
  docker exec r2 vtysh -c 'show ip ospf neighbor' 2>/dev/null | grep -q Full && break
  sleep 5
done
docker exec r2 vtysh -c 'show ip ospf neighbor' | tee evidence/ospf-neighbor.txt
docker exec r2 vtysh -c 'show ip route ospf' | tee evidence/ospf-routes.txt
docker exec r1 vtysh -c 'show ip route ospf' >> evidence/ospf-routes.txt

reach() { ns "$1" ping -c 2 -W 2 "$2"; }
web() { ns "$1" curl -s -o /dev/null -m 4 "http://192.168.50.10:$2/"; }
ns srv sh -c 'cd /tmp && nohup python3 -m http.server 53 >/dev/null 2>&1 & cd /tmp && nohup python3 -m http.server 80 >/dev/null 2>&1 &'
sleep 2

exec > >(tee evidence/results.txt) 2>&1
echo "== Routing and connectivity, no ACLs yet"
{
  check "OSPF adjacency reaches Full"           grep -q Full evidence/ospf-neighbor.txt
  check "PC3 reaches its gateway in VLAN 60"    reach pc3 192.168.60.1
  check "PC1 reaches PC2 (inter-VLAN at HQ)"    reach pc1 192.168.20.10
  check "PC1 reaches Branch-PC (between sites)" reach pc1 192.168.30.20
  check "PC3 reaches Branch-PC (between sites)" reach pc3 192.168.30.20
  check "Without ACLs, Guest-PC reaches PC1"    reach guest 192.168.10.10
  check "Without ACLs, Guest-PC reaches the server on port 80" web guest 80
}

# ACLs: isolate the guest network, and allow only DNS to the server zone
ns r2 iptables -A FORWARD -i t-r2.40 -d 192.168.0.0/16 -j DROP
ns r2 iptables -A FORWARD -i t-r2.40 -d 10.0.0.0/8 -j DROP
ns r1 iptables -A FORWARD -d 192.168.50.0/24 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
ns r1 iptables -A FORWARD -d 192.168.50.0/24 -p tcp --dport 53 -j ACCEPT
ns r1 iptables -A FORWARD -d 192.168.50.0/24 -p udp --dport 53 -j ACCEPT
ns r1 iptables -A FORWARD -d 192.168.50.0/24 -j DROP
{ ns r1 iptables -S FORWARD; ns r2 iptables -S FORWARD; } > evidence/acl-rules.txt

{
  echo
  echo "== With ACLs"
  check_not "Guest-PC can no longer reach PC1"       reach guest 192.168.10.10
  check_not "Guest-PC can no longer reach Branch-PC" reach guest 192.168.30.20
  check_not "Guest-PC can no longer reach the server" web guest 53
  check "PC1 still reaches Branch-PC"                reach pc1 192.168.30.20
  check "PC1 reaches the server on the DNS port (TCP 53)" web pc1 53
  check_not "PC1 is blocked from the server on port 80"   web pc1 80
}
docker logs r1 > evidence/r1.log 2>&1 || true
finish
RC=$?
sleep 1
exit "$RC"
