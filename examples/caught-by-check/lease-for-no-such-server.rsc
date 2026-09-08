# A lease for a dhcp server nothing creates. A server is never hardware, so
# there is nowhere else it could have come from.
/interface bridge
add name=lan
/interface bridge port
add bridge=lan interface=ether2
/ip address
add address=192.168.99.1/24 interface=lan network=192.168.99.0
/ip pool
add name=pool0 ranges=192.168.99.2-192.168.99.254
/ip dhcp-server
add address-pool=pool0 interface=lan name=dhcp1
/ip dhcp-server network
add address=192.168.99.0/24 gateway=192.168.99.1
/ip dhcp-server lease
add address=192.168.99.10 mac-address=aa:aa:aa:aa:aa:aa server=dhcp2
