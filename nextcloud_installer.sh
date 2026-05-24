#!/bin/bash

# ==============================================================================
# Nextcloud Installer & Manager (Intelligent & Interactive)
# for Debian 12 / Ubuntu 22.04 – v3.0 (with bug fixes)
#
# - Fixes all known errors from the Nextcloud administration overview.
# - Configures Redis file locking, Imagick-SVG, maintenance windows, etc.
# - Solves the “server-to-itself” connection problem in containers.
# ==============================================================================

set -e  # Immediately terminates the script if a command fails

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

    echo "✅ Cleanup completed."
}

# Function for the installation process
installation() {
    # 1. Prepare system
    echo " Performing system updates and installing base packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get upgrade -y
    apt-get install -y sudo curl wget unzip tar software-properties-common dirmngr apt-transport-https gnupg2 ca-certificates lsb-release
    echo "✅ System preparation completed."

    # 2. Install PHP and required extensions
    echo " Installing PHP 8.2 and all required extensions (including Imagick-SVG)..."
    if ! apt-key list | grep -q "ondrej/php"; then
        curl -sSLo /usr/share/keyrings/deb.sury.org-php.gpg https://packages.sury.org/php/apt.gpg
        sh -c 'echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" > /etc/apt/sources.list.d/php.list'
        apt-get update
    fi

    apt-get install -y php8.2 libapache2-mod-php8.2
    apt-get install -y \
        php8.2-gd php8.2-mysql php8.2-curl php8.2-mbstring php8.2-intl \
        php8.2-gmp php8.2-bcmath php8.2-xml php8.2-zip php8.2-imagick \
        php8.2-redis php8.2-apcu imagemagick  # Ensure full ImageMagick with SVG support is installed
    echo "✅ PHP installation completed."

    # 3. Install webserver, database, and cache
    echo " Installing and configuring Apache,
