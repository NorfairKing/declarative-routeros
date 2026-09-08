# For the deployment tool, which talks ssh and so has to still be able to
# reach the router after the reset: hence a dhcp client on ether1, in the half
# that is paired with the reset. Not one of ../valid, because a router that
# already has a client on that interface refuses to add a second, and the vm
# that imports over its own console has one.
/interface bridge
add name=lan
/interface bridge port
add bridge=lan interface=ether2
add bridge=lan interface=ether3
/ip dhcp-client
add interface=ether1
/ip address
add address=192.168.99.1/24 interface=lan network=192.168.99.0
/ip pool
add name=pool0 ranges=192.168.99.2-192.168.99.254
/ip dhcp-server
add address-pool=pool0 interface=lan name=dhcp1
/ip dhcp-server network
add address=192.168.99.0/24 gateway=192.168.99.1
# In the half that is paired with the reset, along with the dhcp server that
# hands them out, which is what this example is here to hold still.
/ip dhcp-server lease
add address=192.168.99.10 mac-address=aa:aa:aa:aa:aa:aa server=dhcp1 comment="the one that is expected here"
add address=192.168.99.11 mac-address=bb:bb:bb:bb:bb:bb server=dhcp1 comment="and another"
/ip firewall filter
add action=accept chain=input
