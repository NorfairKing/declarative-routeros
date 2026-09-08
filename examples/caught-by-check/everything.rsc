# A script with many problems at once, so that a report of several of them is
# read by something other than a person who has just written one.
/interface ethernet
set [ find default-name=sfp28-2 ] fec-mode=off
/port
set 0 name=serial0
/ip address
add address=192.168.88.1/24 interface=lan
/interface bridge port
add bridge=lan interface=ether1
add bridge=lan interface=ether1
/ip dhcp-server network
add address=192.168.88.0/24 gateway=192.168.88.1
/ip dhcp-server lease
add address=192.168.88.1 mac-address=11:11:11:11:11:11 comment="collides with the router"
add address=192.168.88.3 mac-address=	84:78:48:1E:0A:41 comment="tab in the mac"
add address=192.168.88.4 mac-address=aa:bb:cc:dd:ee:ff comment="fine"
add address=192.168.88.4 mac-address=11:22:33:44:55:66 comment="duplicate address"
add address=192.168.88.5 mac-address=aa:bb:cc:dd:ee:ff comment="duplicate mac"
add address=192.168.88.999 mac-address=22:33:44:55:66:77 comment="not an address"
add mac-address=33:44:55:66:77:88 comment="no address"
add address=192.168.88.6 comment="no mac"
/ip firewall nat
add action=dst-nat chain=dstnat dst-port=99 protocol=tcp to-addresses=192.168.88.222
add action=dst-nat chain=dstnat dst-port=98 protocol=tcp to-addresses=192.168.88.4
add action=dst-nat chain=dstnat dst-port=98 protocol=tcp to-addresses=192.168.88.4
/interface bridge
add name=lan
/ip pool
add name=pool ranges=192.168.88.100-192.168.88.200
/ip dhcp-server
add address-pool=pool interface=lan name=dhcp
