# An item that is not there. Every word compiles and the selector is only
# looked up when the import runs, so everything above this applies and
# everything below it does not. Nothing about the words of a file can show
# this, and nothing about the chassis: what is missing is an item.
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
/ip service
set nosuchservice address=192.168.99.0/24
/interface bridge
add name=neverreached
