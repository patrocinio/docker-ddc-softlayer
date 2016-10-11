echo Cleaning the SoftLayer API Key
cp docker-ddc.cfg ~
TEMP_FILE=/tmp/docker-ddc.cfg
sed 's/\(API_KEY=\).*/\1/' docker-ddc.cfg > $TEMP_FILE
mv $TEMP_FILE docker-ddc.cfg


