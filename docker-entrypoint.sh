#!/bin/bash

set -e   # (errexit) Exit if any subcommand or pipeline returns a non-zero status
set -u   # (nounset) Exit on any attempt to use an uninitialised variable

# Allow Dockerfile to override default document root, if necessary
: ${DOCUMENT_ROOT:=/var/www/html}
if [ "$DOCUMENT_ROOT" != "/" ]; then
	DOCUMENT_ROOT=${DOCUMENT_ROOT%/}    # Trim trailing slash
fi

# Allow Dockerfile to override default scripts directory
: ${SCRIPTS_DIR:=/scripts}
if [ "$SCRIPTS_DIR" != "/" ]; then
	SCRIPTS_DIR=${SCRIPTS_DIR%/}        # Trim trailing slash
fi

# Alias for WP-cli to include arguments that we want to use everywhere
shopt -s expand_aliases
alias wp="wp --path=$DOCUMENT_ROOT --allow-root"

# Environment variables that might have been set manually by user
: ${WORDPRESS_DB_NAME:=}
: ${WORDPRESS_DB_USER:=}
: ${WORDPRESS_DB_PASSWORD:=}
: ${WORDPRESS_DB_HOST:=}
: ${WORDPRESS_DB_PORT:=}
: ${WORDPRESS_DB_TABLE_PREFIX:=}
: ${WORDPRESS_DB_VERIFICATION_QUERY:=}

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

# Optional environment variable to disable external HTTP requests
: ${WP_HTTP_BLOCK_EXTERNAL:=}

# Internal variables used to pass DB config between functions
db_name=
db_user=
db_host=
db_port=
db_pass=
db_pass_source=
db_verification_query=

# Path to WordPress configuration
config_path=${DOCUMENT_ROOT}/wp-config.php

# Paths to additional installation scripts
preinstall_scripts_dir=${SCRIPTS_DIR}/pre-install.d
postinstall_scripts_dir=${SCRIPTS_DIR}/post-install.d

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

	if [ "$WORDPRESS_DB_USER" ]; then
		db_user=$WORDPRESS_DB_USER
		if [ "WORDPRESS_DB_PASSWORD" ]; then
			db_pass=$WORDPRESS_DB_PASSWORD
			db_pass_source=WORDPRESS_DB_PASSWORD
		elif [ "$WORDPRESS_DB_USER" == "$MYSQL_ENV_MYSQL_USER" ] && [ "$MYSQL_ENV_MYSQL_PASSWORD" ]; then
			db_pass=$MYSQL_ENV_MYSQL_PASSWORD
			db_pass_source=MYSQL_ENV_MYSQL_PASSWORD
		fi
	elif [ "$MYSQL_ENV_MYSQL_USER" ]; then
		db_user=$MYSQL_ENV_MYSQL_USER
		if [ "$MYSQL_ENV_MYSQL_PASSWORD" ]; then
			db_pass=$MYSQL_ENV_MYSQL_PASSWORD
			db_pass_source=MYSQL_ENV_MYSQL_PASSWORD
		fi
	else
		db_user=wordpress
	fi

	if [ "$WORDPRESS_DB_HOST" ]; then
		db_host=$WORDPRESS_DB_HOST
		if [ "$MYSQL_PORT_3306_TCP_ADDR" ]; then
			echo >&2 'warning: both WORDPRESS_DB_HOST and MYSQL_PORT_3306_TCP_ADDR found'
			echo >&2 "  Connecting to WORDPRESS_DB_HOST ($WORDPRESS_DB_HOST)"
			echo >&2 '  instead of the linked mysql container'
		fi
		if [ "$WORDPRESS_DB_PORT" ]; then
			db_port=$WORDPRESS_DB_PORT
		elif [ "$MYSQL_PORT_3306_TCP_PORT" ] && [ "$WORDPRESS_DB_HOST" == "$MYSQL_PORT_3306_TCP_ADDR" ]; then
			db_port=$MYSQL_PORT_3306_TCP_PORT
		fi
	elif [ "$MYSQL_PORT_3306_TCP_ADDR" ]; then
		db_host=$MYSQL_PORT_3306_TCP_ADDR
		if [ "$MYSQL_PORT_3306_TCP_PORT" ]; then
			db_port=$MYSQL_PORT_3306_TCP_PORT
		fi
	else
		db_host=localhost
	fi

	if [ "$WORDPRESS_DB_VERIFICATION_QUERY" ]; then
		db_verification_query="${WORDPRESS_DB_VERIFICATION_QUERY}"
	fi

	if [ "$db_name" ]; then echo "Using DB name: $db_name"; fi
	if [ "$db_host" ]; then echo "Using DB host: $db_host"; fi
	if [ "$db_port" ]; then echo "Using DB port: $db_port"; fi
	if [ "$db_user" ]; then echo "Using DB username: $db_user"; fi
	if [ "$db_pass" ]; then echo "Using DB password from: \$$db_pass_source"; fi
}

#
# Wait up to 20 seconds for MySQL to become available
#
function wait_for_mysql() (
	echo "Waiting for MySQL to become available on $db_host..."
	local retries=20
	while [ $retries -gt 0 ]; do
		local response=`mysqladmin --host=$db_host --port=$db_port --user=UNKNOWN_MYSQL_USER ping 2>&1` && break
		echo "$response" | grep -q "Access denied for user" && break
		sleep 1
		let retries=${retries}-1
	done
	if [ $retries -eq 0 ]; then
		echo "MySQL server could not be contacted."
		exit 1
	fi
	echo "MySQL ready."

	local mysql_args="--host=$db_host --port=$db_port --user=$db_user --password=$db_pass"

	echo "Waiting for database '$db_name' to be ready..."
	let retries=20
	while [ $retries -gt 0 ]; do
		mysql $mysql_args --execute="use ${db_name};" > /dev/null 2>&1 && break
		sleep 1
		let retries=${retries}-1
	done
	if [ $retries -eq 0 ]; then
		echo "MySQL server is up, but database '$db_name' is not accessible."
		exit 1
	fi
	echo "Database created."

	if [ "$db_verification_query" ]; then
		echo "About to verify database state using custom query: $db_verification_query"
		echo "Waiting for custom query to succeed..."
		let retries=20
		while [ $retries -gt 0 ]; do
			mysql $mysql_args --database=$db_name --execute="${db_verification_query};" > /dev/null 2>&1 && break
			sleep 1
			let retries=${retries}-1
		done
		if [ $retries -eq 0 ]; then
			echo "Database is present, but database state could not be verified using custom query."
			exit 1
		fi
		echo "Database state verified."
	fi
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
	sed -ri "s/($regex\s*)(['\"]).*\3/\1$(sed_escape_rhs "$(php_escape "$value")")/" $config_path
)

#
# Update database configuration in existing wp-config.php file
#
# Note that this function can only update database configuration constants that
# are already present in the configuration file. If a new value for a given
# constant has not been provided, then the previous value will be preseved.
#
function update_database_config() (
	if [ "$db_host" ]; then
		if [ "$db_port" ]; then
			set_php_constant 'DB_HOST' "$db_host:$db_port"
		else
			set_php_constant 'DB_HOST' "$db_host"
		fi
	fi

	if [ "$db_user" ]; then
		set_php_constant 'DB_USER' "$db_user"
	fi

	if [ "$db_pass" ]; then
		set_php_constant 'DB_PASSWORD' "$db_pass"
	fi

	if [ "$db_name" ]; then
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
	if [ "$db_user" ]; then
		wp_core_config_args="$wp_core_config_args --dbuser=$db_user"
	fi
	if [ "$db_pass" ]; then
		wp_core_config_args="$wp_core_config_args --dbpass=$db_pass"	
	fi
	if [ "$db_host" ]; then
		wp_core_config_args="$wp_core_config_args --dbhost=$db_host"
		if [ "$db_port" ]; then
			wp_core_config_args="${wp_core_config_args}:$db_port"
		fi
	fi

	shopt -s nocasematch;

	local wp_debug=
	local wp_debug_display=
	local wp_debug_log=
	local wp_http_block_external=

	# WordPress sets WP_DEBUG to 'false' by default. If we're overriding this value, we also want
	# to check whether the WP_DEBUG_DISPLAY and WP_DEBUG_LOG constants should be set.
	if [[ "$WP_DEBUG" =~ ^on|y|yes|1|t|true|enabled$ ]]; then
		wp_debug="define( 'WP_DEBUG', true );"

		# WordPress sets WP_DEBUG_DISPLAY to 'true' by default. We want to override the WP_DEBUG_DISPLAY
		# constant if, and only if, a non-empty value has been provided and that value does not match
		# one of our truthy values. The regex test would not be enough on its own here, as that would
		# cause the constant to be set for empty values.
		if [ "$WP_DEBUG_DISPLAY" ] && ! [[ "$WP_DEBUG_DISPLAY" =~ ^on|y|yes|1|t|true|enabled$ ]]; then
			wp_debug_display="define( 'WP_DEBUG_DISPLAY', false );"
		fi

		# WordPress sets WP_DEBUG_LOG to 'false' by default
		if [[ "$WP_DEBUG_LOG" =~ ^on|y|yes|1|t|true|enabled$ ]]; then
			wp_debug_log="define( 'WP_DEBUG_LOG', true );"
		fi
	fi

	if [[ "$WP_HTTP_BLOCK_EXTERNAL" =~ ^on|y|yes|1|t|true|enabled$ ]]; then
		wp_http_block_external="define( 'WP_HTTP_BLOCK_EXTERNAL', true );"
	fi

	shopt -u nocasematch;

	if [ "$wp_debug" ]; then
		wp core config $wp_core_config_args \
			--extra-php <<-PHP
				$wp_debug
				$wp_debug_display
				$wp_debug_log
				PHP
	else
		wp core config $wp_core_config_args
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
			local current_set="$(sed -rn "s/define\((([\'\"])$unique\2\s*,\s*)(['\"])(.*)\3\);/\4/p" $config_path)"
			if [ "$current_set" == 'put your unique phrase here' ]; then
				set_php_constant "$unique" "$(head -c1M /dev/urandom | sha1sum | cut -d' ' -f1)"
			fi
		fi
	done

	if [ "$WORDPRESS_DB_TABLE_PREFIX" ]; then
		set_php_constant '$table_prefix' "$WORDPRESS_DB_TABLE_PREFIX"
	fi
)

#
# Run any executable files found in the pre-installation scripts directory
#
# The directory to search is defined by the preinstall_script_dirs environment variable.
#
function run_preinstall_scripts() {
	echo "Checking for pre-installation scripts directory (${preinstall_scripts_dir})..."
	if [ -d ${preinstall_scripts_dir} ]; then
		echo "Running pre-installation scripts..."
		local script=
		for script in ${preinstall_scripts_dir}/*
		do
			if [ -f $script ]; then
				if [ -x $script ]; then
					echo "Running ${script}..."
					$script
				else
					echo "Skipping ${script} as it is not executable."
				fi
			fi
		done
	fi
}

#
# Run any executable files found in the post-installation scripts directory
#
# The directory to search is defined by the postinstall_script_dirs environment variable.
#
function run_postinstall_scripts() {
	echo "Checking for post-installation scripts directory (${postinstall_scripts_dir})..."
	if [ -d ${postinstall_scripts_dir} ]; then
		echo "Running post-installation scripts..."
		local script=
		for script in ${postinstall_scripts_dir}/*
		do
			if [ -f $script ]; then
				if [ -x $script ]; then
					echo "Running ${script}..."
					$script
				else
					echo "Skipping ${script} as it is not executable."
				fi
			fi
		done
	fi
}

parse_environment_variables

wait_for_mysql

export DB_DRIVER=mysql
export DB_NAME=$db_name
export DB_HOST=$db_host
export DB_PORT=$db_port
export DB_USER=$db_user
export DB_PASS=$db_pass

echo "Using database configuration:"
echo "  Database driver    (DB_DRIVER):  $DB_DRIVER"
echo "  Database name      (DB_NAME):    $DB_NAME"
echo "  Database host      (DB_HOST):    $DB_HOST"
echo "  Database port      (DB_PORT):    $DB_PORT"
echo "  Database username  (DB_USER):    $DB_USER"
echo "  Database password  (DB_PASS):    ** not shown **"

export DOCUMENT_ROOT
export SCRIPTS_DIR

echo "Other configuration:"
echo "  Document root      (DOCUMENT_ROOT): $DOCUMENT_ROOT"
echo "  Scripts directory  (SCRIPTS_DIR):   $SCRIPTS_DIR"

run_preinstall_scripts

if ! [ -f ${DOCUMENT_ROOT}/index.php ] || ! [ -f ${DOCUMENT_ROOT}/wp-includes/version.php ]; then
	echo "WordPress not present in ${DOCUMENT_ROOT}."
	wp core download --version=${WORDPRESS_VERSION:-latest}
fi

if [ -f $config_path ]; then
	echo "File $config_path exists."
	echo "Updating database configuration in ${config_path}..."
	update_database_config
else
	echo "File $config_path does not exist."
	echo "Creating new $config_path using wp-cli..."
	create_config_file
fi

update_other_config

run_postinstall_scripts

chown -R www-data:www-data $DOCUMENT_ROOT

# Pass through arguments to exec
if [ $# -ge 1 ]; then
	exec "$@"
fi
