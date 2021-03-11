FROM php:7.4-apache
LABEL maintainer="Pizaini <instagram.com/pizaini>"

#Copy php.ini
COPY docker/php-apache/conf/php.ini "$PHP_INI_DIR/php.ini"

#Enable necessary mods
RUN ln -s /etc/apache2/mods-available/rewrite.load /etc/apache2/mods-enabled/rewrite.load
RUN ln -s /etc/apache2/mods-available/headers.load /etc/apache2/mods-enabled/headers.load

#Install extension
RUN apt-get update && apt-get install -y libmcrypt-dev openssl supervisor locales zip unzip libpng-dev
RUN docker-php-ext-install -j$(nproc) bcmath gd mysqli pdo_mysql
RUN docker-php-ext-enable pdo_mysql