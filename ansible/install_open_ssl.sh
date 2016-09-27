#!/bin/bash
# roles/openssl/files/install.sh

cd /usr/local/src/
wget https://www.openssl.org/source/openssl-1.0.2-latest.tar.gz

tar -zxf openssl-1.0.2-latest.tar.gz
cd openssl-1.0.2*/

./config
make
make test
make install

mv /usr/bin/openssl /root/
ln -s /usr/local/ssl/bin/openssl /usr/bin/openssl
openssl version
