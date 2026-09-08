# One serial port on this chassis, so there is no /port 1 to name. It fails
# while running, so the line after it never happens.
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
/port
set 1 name=serial1
/interface bridge
add name=neverreached
