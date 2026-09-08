# hw-offload= is only a word on a chassis whose switch can offload, and no
# export of this router names it. Where it is not a word it will not compile,
# and takes the whole file with it.
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
add action=fasttrack-connection chain=forward hw-offload=yes
