# Installs the SoftLayer CLI
# pip install --upgrade pip
# pip install softlayer

UCP_PREFIX=ucp-
DTR_PREFIX=dtr-
NODE_PREFIX=node-
HOSTS=/tmp/ansible-hosts
TEMP_FILE=/tmp/deploy-ddc.out

# This var is not used anymore
TIMEOUT=600
PORT_SPEED=10

. ./docker-ddc.cfg

# Need to determine operating system for certain SL CLI commands
PLATFORM_TYPE=$(uname)

# Set the server type
if [ $SERVER_TYPE  == "bare" ]; then
  SERVER_MESSAGE="bare metal server"
  CLI_TYPE=server
  SPEC="--size $SIZE --port-speed $PORT_SPEED --os CENTOS_7_64"
  STATUS_FIELD="status"
  STATUS_VALUE="ACTIVE"
else
  SERVER_MESSAGE="virtual server"
  CLI_TYPE=vs
  SPEC="--cpu $CPU --memory $MEMORY --os CENTOS_LATEST"
  STATUS_FIELD="state"
  STATUS_VALUE="RUNNING"
fi

# Args: $1: VLAN number
function get_vlan_id {
   VLAN_ID=`slcli vlan list | grep $1 | awk '{print $1}'`
}

# Args: $1: label $2: VLAN number
function build_vlan_arg {
  if [ -z $2 ]; then
    VLAN_ARG=""
  else
     get_vlan_id $2
     VLAN_ARG="$1 $VLAN_ID"
  fi
}

# Args: $1: name
function create_server {
  # Creates the machine
  echo "Creating $1 with $CPU cpu(s) and $MEMORY GB of RAM"
  TEMP_FILE=/tmp/create-vs.out
  build_vlan_arg "--vlan-private" $PRIVATE_VLAN
  PRIVATE_ARG=$VLAN_ARG
  build_vlan_arg "--vlan-public" $PUBLIC_VLAN
  PUBLIC_ARG=$VLAN_ARG

  echo "Deploying $SERVER_MESSAGE $1"
  yes | slcli $CLI_TYPE create --hostname $1 --domain $DOMAIN $SPEC --datacenter $DATACENTER --billing hourly  $PRIVATE_ARG $PUBLIC_ARG | tee $TEMP_FILE
}

# Args: $1: name
function get_server_id {
  # Extract virtual server ID
  slcli $CLI_TYPE list --hostname $1 --domain $DOMAIN | grep $1 > $TEMP_FILE

  # Consider only the first returned result
  VS_ID=`head -1 $TEMP_FILE | awk '{print $1}'`
}

# Args: $1: name
function create_node {
  # Check whether ucp exists
  slcli $CLI_TYPE list --hostname $1 --domain $DOMAIN | grep $1 > $TEMP_FILE
  COUNT=`wc $TEMP_FILE | awk '{print $1}'`

  # Determine whether to create the machine
  if [ $COUNT -eq 0 ]; then
  create_server $1
  else
  echo "$1 already created"
  fi

  get_server_id $1

  # Wait machine to be ready
  while true; do
    echo "Waiting for $SERVER_MESSAGE $1 to be ready..."
    STATE=`slcli $CLI_TYPE detail $VS_ID | grep $STATUS_FIELD | awk '{print $2}'`
    if [ "$STATE" == "$STATUS_VALUE" ]; then
      break
    else
      sleep 5
    fi
  done
}

# Arg $1: hostname
function obtain_root_pwd {
  get_server_id $1

  # Obtain the root password
  slcli $CLI_TYPE detail $VS_ID --passwords > $TEMP_FILE

  # Remove "remote users"
  # it seems that for Ubuntu it's print $4; however, for Mac, it's print $3
  if [ $SERVER_TYPE == "bare" ]; then
    PASSWORD=`grep root $TEMP_FILE | grep -v "remote users" | awk '{print $3}'`
  elif [ $PLATFORM_TYPE == "Linux" ] || [ $FORCE_LINUX == "true" ]; then
    PASSWORD=`grep root $TEMP_FILE | grep -v "remote users" | awk '{print $4}'`
  elif [ $PLATFORM_TYPE == "Darwin" ]; then
    PASSWORD=`grep root $TEMP_FILE | grep -v "remote users" | awk '{print $3}'`
  fi
  echo PASSWORD $PASSWORD
}

# Args $1: hostname
function obtain_ip {
  echo Obtaining IP address for $1
  get_server_id $1
  # Obtain the IP address
  slcli $CLI_TYPE detail $VS_ID --passwords > $TEMP_FILE

  if [ $CONNECTION  == "VPN" ]; then
    IP_ADDRESS=`grep private_ip $TEMP_FILE | awk '{print $2}'`
  else
    IP_ADDRESS=`grep public_ip $TEMP_FILE | awk '{print $2}'`
  fi
}

function update_hosts_file {
  # Update ansible hosts file
  echo Updating ansible hosts files
  echo > $HOSTS
  echo "[ucp-primary]" >> $HOSTS
  obtain_ip ${UCP_PREFIX}1
  export UCP1_IP=$IP_ADDRESS
  echo "${UCP_PREFIX}1 ansible_host=$IP_ADDRESS ansible_user=root" >> $HOSTS


  echo "[ucp-secondary]" >> $HOSTS
  for(( x=2; x <= ${NUM_UCPS}; x++))
  do
    obtain_ip "${UCP_PREFIX}${x}"
    export UCP_${x}_IP=$IP_ADDRESS
    echo "${UCP_PREFIX}${x} ansible_host=$IP_ADDRESS ansible_user=root" >> $HOSTS
  done

  echo "[dtr-primary]" >> $HOSTS
  obtain_ip ${DTR_PREFIX}1
  export DTR1_IP=$IP_ADDRESS
  echo "${DTR_PREFIX}1 ansible_host=$IP_ADDRESS ansible_user=root" >> $HOSTS

  echo "[dtr-secondary]" >> $HOSTS
  ## Echoes in the format of "dtr-1 ansible_host=$IP_ADDRESS ansible_user=root" >> $HOSTS
  for(( x=2; x <= ${NUM_DTRS}; x++))
  do
    obtain_ip "${DTR_PREFIX}${x}"
    export DTR_${x}_IP=$IP_ADDRESS
    echo "${DTR_PREFIX}${x} ansible_host=$IP_ADDRESS ansible_user=root" >> $HOSTS
  done

  echo "[node]" >> $HOSTS
  for(( x=1; x <= ${NUM_NODES}; x++))
  do
    obtain_ip "${NODE_PREFIX}${x}"
    export NODE_${x}_IP=$IP_ADDRESS
    echo "${NODE_PREFIX}${x} ansible_host=$IP_ADDRESS ansible_user=root" >> $HOSTS
  done

}

#Args: $1: PASSWORD, $2: IP Address
function set_ssh_key {
  #Remove entry from known_hosts
  ssh-keygen -R $2

  # Log in to the machine

  sshpass -p $1 ssh-copy-id -o 'StrictHostKeyChecking=no' root@$2
}

#Args: $1: hostname $2: IP address
function configure_ucp {
  # Get ucp password
  obtain_root_pwd $1

  # Set the SSH key
  set_ssh_key $PASSWORD $2

  # Create inventory file
  INVENTORY=/tmp/inventory
  echo > $INVENTORY
  echo "[ucps]" >> $INVENTORY
  ## Echoes in the format of "$NODE1_IP" >> $INVENTORY
  for(( x=1; x <= ${NUM_UCPS}; x++))
  do
    TMP1=$(echo \${NODE${x}_IP})
    LOCAL_IP=$(eval echo ${TMP1})
    echo "${LOCAL_IP}" >> ${INVENTORY}
  done


  echo "[dtrs]" >> $INVENTORY
  ## Echoes in the format of "$NODE1_IP" >> $INVENTORY
  for(( x=1; x <= ${NUM_DTRS}; x++))
  do
    TMP1=$(echo \${NODE${x}_IP})
    LOCAL_IP=$(eval echo ${TMP1})
    echo "${LOCAL_IP}" >> ${INVENTORY}
  done

  # Create ansible.cfg
  ANSIBLE_CFG=/tmp/ansible.cfg
  echo "[defaults]" > $ANSIBLE_CFG
  echo "host_key_checking = False" >> $ANSIBLE_CFG

}

function configure_ucp_primary {
  configure_ucp ${UCP_PREFIX}1 $UCP1_IP

  # Execute kube-master playbook
echo UCP License file: $UCP_LICENSE_FILE
  ansible-playbook -v -i $HOSTS ansible/ucp-primary.yaml  -e ucp_license_file=$UCP_LICENSE_FILE
}

# Args $1 Node name
function configure_node {
  echo Configuring node $1

  # Get ucp password
  obtain_root_pwd $1

  # Get master IP address
  obtain_ip $1
  NODE_IP=$IP_ADDRESS
  echo IP Address: $NODE_IP

  # Set the SSH key
  set_ssh_key $PASSWORD $NODE_IP
}

function configure_ucp_secondaries {
  for(( x=2; x <= ${NUM_DTRS}; x++))
  do
    obtain_ip "${UCP_PREFIX}${x}"
    configure_node "${UCP_PREFIX}${x}"
  done

  # Execute kube-master playbook
  ansible-playbook -v -i $HOSTS ansible/ucp-secondary.yaml --extra-vars "url=https://$UCP1_IP"
}

function configure_ucps {
  # Execute kube-master playbook
  ansible-playbook -v -i $HOSTS ansible/ucps.yaml
}


function configure_dtr_primary {
echo Configuring primary DTR
configure_node "${DTR_PREFIX}1"

# Execute dtr-primary playbook
ansible-playbook -i $HOSTS ansible/dtr-primary.yaml --extra-vars "url=https://$UCP1_IP domain=$DOMAIN"
}

function configure_dtr_secondaries {
  echo Configuring other DTRs
  for(( x=2; x <= ${NUM_DTRS}; x++))
  do
    configure_node "${DTR_PREFIX}${x}"
  done

  # Execute dtr-secondary playbook
  ansible-playbook -i $HOSTS ansible/dtr-secondary.yaml --extra-vars "url=https://$UCP1_IP domain=$DOMAIN"
}

function configure_nodes {
  echo Configuring nodes
  for(( x=1; x <= ${NUM_NODES}; x++))
  do
    configure_node "${NODE_PREFIX}${x}"
  done

  # Execute node playbook
  ansible-playbook -i $HOSTS ansible/node.yaml --extra-vars "url=https://$UCP1_IP domain=$DOMAIN"
}



#Args $1: number $2: prefix
function create_machines {
  for(( x=1; x <= $1; x++))
  do
    create_node "$2${x}"
  done
}


function create_dtrs {
  create_machines ${NUM_DTRS} ${DTR_PREFIX}
}

function create_ucps {
  create_machines ${NUM_UCPS} ${UCP_PREFIX}
}

function create_nodes {
  create_machines ${NUM_NODES} ${NODE_PREFIX}
}



# Authenticates to SL
echo "[softlayer]" > ~/.softlayer
echo "username = $USER" >> ~/.softlayer
echo "api_key = $API_KEY" >> ~/.softlayer
echo "endpoint_url = $ENDPOINT" >> ~/.softlayer
echo "timeout = 0" >> ~/.softlayer

echo Using the following SoftLayer configuration
slcli config show

create_ucps
create_dtrs
create_nodes

update_hosts_file

configure_ucp_primary
configure_ucp_secondaries
configure_ucps
configure_dtr_primary
configure_dtr_secondaries
configure_nodes

echo "Congratulations! You can log in to your Docker Data Center environment at https://$UCP1_IP using admin/orca"


