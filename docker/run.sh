#!/bin/bash

function usage {
  echo >&2 "usage: $0 [--doc] [--sso] [--api] [--workbench] [--keep]"
  echo >&2 "If no switches are given, the default is to start all servers."
}

if [[ "$ENABLE_SSH" != "" ]]; then
  EXTRA=" -e ENABLE_SSH=$ENABLE_SSH"
else
  EXTRA=''
fi

start_doc=false
start_sso=false
start_api=false
start_workbench=false
start_keep=false

while [ $# -ge 1 ]
do
    case $1 in
	--doc)
	    start_doc=true
	    ;;
	--sso)
	    start_sso=true
	    ;;
	--api)
	    start_api=true
	    ;;
	--workbench)
	    start_workbench=true
	    ;;
	--keep)
	    start_keep=true
	    ;;
	*)
	    usage
	    exit 1
	    ;;
    esac
    shift
done

# If no options were selected, then start all servers.
if $start_doc || $start_sso || $start_api || $start_workbench || $start_keep
then
    :
else
    start_doc=true
    start_sso=true
    start_api=true
    start_workbench=true
    start_keep=true
fi

function ip_address {
  local container=$1
  echo `docker inspect $container  |grep IPAddress |cut -f4 -d\"`
}

function start_container {
  local port="-p $1"
  if [[ "$2" != '' ]]; then
    local name="-name $2"
  fi
  if [[ "$3" != '' ]]; then
    local volume="-v $3"
  fi
  if [[ "$4" != '' ]]; then
    local link="-link $4"
  fi
  local image=$5

  `docker ps |grep -P "$2[^/]" -q`
  if [[ "$?" == "0" ]]; then
    echo "You have a running container with name $2 -- skipping."
    return
  fi

  echo "Starting container:"
  echo "  docker run -d -i -t$EXTRA $port $name $volume $link $image"
  container=`docker run -d -i -t$EXTRA $port $name $volume $link $image`
  if [[ "$?" != "0" ]]; then
    echo "Unable to start container"
    exit 1
  fi
  if [[ $EXTRA ]]; then
    ip=$(ip_address $container )
    echo
    echo "You can ssh into the container with:"
    echo
    echo "    ssh root@$ip"
    echo
  fi
}

function make_keep_volume {
  # Mount a keep volume if we don't already have one
  local keepvolume=""
  for mountpoint in $(cut -d ' ' -f 2 /proc/mounts); do
    if [[ -d "$mountpoint/keep" && "$mountpoint" != "/" ]]; then
      keepvolume=$mountpoint
    fi
  done

  if [[ "$keepvolume" == '' ]]; then
    keepvolume=$(mktemp -d)
    echo "mounting 512M tmpfs keep volume in $keepvolume"
    sudo mount -t tmpfs -o size=512M tmpfs $keepvolume
    mkdir $keepvolume/keep
  fi
  echo "$keepvolume"
}

$start_doc && start_container "9898:80" "doc_server" '' '' "arvados/doc"
$start_sso && start_container "9901:443" "sso_server" '' '' "arvados/sso"
$start_api && start_container "9900:443" "api_server" '' "sso_server:sso" "arvados/api"
$start_workbench && start_container "9899:80" "workbench_server" '' "api_server:api" "arvados/workbench"

keepvolume=$(make_keep_volume)
$start_keep && start_container "25107:25107" "keep_server_0" "$keepvolume:/dev/keep-0" '' "arvados/warehouse"
$start_keep && start_container "25108:25107" "keep_server_1" "$keepvolume:/dev/keep-0" '' "arvados/warehouse"
