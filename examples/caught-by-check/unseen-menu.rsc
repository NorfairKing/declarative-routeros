# /interface wireless is not in this router's export, so this router may not
# have that menu. A menu RouterOS does not have is a compile error, and
# compiling happens before running, so none of the lines above it apply either.
/interface bridge
add name=lan
/interface bridge port
add bridge=lan interface=ether2
add bridge=lan interface=ether3
/ip address
add address=192.168.99.1/24 interface=lan network=192.168.99.0
/ip pool
add name=pool0 ranges=192.168.99.2-192.168.99.254
/ip dhcp-server
add address-pool=pool0 interface=lan name=dhcp1
/ip dhcp-server network
add address=192.168.99.0/24 gateway=192.168.99.1
/interface wireless security-profiles
set [ find default=yes ] supplicant-identity=MikroTik
