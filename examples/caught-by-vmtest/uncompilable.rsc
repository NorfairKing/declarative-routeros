# An action RouterOS does not have. The parameter name is one this router
# knows, so no export reveals this; only something that compiles the file
# does. Compiling happens before running, so nothing at all is applied.
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
/ip firewall filter
add action=notanaction chain=input
