========================================
       Port 443 Inspection
========================================

[1] Listening on port 443
----------------------------------------
State  Recv-Q Send-Q Local Address:Port Peer Address:Port
LISTEN 0      4096         0.0.0.0:443       0.0.0.0:*   
LISTEN 0      4096            [::]:443          [::]:*   

[2] Process owning port 443
----------------------------------------
State  Recv-Q Send-Q Local Address:Port Peer Address:PortProcess                                  
LISTEN 0      4096         0.0.0.0:443       0.0.0.0:*    users:(("docker-proxy",pid=515120,fd=7))
LISTEN 0      4096            [::]:443          [::]:*    users:(("docker-proxy",pid=515128,fd=7))

[3] HAProxy configuration
----------------------------------------
Cannot read /etc/haproxy/haproxy.cfg

[4] Common reverse-proxy processes
----------------------------------------
515062 traefik traefik

[5] HAProxy frontend/bind configuration
----------------------------------------
HAProxy configuration cannot be read.

========================================
Result
========================================
IPv4 :443 is LISTENING
IPv6 :443 is LISTENING
Owner: Cannot determine without elevated permissions.
