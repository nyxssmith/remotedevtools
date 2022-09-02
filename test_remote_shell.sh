#!/bin/bash

#starts a docker container to act as a remote system for remote shell script testing

name="remoteshelltest"

docker build -f dockerfile.test_remote_shell -t $name .

docker run --name $name --rm -it -v $(pwd)/remote_shell.sh:/home/user/remote_shell.sh:z -v $(pwd)/id_rsa:/home/user/id_rsa:z $name 