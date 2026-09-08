# An address from a pool with no host part, in each of the ways of spelling
# one. The command succeeds and the router keeps working; only everything
# behind it stops.
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
/ipv6 address
add from-pool=v6pool interface=lan
add address=::0 from-pool=v6pool interface=lan
add address=0:0:0:0:0:0:0:0 from-pool=v6pool interface=lan
