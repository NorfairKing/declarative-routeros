# An annotation left behind by something that has since been downloaded: the
# router has been seen to accept every word of the line under it.
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
# [untried] the router has never been asked to accept anything on input.
add action=accept chain=input in-interface=ether1
