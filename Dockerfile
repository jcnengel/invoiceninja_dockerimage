ARG PHP_VERSION=7.3

##
# Prepare Invoiceninja sources for reuse later
##
FROM alpine:latest AS base
ARG INVOICENINJA_VERSION=5.0.21

RUN set -eux; \
    apk update \
    && apk add --no-cache \
    curl \
    libarchive-tools; \
    mkdir -p /var/www/app
    
RUN curl -o /tmp/ninja.tar.gz -LJ0 https://github.com/invoiceninja/invoiceninja/tarball/v$INVOICENINJA_VERSION \
    && bsdtar --strip-components=1 -C /var/www/app -xf /tmp/ninja.tar.gz \
    && rm /tmp/ninja.tar.gz \
    && cp -R /var/www/app/storage /var/www/app/docker-backup-storage  \
    && cp -R /var/www/app/public /var/www/app/docker-backup-public  \
    && mkdir -p /var/www/app/public/logo /var/www/app/storage \
    && cp /var/www/app/.env.example /var/www/app/.env \
    && cp /var/www/app/.env.dusk.example /var/www/app/.env.dusk.local \
    && rm -rf /var/www/app/docs /var/www/app/tests

##
# Prepare libraries using nodejs
##
FROM node:14-alpine AS nodejs
RUN apk add --no-cache chromium nss freetype freetype-dev \
	harfbuzz ca-certificates ttf-freefont curl
COPY --from=base /var/www/app /var/www/app
WORKDIR /var/www/app

ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser

RUN npm i puppeteer && npm audit fix

##
# Prepare final image including PHP
##
FROM php:${PHP_VERSION}-fpm-alpine AS php-base
LABEL maintainer="jcnengel@gmail.com"

# Install chromium
RUN apk add --no-cache chromium nss freetype freetype-dev \
	harfbuzz ca-certificates ttf-freefont npm
COPY --from=nodejs /var/www/app /var/www/app
WORKDIR /var/www/app

ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
ENV PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser

##
# Install missing PHP extensions
##
RUN apk update \
    && apk add --no-cache git gmp-dev freetype-dev libjpeg-turbo-dev \
    coreutils chrpath fontconfig libpng-dev oniguruma-dev zip libzip libzip-dev \
    && docker-php-ext-configure gmp \
    && docker-php-ext-install iconv mbstring pdo pdo_mysql mysqli bcmath zip gd gmp opcache exif \
    && echo "php_admin_value[error_reporting] = E_ALL & ~E_NOTICE & ~E_WARNING & ~E_STRICT & ~E_DEPRECATED" >> /usr/local/etc/php-fpm.d/www.conf \
    && apk del gmp-dev freetype-dev libjpeg-turbo-dev libpng-dev oniguruma-dev libzip-dev

RUN { \
	echo 'opcache.memory_consumption=128'; \
	echo 'opcache.interned_strings_buffer=8'; \
	echo 'opcache.max_accelerated_files=4000'; \
	echo 'opcache.revalidate_freq=60'; \
	echo 'opcache.fast_shutdown=1'; \
	echo 'opcache.enable_cli=1'; \
} > /usr/local/etc/php/conf.d/opcache-recommended.ini

# Install composer and related requirements
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin \
	--filename=composer; \
	composer global require hirak/prestissimo; \
	composer install --no-dev --no-suggest --no-progress


COPY entrypoint.sh /usr/local/bin/invoiceninja-entrypoint
RUN chmod +x /usr/local/bin/invoiceninja-entrypoint

# Create local user
ENV INVOICENINJA_USER=invoiceninja
RUN addgroup -S "${INVOICENINJA_USER}" \
	&& adduser --disabled-password --gecos "" --home "/var/www/app" \
	--ingroup "${INVOICENINJA_USER}" --no-create-home "${INVOICENINJA_USER}"; \
	addgroup "${INVOICENINJA_USER}" www-data; \
	chown -R "${INVOICENINJA_USER}":"${INVOICENINJA_USER}" /var/www/app

ENV APP_ENV production
ENV LOG errorlog
ENV SELF_UPDATER_SOURCE ''
ENV NPM_PATH="/usr/bin"

VOLUME /var/www/app/public

## Set up the cronjob and run cron daemon
COPY ./cronjob_v5.sh /etc/periodic/1min/invoiceninja_cronjob
RUN echo "* * * * * run-parts /etc/periodic/1min" >> /etc/crontabs/root \
    && chown $INVOICENINJA_USER /etc/periodic/1min/invoiceninja_cronjob \
    && crond -l 2 -b

USER $INVOICENINJA_USER

ENTRYPOINT ["/usr/local/bin/invoiceninja-entrypoint"]
CMD ["php-fpm"]
