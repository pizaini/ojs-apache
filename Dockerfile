FROM php:7.4-apache
LABEL maintainer="Pizaini <instagram.com/pizaini>"

ENV OJS_VERSION 3.3.0-8
ENV APACHE_DOCUMENT_ROOT /var/www/html
ENV APACHE_RUN_DIR /var/run/apache2
ENV APACHE_PID_FILE /var/run/apache2/httpd.pid
ENV APACHE_RUN_USER www-data
ENV APACHE_RUN_GROUP www-data
ENV APACHE_LOG_DIR /var/www/html

#Copy php.ini and SSL
COPY docker/php-apache/conf/php.ini "$PHP_INI_DIR/php.ini"
COPY docker/ssl/localhost.crt "$APACHE_CONFDIR/ssl/ssl.crt"
COPY docker/ssl/localhost.key "$APACHE_CONFDIR/ssl/ssl.key"

#Copy config files
COPY docker/php-apache/conf/000-default.conf "$APACHE_CONFDIR/sites-available/"
COPY docker/php-apache/conf/apache2.conf $APACHE_CONFDIR

#Enable necessary mods
RUN ln -s /etc/apache2/mods-available/rewrite.load /etc/apache2/mods-enabled/rewrite.load
RUN ln -s /etc/apache2/mods-available/headers.load /etc/apache2/mods-enabled/headers.load
RUN a2enmod rewrite

#Install extension
RUN apt-get update && apt-get install -y libmcrypt-dev openssl zip unzip libpng-dev
RUN docker-php-ext-install -j$(nproc) bcmath gd mysqli pdo_mysql gettext
RUN docker-php-ext-enable pdo_mysql

WORKDIR /var/www/html
EXPOSE 443
#Copy and chmod run.sh
COPY docker/run.sh /run.sh
RUN chmod +x /run.sh
ENTRYPOINT ["/run.sh"]