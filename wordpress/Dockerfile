FROM php:5.6-apache

MAINTAINER tristan@tristanpenman.com

RUN a2enmod rewrite

# install the PHP extensions we need
RUN apt-get update && apt-get install -y libpng12-dev libjpeg-dev mysql-client && rm -rf /var/lib/apt/lists/*
RUN docker-php-ext-configure gd --with-png-dir=/usr --with-jpeg-dir=/usr && docker-php-ext-install gd
RUN docker-php-ext-install mysqli

# Allow an existing WordPress install to be mapped into /var/www/html
VOLUME /var/www/html

# Install wp-cli
RUN curl -L https://github.com/wp-cli/wp-cli/releases/download/v0.20.1/wp-cli-0.20.1.phar -o /usr/local/bin/wp
RUN chmod +x /usr/local/bin/wp

# Set up entrypoint script
COPY docker-entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]

CMD ["apache2-foreground"]
