FROM php:7.4-apache
LABEL maintainer="Pizaini <instagram.com/pizaini>"

ENV APACHE_DOCUMENT_ROOT=/var/www/html
#Copy php.ini and SSL
COPY docker/php-apache/conf/php.ini "$PHP_INI_DIR/php.ini"
COPY docker/ssl/localhost.crt /etc/apache2/ssl/ssl.crt
COPY docker/ssl/localhost.key /etc/apache2/ssl/ssl.key

#Copy config files
COPY docker/php-apache/conf/000-default.conf /etc/apache2/sites-available/
COPY docker/php-apache/conf/apache2.conf /etc/apache2/

#Enable necessary mods
RUN ln -s /etc/apache2/mods-available/rewrite.load /etc/apache2/mods-enabled/rewrite.load
RUN ln -s /etc/apache2/mods-available/headers.load /etc/apache2/mods-enabled/headers.load
RUN ln -s /etc/apache2/mods-available/ssl.load /etc/apache2/mods-enabled/ssl.load

#Install extension
RUN apt-get update && apt-get install -y libmcrypt-dev openssl zip unzip libpng-dev
RUN docker-php-ext-install -j$(nproc) bcmath gd mysqli pdo_mysql gettext
RUN docker-php-ext-enable pdo_mysql

EXPOSE 443
CMD ["chown", "-R", "www-data:www-data", "/var/www"]
CMD ["apache2-foreground"]