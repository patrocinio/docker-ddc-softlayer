# Installs the SoftLayer CLI
#pip install --upgrade pip
#pip install softlayer

. ./docker-ddc.cfg

echo Using the following SoftLayer configuration
slcli config show

# Set the server type
if [ $SERVER_TYPE  == "bare" ]; then
  CLI_TYPE=server
else
  CLI_TYPE=vs
fi


# Creates the kube master
slcli $CLI_TYPE list --domain $DOMAIN






