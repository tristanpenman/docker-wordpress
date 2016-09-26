# Docker Image for WordPress #

## Overview ##

This repo contains an unofficial Docker image for WordPress. It differs from the [official image](https://hub.docker.com/_/wordpress/) by taking steps to make it easier to install and customise a WordPress installation while initialising a container.

This image also has [WP-CLI](http://wp-cli.org/) installed, to allow for easy installation and configuration of plugins.

You can find this image on [Docker Hub](https://hub.docker.com/r/tristanpenman/wordpress/).

## Usage ##

You can pull the latest build from Docker Hub:

    docker pull tristanpenman/wordpress

Alternatively, you can grab the latest source and build the image yourself:

    git clone https://github.com/tristanpenman/docker-wordpress.git
    docker build -t wordpress docker-wordpress

This will create an image with a repository name of 'wordpress'.

This image expects MySQL to be available. To get a database up and running quickly, you can use the official MySQL Docker image:

    docker run --name mysql \
        -d mysql:5.7 \
        -e MYSQL_USER=wordpress \
        -e MYSQL_PASSWORD=wordpress \
        -e MYSQL_ROOT_PASSWORD=root \
        -e MYSQL_DATABASE=wordpress

You can then start a WordPress container, configured to talk to the database created by your MySQL container:

    docker run --link mysql:mysql \
        -p 8080:80 \
        -e WORDPRESS_DB_NAME=wordpress \
        -e WORDPRESS_DB_PASSWORD=wordpress \
        -e WORDPRESS_DB_USER=wordpress \
        tristanpenman/wordpress

If you are using an image that you built locally, you would want to the replace the repository name 'tristanpenman/wordpress' with the name that you have chosen.

## Apache ##

By default, Apache will listen on port 80 in the container. In the example above, the `-p` option is used to map port 80 in the container to port 8080 on the host.

## Database Configuration ##

When not relying on Docker's linked container functionality, you can use the following environment variables to tell WordPress how to connect to its MySQL database:

 * `WORDPRESS_DB_HOST` (required)
 * `WORDPRESS_DB_PORT` (optional; default is port 3306)
 * `WORDPRESS_DB_NAME` (optional; default is 'wordpress')
 * `WORDPRESS_DB_USER` (optional; default is 'wordpress')
 * `WORDPRESS_DB_PASSWORD` (optional; default is 'wordpress')
 * `WORDPRESS_DB_TABLE_PREFIX` (optional)

If you link your container to an official Docker MySQL container, then the following environment variables will be used as a fallback:

 * MYSQL_PORT_3306_TCP_ADDR
 * MYSQL_PORT_3306_TCP_PORT
 * MYSQL_ENV_MYSQL_DATABASE
 * MYSQL_ENV_MYSQL_USER
 * MYSQL_ENV_MYSQL_PASSWORD

After parsing the environment, the final configuration will be exported via the following environment variables:

 * `DB_DRIVER`
 * `DB_NAME`
 * `DB_HOST`
 * `DB_PORT`
 * `DB_USER`
 * `DB_PASS`

## Debug Configuration ##

In addition to database configuration, you can also enable WordPress debug logging using the following environment variables:

 * `WP_DEBUG` (set to `true` to enable debugging; default is `false`)
 * `WP_DEBUG_DISPLAY` (set to `true` to display all errors in the browser; default is the value of `$WP_DEBUG`)
 * `WP_DEBUG_LOG` (set to `true` to have all errors logged to the PHP error log; default is `false`)

You can also disable external HTTP requests by setting `WP_HTTP_BLOCK_EXTERNAL` to `true.

See the Docker Compose example below for an example of how these are set.

## Customisation ##

This image has been designed with customisation in mind.

You will notice that this repo includes a script called `docker-entrypoint.sh`, which is run by the container at startup. This script takes care of installing and configuring WordPress, and if necessary, running any additional installation scripts.

When using this image as the base image for your own Dockerfile, you can provide your own installation scripts to be run before or after `docker-entrypoint.sh` installs/configures WordPress. Scripts that you want run before-hand should be placed in `/scripts/pre-install.d`, while scripts that you want executed after Wordpress has been installed and configured should be placed in `/scripts/post-install.d`.

### Example ###

As an example, a post-install script could install a WordPress plugin such as WooCommerce:

    #!/bin/bash
    #
    # /scripts/post-install.d/00-install-woocommerce
    #
    set -e   # (errexit) Exit if any subcommand or pipeline returns a non-zero status
    set -u   # (nounset) Exit on any attempt to use an uninitialised variable

    shopt -s expand_aliases
    alias wp="wp --path=$DOCUMENT_ROOT --allow-root"

    if ! $(wp plugin is-installed woocommerce); then
        wp plugin install woocommerce
    fi

### Environment Variables ###

Note that in the example above, the `DOCUMENT_ROOT` environment variable is used to refer to the location of the WordPress installation.

## Docker Compose ##

A convenient way to capture the configuration of your MySQL and WordPress images is to use [Docker Compose](https://docs.docker.com/compose/).

### Example ###

    # docker-compose.yml

    web:
      build: tristanpenman/wordpress
      ports: 
       - "8080:80"
      environment:
       - WORDPRESS_DB_NAME=wordpress
       - WORDPRESS_DB_PASSWORD=wordpress
       - WORDPRESS_DB_USER=wordpress
       - WP_DEBUG=true
       - WP_DEBUG_DISPLAY=false
       - WP_DEBUG_LOG=true
      links:
       - mysql

    mysql:
      image: mysql:5.7
      environment:
       - MYSQL_USER=wordpress
       - MYSQL_PASSWORD=wordpress
       - MYSQL_ROOT_PASSWORD=root
       - MYSQL_DATABASE=wordpress

## Supported Versions ##

### Docker ###

This image has been tested with Docker version 1.8.3, and will generally be tested against the latest version of Docker at the time that any changes are made.

### WP-CLI ###

This image includes version 0.24.1 of WP-CLI.

## License ##

This Docker image is licensed under the MIT License.

See the LICENSE file for more information.
