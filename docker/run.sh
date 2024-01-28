#!/bin/bash
set -e
if [ "$(ls -A /var/www/html)" ]
  then
    echo "Web already exist..."
  else
    echo "Web data does not exist. Downloading new OJS and extract it..."
    curl https://pkp.sfu.ca/ojs/download/ojs-${OJS_VERSION}.tar.gz -o ojs3.tar.gz
    mkdir /ojs-download
    tar -xzf ojs3.tar.gz -C /ojs-download
    cp -r /ojs-download/ojs-${OJS_VERSION}/* /var/www/html/
    rm ojs3.tar.gz
fi

#Create OJS data if not exist
mkdir -p /var/www/ojs-data

#change directory owner
echo "Change directory owner..."
chown www-data:www-data -R /var/www/html
chown www-data:www-data -R /var/www/ojs-data

echo "Change directory permissions..."
# Set all to 750
chmod 750 -R /var/www/html
chmod 750 -R /var/www/ojs-data

# set 640 for writable with no execution
if [ -e /var/www/html/config.inc.php ]
then
    chmod 640 /var/www/html/config.inc.php
fi

#start services
echo "Start services..."
supervisord -c /etc/supervisor/conf.d/supervisord.conf