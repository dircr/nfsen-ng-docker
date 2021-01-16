#!/bin/bash
# avoid process container restart when updating sources.conf
cp /tmp/sources.conf /tmp/sources.set
# read source.set and start a background [sn]fcap process for each source
cat /tmp/sources.set | while read ln; do
    command=""
    read -r host port protocol <<< $(echo $ln | awk -F ';' '{print $1 " " $2 " " substr($3,1,1)}')
    mkdir -p /data/live/$host && command="${protocol}fcapd -I $host -l /data/live/$host  -w -S 1 -T all -p $port"
    if [ -z "$command" ]; then 
        echo >&2 "Error creating directory /data/live/$host"
        exit 1
    else
        echo '$' $command
        $command &
        sleep 0.1
    fi
    if [ $? -ne 0 ]; then 
        echo >&2 "Startup interrupted !"
        exit
    fi
done
sleep 1
echo "Ready"
while true; do
    sleep 60; 
    cat /tmp/sources.set | while read ln; do
        read -r host port protocol <<< $(echo $ln | awk -F ';' '{print $1 " " $2 " " substr($3,1,1)}')
        command="${protocol}fcapd -I $host -l /data/live/$host  -w -S 1 -T all -p $port"
        ps aux| grep '\s'$host'\s' > /dev/null || { echo >&2 "Missing process for $host (port $port)"; exit 1; }
    done
    if [ $? -ne 0 ]; then 
        echo >&2 "Restarting..."
        break
    fi
done
