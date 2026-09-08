# Never gets the router back to a state it could be redeployed from.
/interface bridge
add name=lan
/interface bridge port
add bridge=lan interface=ether1
