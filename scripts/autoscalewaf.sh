#!/bin/bash

ARGS=`getopt -o r:v:u:p:s:m:w: --long resourceGroup:,vmssName:,userName:,password:,azureSecretFile:,managementPort:,wafScriptArgs: -n $0 -- "$@"`
eval set -- "$ARGS"
# Parse the command line arguments
while true; do
    case "$1" in
        -r|--resourceGroup)
            resource_group=$2
            shift 2;;
        -v|--vmssName)
            vmss_name=$2
            shift 2;;
        -u|--userName)
            user=$2
            shift 2;;
        -p|--password)
            passwd_file=$2
            shift 2;;
        -s|--azureSecretFile)
            azure_secret_file=$2
            shift 2;;
        -m|--managementPort)
            mgmt_port=$2
            shift 2;;
        -w|--wafScriptArgs)
            waf_script_args=$2
            shift 2;;
        --)
            shift
            break;;
    esac
done
echo "WAF_SCRIPT: $waf_script_args"

# Need to ensure we can get to metadata service
route | grep "169.254.169.254" | grep "internal"
if [[ $? != 0 ]]; then
     echo "Creating metadata service route: 169.254.169.254"
     dfl_gw=`tmsh list net route | grep "route default" -C 4 | grep gw | grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}'`
     route add -net 169.254.169.254 netmask 255.255.255.255 gw $dfl_gw internal
else
    echo "Metadata service route already exists"
fi
dfl_mgmt_port=`tmsh list sys httpd ssl-port | grep ssl-port | sed 's/ssl-port //;s/ //g'`
self_ip=$(tmsh list net self self_1nic address | grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}')
instance=`curl http://169.254.169.254/metadata/v1/InstanceInfo --silent --retry 5 | jq .ID | sed 's/_//;s/\"//g'`

# Add check/loop in case metadata service does not respond right away
count=0
while [ $count -lt 5 ]; do
    if [[ -z $instance ]]; then
        sleep 5
        instance=`curl http://169.254.169.254/metadata/v1/InstanceInfo --silent --retry 5 | jq .ID | sed 's/_//;s/\"//g'`
    fi
    count=$(( $count + 1 ))
done
echo "INSTANCE NAME CHOSEN: $instance"
# Add check/loop for self_ip in case BIG-IP is not finished provisioning 1 NIC
count=0
while [ $count -lt 10 ]; do
    if [[ -z $self_ip ]]; then
        sleep 5
        self_ip=`tmsh list net self self_1nic address | grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}'`
    fi
    count=$(( $count + 1 ))
done
echo "SELF IP CHOSEN: $self_ip"

f5-rest-node /config/cloud/node_modules/f5-cloud-libs/scripts/azure/runScripts.js --base-dir /config/cloud/node_modules/f5-cloud-libs --log-level debug --onboard "--output /var/log/onboard.log --log-level debug --host $self_ip --port $dfl_mgmt_port --ssl-port $mgmt_port -u $user --password-url file://$passwd_file --hostname $instance.azuresecurity.com --db provision.1nicautoconfig:disable --db tmm.maxremoteloglength:2048 --module ltm:nominal --module asm:nominal --module afm:none --signal ONBOARD_DONE" --autoscale "--wait-for ONBOARD_DONE --output /var/log/autoscale.log --log-level debug --host $self_ip --port $mgmt_port -u $user --password-url file://$passwd_file --cloud azure --provider-options scaleSet:$vmss_name,azCredentialsUrl:file://$azure_secret_file,resourceGroup:$resource_group --cluster-action join --device-group Sync --block-sync"

if [ -f /config/cloud/master ]; then
    echo 'SELF-SELECTED as Master ... Initiating Autoscale Cluster'

    # UCS Loaded?
    ucs_loaded=`cat /config/cloud/master | jq .ucsLoaded`
    echo "UCS Loaded: $ucs_loaded"

    # Create iCall, first check if it already exists
    icall_handler_name="ClusterUpdateHandler"
    tmsh list sys icall handler | grep $icall_handler_name
    if [[ $? != 0 ]]; then
        tmsh create sys icall script ClusterUpdate definition { exec f5-rest-node /config/cloud/node_modules/f5-cloud-libs/scripts/azure/runScripts.js --base-dir /config/cloud/node_modules/f5-cloud-libs --log-level debug --autoscale "--cloud azure --log-level debug --output /var/log/azure-autoscale.log --host $self_ip --port $mgmt_port --user $user --password-url file://$passwd_file --provider-options scaleSet:$vmss_name,azCredentialsUrl:file://$azure_secret_file,resourceGroup:$resource_group --cluster-action update --device-group Sync" }
        tmsh create sys icall handler periodic /Common/$icall_handler_name { first-occurrence now interval 300 script /Common/ClusterUpdate }
        tmsh save /sys config
    else
        echo "Appears the $icall_handler_name icall already exists!"
    fi

    # Deploy the WAF Application if master and ucs loaded equals false
	if $ucs_loaded; then
        echo "NOTE: We are not deploying any WAF applications as a UCS was loaded, and it takes precedence."
    else
        /usr/bin/f5-rest-node /config/cloud/node_modules/f5-cloud-libs/scripts/azure/runScripts.js --base-dir /config/cloud/node_modules/f5-cloud-libs --script " --output /var/log/deployScript.log --log-level debug --file /var/lib/waagent/custom-script/download/0/deploy_waf.sh --cl-args '$waf_script_args' --signal DEPLOY_SCRIPT_DONE "
    fi

    # Unblock the cluster sync
    f5-rest-node /config/cloud/node_modules/f5-cloud-libs/scripts/autoscale.js --output /var/log/autoscale.log --log-level debug --host $self_ip --port $mgmt_port -u $user --password-url file://$passwd_file --cloud azure --provider-options scaleSet:$vmss_name,azCredentialsUrl:file://$azure_secret_file,resourceGroup:$resource_group --cluster-action unblock-sync
fi



if [[ $? == 0 ]]; then
    echo "AUTOSCALE INIT SUCCESS"
else
    echo "AUOTSCALE INIT FAIL"
    exit 1
fi
exit
