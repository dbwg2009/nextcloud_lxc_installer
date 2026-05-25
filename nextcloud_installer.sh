#!/bin/bash

# ==============================================================================
# Nextcloud Installer & Manager (Intelligent & Interactive)
# for Debian 12 / Ubuntu 22.04 - v3.0 (with bug fixes)
#
# - Fixes all known issues from the Nextcloud Administration overview.
# - Configures Redis file locking, Imagick SVG support, maintenance window, etc.
# - Resolves the "server-to-itself" connection problem in container environments.
# ==============================================================================

set -e # Exit the script immediately if a command fails

# --- Global Variables ---
SERVICES=(
    "apache2.service"
    "mariadb.service"
    "redis-server.service"
)
STATE_FILE=".nextcloud_install_state"
NC_PATH="/var/www/nextcloud"

# ==============================================================================
# --- FUNCTION DEFINITIONS ---
# ==============================================================================

# Function to clean up an existing installation
cleanup() {
    echo " Starting cleanup of the Nextcloud installation..."

    # 1. Remove /etc/hosts entry
    echo "→ Removing host entry from /etc/hosts..."
    sed -i "/${NC_URL}/d" /etc/hosts

    # 2. Remove Apache vHost
    echo "→ Removing Apache vHost configurations..."
    a2dissite "${NC_URL}.conf" &>/dev/null || true
    a2dissite "${NC_URL}-le-ssl.conf" &>/dev/null || true
    rm -f "/etc/apache2/sites-available/${NC_URL}.conf"
    rm -f "/etc/apache2/sites-available/${NC_URL}-le-ssl.conf"
    systemctl reload apache2 &>/dev/null || true

    # 3. Delete database and DB user
    echo "→ Deleting MariaDB database and user..."
    if ! systemctl is-active --quiet mariadb.service; then
        echo "   MariaDB service is not running, starting it temporarily for cleanup..."
        systemctl start mariadb.service
        sleep 2
    fi
    mysql -e "DROP DATABASE IF EXISTS \`${NC_DB_NAME}\`;"
    mysql -e "DROP USER IF EXISTS '${NC_DB_USER}'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"

    # 4. Stop and disable services
    echo "→ Stopping and disabling all relevant services..."
    systemctl stop "${SERVICES[@]}" &>/dev/null || true
    systemctl disable "${SERVICES[@]}" &>/dev/null || true

    # 5. Delete Nextcloud files and directories
    echo "→ Deleting Nextcloud directories..."
    rm -rf "${NC_PATH}"
    rm -rf "/var/nextcloud_data"

    # 6. Remove cronjob
    echo "→ Removing cronjob..."
    (crontab -u www-data -l | grep -v "${NC_PATH}/cron.php" | crontab -u www-data -) &>/dev/null || true

    # 7. Delete state file
    rm -f "$STATE_FILE"
    
    echo "✅ Cleanup complete."
}


# Function for the installation process
installation() {
    # 1. Prepare system
    echo " Running system updates and installing base packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get upgrade -y
    apt-get install -y sudo curl wget unzip tar software-properties-common dirmngr apt-transport-https gnupg2 ca-certificates lsb-release
    echo "✅ System preparation complete."

    # 2. Install PHP and required extensions
    echo " Installing PHP 8.2 and all required extensions (including Imagick SVG)..."
    if ! apt-key list | grep -q "ondrej/php"; then
        curl -sSLo /usr/share/keyrings/deb.sury.org-php.gpg https://packages.sury.org/php/apt.gpg
        sh -c 'echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list'
        apt-get update
    fi
    
    apt-get install -y php8.2 libapache2-mod-php8.2
    apt-get install -y \
        php8.2-gd php8.2-mysql php8.2-curl php8.2-mbstring php8.2-intl \
        php8.2-gmp php8.2-bcmath php8.2-xml php8.2-zip php8.2-imagick \
        php8.2-redis php8.2-apcu imagemagick # Ensure full ImageMagick with SVG support is installed
    echo "✅ PHP installation complete."

    # 3. Install web server, database, and cache
    echo " Installing and configuring Apache, MariaDB, and Redis..."
    apt-get install -y apache2 mariadb-server redis-server
    systemctl enable --now "${SERVICES[@]}"
    
    mysql -e "CREATE DATABASE \`${NC_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
    mysql -e "CREATE USER '${NC_DB_USER}'@'localhost' IDENTIFIED BY '${NC_DB_PASS}';"
    mysql -e "GRANT ALL PRIVILEGES ON \`${NC_DB_NAME}\`.* TO '${NC_DB_USER}'@'localhost';"
    mysql -e "FLUSH PRIVILEGES;"
    echo "✅ Database and caching service configured."

    # 4. Download and extract Nextcloud
    echo " Downloading Nextcloud v${NC_VERSION}..."
    cd /tmp
    wget -q --show-progress "https://download.nextcloud.com/server/releases/nextcloud-${NC_VERSION}.zip"
    unzip -q "nextcloud-${NC_VERSION}.zip"
    mv nextcloud "${NC_PATH}"
    rm "nextcloud-${NC_VERSION}.zip"
    echo "✅ Nextcloud downloaded and extracted."

    # 5. Set file permissions
    echo " Setting file permissions..."
    mkdir -p /var/nextcloud_data
    chown -R www-data:www-data "${NC_PATH}/"
    chown -R www-data:www-data "/var/nextcloud_data/"
    chmod -R 750 "${NC_PATH}/"
    chmod -R 750 "/var/nextcloud_data/"
    echo "✅ Permissions set."

    # 6. Create Apache vHost
    echo " Creating Apache vHost..."
    tee "/etc/apache2/sites-available/${NC_URL}.conf" > /dev/null <<EOF
<VirtualHost *:80>
    ServerAdmin admin@${NC_URL}
    ServerName ${NC_URL}
    DocumentRoot ${NC_PATH}

    <Directory ${NC_PATH}/>
        Require all granted
        # AllowOverride All is required for the Nextcloud .htaccess file to work.
        AllowOverride All
        Options FollowSymLinks MultiViews

        <IfModule mod_dav.c>
            Dav off
        </IfModule>
    </Directory>

    # Add security and privacy related headers
    <IfModule mod_headers.c>
        Header always set X-Content-Type-Options "nosniff"
        Header always set X-Frame-Options "SAMEORIGIN"
        Header always set X-Permitted-Cross-Domain-Policies "none"
        Header always set X-Robots-Tag "noindex, nofollow"
        Header always set Referrer-Policy "no-referrer"
    </IfModule>

    # Add mime types for modern file formats
    <IfModule mod_mime.c>
      AddType image/svg+xml svg svgz
      AddType application/wasm wasm
      # Serve ESM javascript files (.mjs) with correct mime type
      AddType text/javascript js mjs
    </IfModule>

    # Service discovery and other rewrites
    <IfModule mod_rewrite.c>
        RewriteEngine on
        # These are the essential rewrites for service discovery.
        # The full .htaccess file is still used via "AllowOverride All".
        RewriteRule ^\.well-known/carddav /remote.php/dav/ [R=301,L]
        RewriteRule ^\.well-known/caldav /remote.php/dav/ [R=301,L]
        RewriteRule ^ocm-provider/?$ /index.php [QSA,L]
        RewriteRule ^ocs-provider/?$ /index.php [QSA,L]
        RewriteRule ^\.well-known/(?!acme-challenge|pki-validation) /index.php [QSA,L]
    </IfModule>

</VirtualHost>
EOF
    a2ensite "${NC_URL}.conf"
    a2enmod rewrite headers env dir mime
    systemctl restart apache2
    echo "✅ Apache configured."

    # 7. Optimise PHP settings
    echo " Optimising PHP settings..."
    PHP_INI_FILE=$(find /etc/php -name "php.ini" -and -path "*apache2*")
    sed -i "s/memory_limit = .*/memory_limit = 512M/" "$PHP_INI_FILE"
    sed -i "s/upload_max_filesize = .*/upload_max_filesize = 10G/" "$PHP_INI_FILE"
    sed -i "s/post_max_size = .*/post_max_size = 10G/" "$PHP_INI_FILE"
    sed -i "s/;date.timezone =/date.timezone = Europe\/Berlin/" "$PHP_INI_FILE"
    systemctl restart apache2
    echo "✅ PHP optimised."

    # 8. Nextcloud installation via 'occ'
    echo " Running the Nextcloud command-line installation..."
    sudo -u www-data php "${NC_PATH}/occ" maintenance:install \
        --database "mysql" --database-name "${NC_DB_NAME}" --database-user "${NC_DB_USER}" \
        --database-pass "${NC_DB_PASS}" --admin-user "${NC_ADMIN_USER}" --admin-pass "${NC_ADMIN_PASS}" \
        --data-dir "/var/nextcloud_data"
    echo "✅ Nextcloud core installation complete."
    
    # 9. NEW: Fix server-to-itself problem (fix for container environments)
    echo " Adding '${NC_URL}' to /etc/hosts to resolve connectivity issues..."
    echo "127.0.0.1 ${NC_URL}" >> /etc/hosts
    echo "✅ Host entry set for internal reachability."

    # 10. Post-installation & bug fixes via 'occ'
    echo " Running post-installation configurations..."
    sudo -u www-data php "${NC_PATH}/occ" config:system:set trusted_domains 1 --value="${NC_URL}"
    # Caching
    sudo -u www-data php "${NC_PATH}/occ" config:system:set memcache.local --value '\OC\Memcache\APCu'
    sudo -u www-data php "${NC_PATH}/occ" config:system:set memcache.distributed --value '\OC\Memcache\Redis'
    # Redis configuration
    sudo -u www-data php "${NC_PATH}/occ" config:system:set redis host --value 'localhost'
    sudo -u www-data php "${NC_PATH}/occ" config:system:set redis port --value '6379'
    # Use Redis for file locking
    sudo -u www-data php "${NC_PATH}/occ" config:system:set 'filelocking.enabled' --value='true' --type=boolean
    sudo -u www-data php "${NC_PATH}/occ" config:system:set 'memcache.locking' --value='\OC\Memcache\Redis'
    # Set default phone region
    sudo -u www-data php "${NC_PATH}/occ" config:system:set default_phone_region --value="DE"
    # Set maintenance window (to 1 AM)
    sudo -u www-data php "${NC_PATH}/occ" config:system:set maintenance_window_start --type=integer --value="1"
    
    # Reverse proxy configuration
    if [[ "$USE_REVERSE_PROXY" == "ja" ]]; then
        echo " Configuring Nextcloud to operate behind a reverse proxy..."
        sudo -u www-data php "${NC_PATH}/occ" config:system:set overwrite.cli.url --value="https://${NC_URL}"
        sudo -u www-data php "${NC_PATH}/occ" config:system:set trusted_proxies 0 --value="${REVERSE_PROXY_IP}"
        sudo -u www-data php "${NC_PATH}/occ" config:system:set overwriteprotocol --value="https"
    fi
    echo "✅ Base configuration complete."

    # 11. Set up cronjob
    echo " Setting up cronjob..."
    (crontab -u www-data -l 2>/dev/null; echo "*/5  * * * * php -f ${NC_PATH}/cron.php") | crontab -u www-data -
    sudo -u www-data php "${NC_PATH}/occ" background:cron
    echo "✅ Cronjob set up."
    
    # 12. NEW: Run expensive repair tasks (MIME types, etc.)
    echo " Running final maintenance tasks (this may take a moment)..."
    sudo -u www-data php "${NC_PATH}/occ" maintenance:repair --include-expensive
    echo "✅ Maintenance tasks complete."

    # 13. SSL, but only if NO reverse proxy is in use
    if [[ "$USE_REVERSE_PROXY" == "ja" ]]; then
        echo "ℹ️ Reverse proxy is in use. SSL/TLS must be configured on the proxy."
        FINAL_URL="https://${NC_URL}"
    else
        read -p "Would you like to set up a free SSL certificate with Let's Encrypt? (yes/no): " setup_ssl
        if [[ "$setup_ssl" == "yes" ]]; then
            apt-get install -y certbot python3-certbot-apache
            certbot --apache --non-interactive --agree-tos --redirect -d "${NC_URL}" -m "admin@${NC_URL}"
            FINAL_URL="https://${NC_URL}"
        else
            FINAL_URL="http://${NC_URL}"
        fi
    fi

    # --- Completion ---
    echo -e "\n\n🎉 Nextcloud installation was successful! 🎉"
    echo "------------------------------------------------------------------"
    echo "You can now access Nextcloud at the following address:"
    echo -e "\n    \033[1m${FINAL_URL}\033[0m\n"
    echo "Your login credentials are:"
    echo -e "  » Username: \033[1m${NC_ADMIN_USER}\033[0m"
    echo -e "  » Password: \033[1m${NC_ADMIN_PASS}\033[0m"
    echo -e "\nAfter installation, your Administration overview should no longer show any errors."
    echo "Remember to manually configure your email server settings in the Nextcloud settings."
    echo "------------------------------------------------------------------"
}

# Function to reset the admin password
reset_password() {
    echo "Resetting password for admin user '${NC_ADMIN_USER}'."
    read -s -p "Please enter the new password: " NEW_PASSWORD
    echo; read -s -p "Please confirm the new password: " CONFIRM_PASSWORD; echo

    if [ "$NEW_PASSWORD" != "$CONFIRM_PASSWORD" ]; then echo "❌ Passwords do not match. Aborting."; exit 1; fi
    if [ -z "$NEW_PASSWORD" ]; then echo "❌ Password must not be empty. Aborting."; exit 1; fi
    sudo -u www-data php "${NC_PATH}/occ" user:resetpassword "${NC_ADMIN_USER}" --password-from-env <<< "OC_PASS=${NEW_PASSWORD}"
    echo "✅ Password for '${NC_ADMIN_USER}' has been successfully reset."
}

# --- Service management functions ---
check_status() { echo "Status of Nextcloud services:"; systemctl status "${SERVICES[@]}"; }
start_services() { echo "Starting Nextcloud services..."; systemctl start "${SERVICES[@]}"; echo "✅ Services started."; }
stop_services() { echo "Stopping Nextcloud services..."; systemctl stop "${SERVICES[@]}"; echo "✅ Services stopped."; }
restart_services() { echo "Restarting Nextcloud services..."; systemctl restart "${SERVICES[@]}"; echo "✅ Services restarted."; }


# ==============================================================================
# --- MAIN LOGIC ---
# ==============================================================================

if [ "$(id -u)" -ne 0 ]; then
   echo "This script must be run as root." >&2
   exit 1
fi

if [ -f "$STATE_FILE" ]; then
    source "$STATE_FILE"
    
    echo
    echo "================ NEXTCLOUD MANAGER ================"
    if [[ "$USE_REVERSE_PROXY" == "ja" ]]; then
        echo "Installation (behind reverse proxy: ${REVERSE_PROXY_IP}) for URL '${NC_URL}' (Version: ${NC_VERSION})"
    else
        echo "Installation for URL '${NC_URL}' (Version: ${NC_VERSION})"
    fi
    echo
    echo "What would you like to do?"
    echo "--- Service Management ---"
    echo "  1) Check service status"
    echo "  2) Start services"
    echo "  3) Stop services"
    echo "  4) Restart services"
    echo "--- Installation & Maintenance ---"
    echo "  5) Reset admin password ('${NC_ADMIN_USER}')"
    echo "  6) Reinstall (DELETES CURRENT INSTALLATION)"
    echo "  7) Fully uninstall (DELETES EVERYTHING)"
    echo "  8) Cancel"
    read -p "Please choose an option [1-8]: " choice
    
    case "$choice" in
        1) check_status ;;
        2) start_services ;;
        3) stop_services ;;
        4) restart_services ;;
        5) reset_password ;;
        6)
            read -p "WARNING: This will completely delete the current Nextcloud installation. Are you sure? (yes/no): " confirm
            if [[ "$confirm" == "yes" ]]; then
                cleanup
                echo "System has been cleaned up. Please run the script again to start a fresh installation."
            else echo "Cancelled."; fi
            ;;
        7)
            read -p "WARNING: This will permanently delete ALL Nextcloud data. Are you sure? (yes/no): " confirm
            if [[ "$confirm" == "yes" ]]; then
                cleanup
                echo "Nextcloud has been completely removed."
            else echo "Cancelled."; fi
            ;;
        8) echo "Cancelled."; exit 0 ;;
        *) echo "Invalid selection. Aborting."; exit 1 ;;
    esac
else
    # First-time installation
    echo "Welcome to the Nextcloud Installer."
    echo ""

    read -p "Nextcloud version to install [29.0.4]: " NC_VERSION_INPUT
    NC_VERSION=${NC_VERSION_INPUT:-29.0.4}

    read -p "URL for Nextcloud (e.g. cloud.mycompany.com): " NC_URL
    if [ -z "$NC_URL" ]; then echo "❌ URL must not be empty."; exit 1; fi

    read -p "Username for the Nextcloud admin [admin]: " NC_ADMIN_USER_INPUT
    NC_ADMIN_USER=${NC_ADMIN_USER_INPUT:-admin}

    read -s -p "Password for the Nextcloud admin [randomly generated]: " NC_ADMIN_PASS
    if [ -z "$NC_ADMIN_PASS" ]; then
        NC_ADMIN_PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
        echo -e "\nA random password has been generated: \033[1m${NC_ADMIN_PASS}\033[0m"
    else echo; fi

    read -p "MariaDB database name [nextcloud_db]: " NC_DB_NAME_INPUT
    NC_DB_NAME=${NC_DB_NAME_INPUT:-nextcloud_db}

    read -p "MariaDB database user [nextcloud_user]: " NC_DB_USER_INPUT
    NC_DB_USER=${NC_DB_USER_INPUT:-nextcloud_user}
    
    read -s -p "Password for the MariaDB user [randomly generated]: " NC_DB_PASS
    if [ -z "$NC_DB_PASS" ]; then
        NC_DB_PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
        echo -e "\nA random password has been generated."
    else echo; fi

    # NEW: Reverse proxy prompt
    read -p "Are you running Nextcloud behind a reverse proxy? (yes/no) [no]: " USE_REVERSE_PROXY
    USE_REVERSE_PROXY=${USE_REVERSE_PROXY:-no}

    if [[ "$USE_REVERSE_PROXY" == "yes" ]]; then
        read -p "Please enter the IP address of your reverse proxy: " REVERSE_PROXY_IP
        if [ -z "$REVERSE_PROXY_IP" ]; then
            echo "❌ Reverse proxy IP address must not be empty. Aborting."
            exit 1
        fi
    fi

    # Save variables to state file
    {
        echo "NC_URL='${NC_URL}'"
        echo "NC_VERSION='${NC_VERSION}'"
        echo "NC_ADMIN_USER='${NC_ADMIN_USER}'"
        echo "NC_DB_NAME='${NC_DB_NAME}'"
        echo "NC_DB_USER='${NC_DB_USER}'"
        echo "USE_REVERSE_PROXY='${USE_REVERSE_PROXY}'"
        if [[ "$USE_REVERSE_PROXY" == "yes" ]]; then
            echo "REVERSE_PROXY_IP='${REVERSE_PROXY_IP}'"
        fi
    } > "$STATE_FILE"
    
    echo ""
    echo "Configuration complete. Installation will begin with the following values:"
    echo "--------------------------------------------------"
    echo "Version:        ${NC_VERSION}"
    echo "URL:            ${NC_URL}"
    echo "Admin user:     ${NC_ADMIN_USER}"
    if [[ "$USE_REVERSE_PROXY" == "yes" ]]; then
        echo "Reverse proxy:  Yes (IP: ${REVERSE_PROXY_IP})"
    else
        echo "Reverse proxy:  No"
    fi
    echo "--------------------------------------------------"
    read -p "Press Enter to continue, or Ctrl+C to cancel."

    installation
fi
