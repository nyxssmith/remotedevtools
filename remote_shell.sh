#!/bin/bash
# try to replace shell with new one iff
# found on local network, do ssh
# found via public ip if set
# else keep existing shell

# if remote shell is working, then run a port checker in background that forwards all docker ports to localhost
# ex if remote is running port 8080 via docker, forward it to local so localhost:8080 = remote:8080

# SETTINGS
REMOTE_LOCAL_IP=192.168.68.151
REMOTE_PUBLIC_IP=192.168.68.150
REMOTE_USERNAME="nyx"
SSH_KEY=$(pwd)/id_rsa
PORT_FORWARDER_CHECK_INTERVAL_SECONDS=10

# VARS
CAN_REACH=1
PORT_FORWARDING_PIDS=()
PORTS_FORWARDED_ON_REMOTE=()
PORTS_FORWARDED_TO_LOCAL=()
# current PID so doesnt kill any other shells children
PID=""
# TODO uuid for runfile for multiple shells at once
BACKGROUND_RUN_FILE=$(pwd)/runfile


# check if can reach remote system via local IP
check_remote_local() {
    ssh -o ConnectTimeout=1 -i $SSH_KEY $REMOTE_USERNAME@$REMOTE_LOCAL_IP ls > /dev/null
    echo $?
}

# check if can reach remote system via public IP
check_remote_public() {
    ssh -o ConnectTimeout=1 -i $SSH_KEY $REMOTE_USERNAME@$REMOTE_PUBLIC_IP ls > /dev/null
    echo $?
}


# runs on local system checking for open docker ports on remote system
# if it finds a new one, calls forward_port
port_forwarder() {
    #while [ 1 ]; do
    while [ -f "$BACKGROUND_RUN_FILE" ]; do
        sleep $PORT_FORWARDER_CHECK_INTERVAL_SECONDS
        #echo "background"

        # update both lists
        # get list of ports currently forwarded by docker on remote
        get_list_of_docker_port_forwards_on_remote_system
        # get list of ports forwared to the local system
        get_list_of_docker_port_forwards_on_local_system

        # for each in list, if not in list currently forwarded, forward it
        
        # check if ports need to be forwared
        for port in "${PORTS_FORWARDED_ON_REMOTE[@]}"
        do
            # echo "port on remote $port"
            containsElement "$port" "${PORTS_FORWARDED_TO_LOCAL[@]}"
            PORT_NEEDS_TO_BE_FORWARDED=$?
            if [ $PORT_NEEDS_TO_BE_FORWARDED -ne 0 ]; then
                echo "$port needs to be forwared"
                port_forward $port
            fi
        done

        # for each in list of forwarded ports check they are currently used by docker on remote, if not then kill its pid
        for port in "${PORTS_FORWARDED_TO_LOCAL[@]}"
        do
            #echo "port on local $port"
            containsElement "$port" "${PORTS_FORWARDED_ON_REMOTE[@]}"
            PORT_NEEDS_TO_BE_FORWARDED=$?
            #echo "fwd on remote containers $port $PORT_NEEDS_TO_BE_FORWARDED"
            if [ $PORT_NEEDS_TO_BE_FORWARDED -eq 1 ]; then
                # echo "needs to be forwared"
                pid=$(get_pid_for_forwarded_port $port)
                #echo "need to kill $pid for port $port"
                if [ ! -z "$pid" ]; then
                    # TODO rm from list of port forwarding pids
                    kill $pid
                fi
            fi
        done
    done

    kill_all_port_forwarding_pids
}


get_pid_for_forwarded_port() {
    # $1 is port to find
    echo $(ps -ef | grep ssh | grep localhost | grep $1 | tr -s " " | cut -d' ' -f2)
    # TODO macOS or os specific here for `ps` 
}

port_forward() {
    # $1 is port to forward

    # check if port is already forwarded via PS, could be done by other process
    #echo "forwarding $1"
    # create port forward
    ssh -fNT -L$1:localhost:$1 -i $SSH_KEY $REMOTE_USERNAME@$REMOTE_LOCAL_IP > /dev/null 2&>1
    # add the pid to the list of owned pid
    #echo "PID for port $1 is "$(get_pid_for_forwarded_port $1)
    PORT_FORWARDING_PIDS+=($(echo "$(get_pid_for_forwarded_port $1)"))
    PORTS_FORWARDED_TO_LOCAL+=("$1")


}

get_list_of_docker_port_forwards_on_remote_system() {
    PORTS_FORWARDED_ON_REMOTE=()
    # for all lines in docker ps on remote system
    # trim to just the ones that have 0.0.0.0:port on remote system->port in container
    # then get just the port on remote system
    # if that worked and port is set, append to list
    while IFS=',' read -ra LINE; do
        for i in "${LINE[@]}"; do
            port=$(echo $i | grep "0.0.0.0" | grep "\->" | cut -d'-' -f1 | cut -d':' -f2)
            echo "port on remote $port"
            if [ ! -z "$port" ]; then
                PORTS_FORWARDED_ON_REMOTE+=("$port")
                echo "added port to list"
            fi
        done
    done <<< $(ssh -i $SSH_KEY $REMOTE_USERNAME@$REMOTE_LOCAL_IP 'docker ps --format "{{.Ports}}"')
}

get_list_of_docker_port_forwards_on_local_system() {
    PORTS_FORWARDED_TO_LOCAL=()
    # get output of ps -ef on the remote system
    PS_EF_REMOTE=$(ssh -i $SSH_KEY $REMOTE_USERNAME@$REMOTE_LOCAL_IP "ps -ef")
    # get just the ssh forwared ports
    SSH_FORWARDED_PORTS=$(echo "$PS_EF_REMOTE" | grep ssh | grep localhost | grep fNT | tr -s " " | cut -d' ' -f10 | cut -d':' -f3)
    # add ssh forwarded ports to the ports forwarded already
    while IFS=',' read -ra port; do
        # ensure only got ports just in case
        re='^[0-9]+$'
        if [[ $port =~ $re ]] ; then
            PORTS_FORWARDED_TO_LOCAL+=("$port")
        fi
    done <<< $(echo "$SSH_FORWARDED_PORTS")
}


kill_all_port_forwarding_pids() {
    for pid in "${PORT_FORWARDING_PIDS[@]}"
    do
        echo "killing $pid"
        kill $pid
    done
}


containsElement () {
    local e match="$1"
    shift
    for e; do [[ "$e" == "$match" ]] && return 0; done
    return 1
}


local_shell() {
    echo "local"
    bash
}

remote_shell() {
    ssh -i $SSH_KEY $REMOTE_USERNAME@$REMOTE_LOCAL_IP 
}


# main logic entrypoint here
PID=$$
if [ $(check_remote_local) -ne 0 ]; then
    if [ $(check_remote_public) -ne 0 ]; then
        echo "Cant reach remote system"
    else
        CAN_REACH=0
    fi
else
    CAN_REACH=0
fi


if [ $CAN_REACH -eq 0 ]; then

    touch $BACKGROUND_RUN_FILE
    # start port forwarder
    port_forwarder &
    # save its pid in list
    PORT_FORWARDING_PIDS+=("$!")
    echo "Port forwarder started with PID $PORT_FORWARDER_PID"

    remote_shell
    rm $BACKGROUND_RUN_FILE
    sleep 10

fi


exit 0
# (sleep 2; echo "subsh 1")&
remote_shell

REMOTE_SHELL_PID=$!
(local_shell)&
LOCAL_SHELL_PID=$!

echo "r"$REMOTE_SHELL_PID
echo "l"$LOCAL_SHELL_PID
echo "topsh"