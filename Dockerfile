FROM php:8.3-apache
MAINTAINER pizaini <github.com/pizaini>

ENV OJS_VERSION 3.5.0-1
ENV APACHE_DOCUMENT_ROOT /var/www/html
ENV APACHE_RUN_DIR /var/run/apache2
ENV APACHE_PID_FILE /var/run/apache2/httpd.pid
ENV APACHE_RUN_USER www-data
ENV APACHE_RUN_GROUP www-data

RUN mkdir /var/log/apache
ENV APACHE_LOG_DIR /var/log/apache

#Copy php.ini and SSL
COPY docker/php-apache/conf/php.ini "$PHP_INI_DIR/php.ini"
COPY docker/ssl/localhost.crt "$APACHE_CONFDIR/ssl/ssl.crt"
COPY docker/ssl/localhost.key "$APACHE_CONFDIR/ssl/ssl.key"

#Copy config files
COPY docker/php-apache/conf/000-default.conf "$APACHE_CONFDIR/sites-available/"
COPY docker/php-apache/conf/apache2.conf "$APACHE_CONFDIR/"

#Enable necessary mods
RUN ln -s /etc/apache2/mods-available/rewrite.load /etc/apache2/mods-enabled/rewrite.load
RUN ln -s /etc/apache2/mods-available/headers.load /etc/apache2/mods-enabled/headers.load
RUN a2enmod rewrite
RUN a2enmod ssl

#Install extension
RUN apt-get update && apt-get install -y \
    pkg-config \
    make \
    autoconf \
    libmcrypt-dev \
    openssl \
    zip \
    unzip \
    libpng-dev \
    libicu-dev \
    g++ \
    zlib1g-dev \
    supervisor \
    libz-dev \
    libmemcached-dev \
    libcurl4-openssl-dev \
    libzip-dev \
    libxml2-dev \
    libonig-dev \
 && pecl install memcache-8.2 msgpack \
 && docker-php-ext-configure intl \
 && docker-php-ext-install -j$(nproc) \
        bcmath gd mysqli pdo_mysql gettext intl curl zip xml mbstring ftp \
 && docker-php-ext-enable pdo_mysql memcache msgpack \
 && rm -rf /var/lib/apt/lists/*



#Config supervisord
COPY docker/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

WORKDIR /var/www/html
EXPOSE 80
EXPOSE 443
#Copy and chmod run.sh
COPY docker/run.sh /run.sh
RUN chmod +x /run.sh
ENTRYPOINT ["/run.sh"]