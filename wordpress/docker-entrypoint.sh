#!/bin/bash

set -e   # (errexit) Exit if any subcommand or pipeline returns a non-zero status
set -u   # (nounset) Exit on any attempt to use an uninitialised variable

# Alias for WP-cli to include arguments that we want to use everywhere
shopt -s expand_aliases
alias wp="wp --path=/var/www/html --allow-root"

# Environment variables that might have been set manually by user
: ${WORDPRESS_DB_NAME:=}
: ${WORDPRESS_DB_USER:=}
: ${WORDPRESS_DB_PASSWORD:=}
: ${WORDPRESS_DB_HOST:=}
: ${WORDPRESS_DB_PORT:=}
: ${WORDPRESS_DB_TABLE_PREFIX:=}

# Environment variables that might be set when linking to a MySQL container
: ${MYSQL_ENV_MYSQL_USER:=}
: ${MYSQL_ENV_MYSQL_PASSWORD:=}
: ${MYSQL_ENV_MYSQL_DATABASE:=}
: ${MYSQL_PORT_3306_TCP_ADDR:=}
: ${MYSQL_PORT_3306_TCP_PORT:=}

# Optional environment variables to toggle debug modes
: ${WP_DEBUG:=}
: ${WP_DEBUG_DISPLAY:=}
: ${WP_DEBUG_LOG:=}

# Internal variables used to pass DB config between functions
db_name=
db_user=
db_pass=
db_pass_source=

#
# Extract database configuration from environment variables
#
# Precedence is given to the WORDPRESS_DB_USER, WORDPRESS_DB_PASSWORD,
# WORDPRESS_DB_HOST, WORDPRESS_DB_PORT and WORDPRESS_DB_NAME environment
# variables. When not present, MYSQL_ENV_* environment variables will be used
# where appropriate, with sane defaults used otherwise.
#
function parse_environment_variables() {
	db_name=${WORDPRESS_DB_NAME:-${MYSQL_ENV_MYSQL_DATABASE:-wordpress}}

	if ! [ -z "$WORDPRESS_DB_USER" ]; then
		db_user=$WORDPRESS_DB_USER
		if ! [ -z "WORDPRESS_DB_PASSWORD" ]; then
			db_pass=$WORDPRESS_DB_PASSWORD
			db_pass_source=WORDPRESS_DB_PASSWORD
		elif [ "$WORDPRESS_DB_USER" == "$MYSQL_ENV_MYSQL_USER" ] && ! [ -z "$MYSQL_ENV_MYSQL_PASSWORD" ]; then
			db_pass=$MYSQL_ENV_MYSQL_PASSWORD
			db_pass_source=MYSQL_ENV_MYSQL_PASSWORD
		fi
	elif ! [ -z "$MYSQL_ENV_MYSQL_USER" ]; then
		db_user=$MYSQL_ENV_MYSQL_USER
		if ! [ -z "$MYSQL_ENV_MYSQL_PASSWORD" ]; then
			db_pass=$MYSQL_ENV_MYSQL_PASSWORD
			db_pass_source=MYSQL_ENV_MYSQL_PASSWORD
		fi
	else
		db_user=wordpress
	fi

	if ! [ -z "$WORDPRESS_DB_HOST"]; then
		db_host=$WORDPRESS_DB_HOST
		if ! [ -z "$MYSQL_PORT_3306_TCP_ADDR" ]; then
			echo >&2 'warning: both WORDPRESS_DB_HOST and MYSQL_PORT_3306_TCP_ADDR found'
			echo >&2 "  Connecting to WORDPRESS_DB_HOST ($WORDPRESS_DB_HOST)"
			echo >&2 '  instead of the linked mysql container'
		fi
		if ! [ -z "$WORDPRESS_DB_PORT" ]; then
			db_port=$WORDPRESS_DB_PORT
		elif ! [ -z "$MYSQL_PORT_3306_TCP_PORT" ] && [ "$WORDPRESS_DB_HOST" == "$MYSQL_PORT_3306_TCP_ADDR" ]; then
			db_port=$MYSQL_PORT_3306_TCP_PORT
		fi
	elif ! [ -z "$MYSQL_PORT_3306_TCP_ADDR" ]; then
		db_host=$MYSQL_PORT_3306_TCP_ADDR
		if ! [ -z "$MYSQL_PORT_3306_TCP_PORT" ]; then
			db_port=$MYSQL_PORT_3306_TCP_PORT
		fi
	fi

	if ! [ -z "$db_name" ]; then echo "Using DB name: $db_name"; fi
	if ! [ -z "$db_host" ]; then echo "Using DB host: $db_host"; fi
	if ! [ -z "$db_port" ]; then echo "Using DB port: $db_port"; fi
	if ! [ -z "$db_user" ]; then echo "Using DB username: $db_user"; fi
	if ! [ -z "$db_pass" ]; then echo "Using DB password from: \$$db_pass_source"; fi
}

#
# Wait up to 20 seconds for MySQL to become available
#
function wait_for_mysql() (
	local host=${db_host:-localhost}
	echo "Waiting for MySQL to become available on $host..."

	local timeout=20
	while [ $timeout -gt 0 ]; do
		local response=`mysqladmin --host=$host --user=UNKNOWN_MYSQL_USER ping 2>&1` && break
		echo "$response" | grep -q "Access denied for user" && break
		sleep 1
		let timeout=${timeout}-1
	done

	echo "MySQL ready."
)

#
# Function used to update an existing wp-config.php file, based on the
# set_config function from the entrypoint script used by Docker's official 
# wordpress image. This can be found at:
#
#     https://github.com/docker-library/wordpress
#
function set_php_constant() (
	function sed_escape_lhs() {
		echo "$@" | sed 's/[]\/$*.^|[]/\\&/g'
	}
	function sed_escape_rhs() {
		echo "$@" | sed 's/[\/&]/\\&/g'
	}
	function php_escape() {
		php -r 'var_export((string) $argv[1]);' "$1"
	}
	local key="$1"
	local value="$2"
	local regex="(['\"])$(sed_escape_lhs "$key")\2\s*,"
	if [ "${key:0:1}" = '$' ]; then
		regex="^(\s*)$(sed_escape_lhs "$key")\s*="
	fi
	sed -ri "s/($regex\s*)(['\"]).*\3/\1$(sed_escape_rhs "$(php_escape "$value")")/" wp-config.php
)

#
# Update database configuration in existing wp-config.php file
#
# Note that this function can only update database configuration constants that
# are already present in the configuration file. If a new value for a given
# constant has not been provided, then the previous value will be preseved.
#
function update_database_config() (
	if ! [ -z "$db_host" ]; then
		if [ -z "$db_port" ]; then
			set_php_constant 'DB_HOST' "$db_host"
		else
			set_php_constant 'DB_HOST' "$db_host:$db_port"
		fi
	fi

	if ! [ -z "$db_user" ]; then
		set_php_constant 'DB_USER' "$db_user"
	fi

	if ! [ -z "$db_pass" ]; then
		set_php_constant 'DB_PASSWORD' "$db_pass"
	fi

	if ! [ -z "$db_name" ]; then
		set_php_constant 'DB_NAME' "$db_name"
	fi
)

#
# Create a new wp-config.php file, or update database configuration if the file
# already exists
#
# When creating a new wp-config.php file, the WP_DEBUG, WP_DEBUG_DISPLAY and
# WP_DEBUG_LOG environment variables will be used to set the identically named
# constants in wp-config.php.
#
function create_config_file() (
	local wp_core_config_args="--dbname=$db_name"
	if ! [ -z "$db_user" ]; then
		wp_core_config_args="$wp_core_config_args --dbuser=$db_user"
	fi
	if ! [ -z "$db_pass" ]; then
		wp_core_config_args="$wp_core_config_args --dbpass=$db_pass"	
	fi
	if ! [ -z "$db_host" ]; then
		wp_core_config_args="$wp_core_config_args --dbhost=$db_host"
		if ! [ -z "$db_port" ]; then
			wp_core_config_args="$wp_core_config_args:$db_port"
		fi
	fi

	shopt -s nocasematch;

	local wp_debug=
	local wp_debug_display=
	local wp_debug_log=

	if [[ "$WP_DEBUG" =~ ^on|y|yes|1|t|true|enabled$ ]]; then
		wp_debug="define( 'WP_DEBUG', true );"
		if ! [ -z "$WP_DEBUG_DISPLAY" ] && ! [[ "$WP_DEBUG_DISPLAY" =~ ^on|y|yes|1|t|true|enabled$ ]]; then
			wp_debug_display="define( 'WP_DEBUG_DISPLAY', false );"
		fi
		if [[ "$WP_DEBUG_LOG" =~ ^on|y|yes|1|t|true|enabled$ ]]; then
			wp_debug_log="define( 'WP_DEBUG_LOG', true );"
		fi
	fi

	if [ -z "$wp_debug" ]; then
		wp core config $wp_core_config_args
	else
		wp core config $wp_core_config_args \
			--extra-php <<-PHP
				$wp_debug
				$wp_debug_display
				$wp_debug_log
				PHP
	fi
)

#
# Update various other constants in wp-config.php
#
# If not specified via environment variables, any random keys will be
# regenerated automatically.
#
function update_other_config() (
	local uniques=(
		AUTH_KEY
		SECURE_AUTH_KEY
		LOGGED_IN_KEY
		NONCE_KEY
		AUTH_SALT
		SECURE_AUTH_SALT
		LOGGED_IN_SALT
		NONCE_SALT
	)
	for unique in "${uniques[@]}"; do
		eval local unique_value=\${WORDPRESS_$unique:-}
		if [ "$unique_value" ]; then
			set_php_constant "$unique" "$unique_value"
		else
			# if not specified, let's generate a random value
			local current_set="$(sed -rn "s/define\((([\'\"])$unique\2\s*,\s*)(['\"])(.*)\3\);/\4/p" wp-config.php)"
			if [ "$current_set" == 'put your unique phrase here' ]; then
				set_php_constant "$unique" "$(head -c1M /dev/urandom | sha1sum | cut -d' ' -f1)"
			fi
		fi
	done

	if [ "$WORDPRESS_DB_TABLE_PREFIX" ]; then
		set_php_constant '$table_prefix' "$WORDPRESS_DB_TABLE_PREFIX"
	fi
)

parse_environment_variables

if ! [ -f /var/www/html/index.php -a -f /var/www/html/wp-includes/version.php ]; then
	echo "WordPress not present in /var/www/html."
	wp core download --version=${WORDPRESS_VERSION:-latest}
fi

wait_for_mysql

if [ -f /var/www/html/wp-config.php ]; then
	echo "File /var/www/html/wp-config.php exists."
	echo "Updating database configuration in /var/www/html/wp-config.php..."
	update_database_config
else
	echo "File /var/www/html/wp-config.php does not exist."
	echo "Creating new /var/www/html/wp-config.php using wp-cli..."
	create_config_file
fi

update_other_config

# Run any post-install scripts located in /entrypoint.d
if [ -d /entrypoint.d ]; then
	for SCRIPT in /entrypoint.d/*
	do
		# $SCRIPT should contain a full path to a file in /entrypoint.d
		if [ -f $SCRIPT -a -x $SCRIPT ]
		then
			$SCRIPT
		fi
	done
fi

# Pass through arguments to exec
if [ $# -ge 1 ]; then
	exec "$@"
fi
