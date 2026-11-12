# A command written on the line of its menu is checked like any other, and it
# leaves the lines after it in the menu that was open before it.
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
/ip firewall filter add action=fasttrack-connection chain=forward hw-offload=yes
add address=192.168.99.0/24 gateway=192.168.99.1
