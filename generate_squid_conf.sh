#!/bin/bash

# Input and output files
PROXY_FILE="proxy.txt"
SQUID_CONF="squid.conf"

# Base configuration for squid.conf
cat > $SQUID_CONF <<EOL
# Port on which Squid listens
http_port 3128

# Limit the memory used for cache in RAM
cache_mem 32 MB

# Disable disk cache (optional)
# If you don't want to use disk cache, comment or remove this line
# cache_dir ufs /var/spool/squid 100 16 256

# List of external proxies with round-robin rotation
EOL

# Read the proxy.txt file and generate the configurations
while IFS=: read -r username password ip port
do
    echo "cache_peer $ip parent $port 0 no-query round-robin login=$username:$password" >> $SQUID_CONF
    echo "cache_peer_access $ip allow all" >> $SQUID_CONF
done < $PROXY_FILE

# Add ACL and access directives to the squid.conf file
cat >> $SQUID_CONF <<EOL

# Define an ACL for all traffic
acl all src 0.0.0.0/0

# Allow traffic through the external proxies
# Block direct access
never_direct allow all

# Allow HTTP access
http_access allow all

# Logs
access_log /var/log/squid/access.log squid
cache_log /var/log/squid/cache.log

# Directory for core dumps
coredump_dir /var/spool/squid
EOL

echo "File $SQUID_CONF generated successfully."
