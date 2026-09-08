# An export of the small router these examples are for, which is how the check
# knows which words it accepts: the router printed these itself. Verbose, so
# every parameter appears at its default, and a name missing from here is a
# name this RouterOS does not have rather than one it has no use for.
#
# No /interface wireless and no hw-offload: a radio-less chassis whose switch
# cannot offload. That is what caught-by-check/unseen-menu.rsc and
# unseen-parameter.rsc are examples of.
/interface bridge
add ageing-time=5m arp=enabled auto-mac=yes disabled=no fast-forward=yes \
    mtu=auto name=lan protocol-mode=rstp vlan-filtering=no
/interface ethernet
set [ find default-name=ether1 ] advertise="" arp=enabled auto-negotiation=yes \
    disabled=no fec-mode=auto l2mtu=1598 mtu=1500 name=ether1
/interface bridge port
add bridge=lan disabled=no interface=ether2 pvid=1
/interface list
add exclude="" include="" name=all
/ip pool
add name=pool0 ranges=192.168.99.2-192.168.99.254
/ip dhcp-server
add address-pool=pool0 disabled=no interface=lan lease-time=10m name=dhcp1
/ip address
add address=192.168.99.1/24 disabled=no interface=lan network=192.168.99.0
/ip dhcp-client
add add-default-route=yes disabled=no interface=ether1 use-peer-dns=yes
/ip dhcp-server lease
add address=192.168.99.10 comment="" disabled=no mac-address=00:00:00:00:00:01 \
    server=dhcp1
/ip dhcp-server network
add address=192.168.99.0/24 dns-server=192.168.99.1 gateway=192.168.99.1 \
    name="" netmask=0
/ip firewall filter
add action=accept chain=input disabled=no in-interface=ether1 log=no
/ip firewall nat
add action=masquerade chain=srcnat comment="" disabled=no dst-port="" \
    log=no out-interface=ether1 protocol="" to-addresses="" to-ports=""
/ip service
set api address="" disabled=yes port=8728
/ipv6 settings
set accept-redirects=yes-if-forwarding-disabled accept-router-advertisements=yes
/ipv6 address
add address=::1 advertise=yes disabled=no from-pool="" interface=lan no-dad=no
/ipv6 dhcp-client
add add-default-route=no disabled=no interface=ether1 pool-name="" \
    pool-prefix-length=64 request=address
/ipv6 firewall filter
add action=accept chain=forward connection-state="" disabled=no \
    in-interface=ether1 log=no out-interface=lan
/port
set 0 baud-rate=auto data-bits=8 name=serial0 parity=none
/system identity
set name=MikroTik
