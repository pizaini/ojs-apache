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
#Set all directory default as 750
find /var/www/html -type d -exec chmod 750 {} \;

#Set all files default as 640
find /var/www/html -type f -exec chmod 640 {} \;

#start services
echo "Start services..."
supervisord -c /etc/supervisor/conf.d/supervisord.conf