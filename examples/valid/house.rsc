# A whole small network, with everything it takes to reach the router again
# first.
/interface bridge
add name=lan
add name=wan protocol-mode=none
/interface bridge port
add bridge=lan interface=ether2
add bridge=wan interface=ether3
/ip address
add address=192.168.99.1/24 interface=lan network=192.168.99.0
/ip dhcp-client
add interface=wan
/ip pool
add name=pool0 ranges=192.168.99.100-192.168.99.200
/ip dhcp-server
add address-pool=pool0 interface=lan name=dhcp1
/ip dhcp-server network
add address=192.168.99.0/24 gateway=192.168.99.1 dns-server=192.168.99.10,8.8.8.8

# From here on, anything that fails costs only itself.
/ip dhcp-server lease
add address=192.168.99.10 mac-address=aa:aa:aa:aa:aa:aa server=dhcp1 comment="server"
add address=192.168.99.11 mac-address=bb:bb:bb:bb:bb:bb server=dhcp1 comment="desktop"
add address=192.168.99.12 mac-address=cc:cc:cc:cc:cc:cc server=dhcp1 comment="laptop"
/ip service
set telnet address=192.168.99.0/24
set ftp address=192.168.99.0/24
set www address=192.168.99.0/24
set ssh address=192.168.99.0/24
/ip firewall filter
add action=accept chain=input in-interface=lan
add action=fasttrack-connection chain=forward
/ip firewall nat
add action=masquerade chain=srcnat out-interface=wan
add action=dst-nat chain=dstnat dst-port=80 protocol=tcp to-addresses=192.168.99.10 comment="http"
add action=dst-nat chain=dstnat dst-port=443 protocol=tcp to-addresses=192.168.99.10 comment="https"
add action=dst-nat chain=dstnat dst-port=2222 protocol=tcp to-addresses=192.168.99.11 to-ports=22 comment="ssh to the desktop"
/ipv6 settings
set accept-router-advertisements=yes
/ipv6 dhcp-client
add add-default-route=yes interface=wan pool-name=v6pool pool-prefix-length=56 request=address,prefix
/ipv6 address
add address=::1 from-pool=v6pool interface=lan
/ipv6 firewall filter
add action=accept chain=forward connection-state=established,related in-interface=wan out-interface=lan
add action=drop chain=forward in-interface=wan out-interface=lan
