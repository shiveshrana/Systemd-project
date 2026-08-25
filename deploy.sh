#!/bin/bash

set -e

# ============================================================
# DEPLOY.SH
# Production Application Deployment & systemd Provisioning
# ============================================================

APP_BASE_DIR="/opt"


# ============================================================
# UTILITY
# ============================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Run this script with sudo."
        exit 1
    fi
}


check_dependencies() {

    local missing=()

    command -v git >/dev/null 2>&1 || missing+=("git")
    command -v python3 >/dev/null 2>&1 || missing+=("python3")
    command -v systemctl >/dev/null 2>&1 || missing+=("systemd")

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "ERROR: Missing dependencies:"
        printf ' - %s\n' "${missing[@]}"
        exit 1
    fi
}


pause() {
    echo
    read -rp "Press Enter to continue..."
}


valid_name() {
    [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]]
}


valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] &&
    (( "$1" >= 1 && "$1" <= 65535 ))
}


# ============================================================
# DEPLOYMENT DISCOVERY
# ============================================================

get_deployments() {

    DEPLOYMENTS=()

    for directory in "$APP_BASE_DIR"/*; do

        if [[ -d "$directory" && -f "$directory/server.py" ]]; then
            DEPLOYMENTS+=("$(basename "$directory")")
        fi

    done
}


get_service_user() {

    local app="$1"
    local service="/etc/systemd/system/$app.service"

    if [[ -f "$service" ]]; then
        grep "^User=" "$service" \
            | head -n 1 \
            | cut -d'=' -f2
    else
        stat -c "%U" "$APP_BASE_DIR/$app"
    fi
}


get_service_port() {

    local app="$1"
    local service="/etc/systemd/system/$app.service"

    if [[ -f "$service" ]]; then
        grep "^ExecStart=" "$service" \
            | grep -oE '[0-9]+$' \
            | head -n 1
    else
        echo "Not configured"
    fi
}


get_service_status() {

    local app="$1"

    if [[ -f "/etc/systemd/system/$app.service" ]]; then
        systemctl is-active "$app.service" 2>/dev/null || true
    else
        echo "No service"
    fi
}


get_service_enabled() {

    local app="$1"

    if [[ -f "/etc/systemd/system/$app.service" ]]; then
        systemctl is-enabled "$app.service" 2>/dev/null || true
    else
        echo "No service"
    fi
}


# ============================================================
# SELECT DEPLOYMENT
# ============================================================

select_deployment() {

    get_deployments

    if [[ ${#DEPLOYMENTS[@]} -eq 0 ]]; then
        echo
        echo "No deployments found."
        pause
        return 1
    fi

    clear

    echo "================================================"
    echo "              EXISTING DEPLOYMENTS"
    echo "================================================"
    echo

    local index=1

    for app in "${DEPLOYMENTS[@]}"; do

        echo "[$index] $app"
        echo "    Path:    $APP_BASE_DIR/$app"
        echo "    User:    $(get_service_user "$app")"
        echo "    Service: $app.service"
        echo "    Port:    $(get_service_port "$app")"
        echo "    Status:  $(get_service_status "$app")"
        echo "    Boot:    $(get_service_enabled "$app")"
        echo

        ((index++))
    done

    echo "[0] Return"
    echo

    read -rp "Select deployment: " choice

    if [[ "$choice" == "0" ]]; then
        return 1
    fi

    if ! [[ "$choice" =~ ^[0-9]+$ ]] ||
       (( choice < 1 || choice > ${#DEPLOYMENTS[@]} )); then

        echo
        echo "Invalid selection."
        pause
        return 1
    fi

    SELECTED_APP="${DEPLOYMENTS[$((choice - 1))]}"
    SELECTED_PATH="$APP_BASE_DIR/$SELECTED_APP"

    return 0
}


# ============================================================
# DEPLOY APPLICATION
# ============================================================

deploy_application() {

    clear

    echo "================================================"
    echo "              DEPLOY NEW APPLICATION"
    echo "================================================"
    echo

    read -rp "Git repository URL: " REPO_URL
    read -rp "Application name: " APP_NAME
    read -rp "Linux service user: " SERVICE_USER
    read -rp "Application port [8000]: " PORT

    PORT="${PORT:-8000}"

    # --------------------------------------------------------
    # Validation
    # --------------------------------------------------------

    if [[ -z "$REPO_URL" ||
          -z "$APP_NAME" ||
          -z "$SERVICE_USER" ]]; then

        echo
        echo "ERROR: All fields are required."
        pause
        return
    fi

    if ! valid_name "$APP_NAME"; then

        echo
        echo "ERROR: Invalid application name."
        echo "Allowed: letters, numbers, - and _"
        pause
        return
    fi

    if ! valid_name "$SERVICE_USER"; then

        echo
        echo "ERROR: Invalid service username."
        echo "Allowed: letters, numbers, - and _"
        pause
        return
    fi

    if ! valid_port "$PORT"; then

        echo
        echo "ERROR: Invalid port."
        pause
        return
    fi


    APP_PATH="$APP_BASE_DIR/$APP_NAME"
    SERVICE_FILE="/etc/systemd/system/$APP_NAME.service"


    if [[ -d "$APP_PATH" ]]; then

        echo
        echo "ERROR: Application already exists:"
        echo "$APP_PATH"
        pause
        return
    fi


    if [[ -f "$SERVICE_FILE" ]]; then

        echo
        echo "ERROR: systemd service already exists:"
        echo "$SERVICE_FILE"
        pause
        return
    fi


    # --------------------------------------------------------
    # Show configuration
    # --------------------------------------------------------

    echo
    echo "Deployment configuration"
    echo "-----------------------------------------------"
    echo "Repository:   $REPO_URL"
    echo "Application:  $APP_NAME"
    echo "Location:     $APP_PATH"
    echo "User:         $SERVICE_USER"
    echo "Port:         $PORT"
    echo "Service:      $APP_NAME.service"
    echo

    read -rp "Continue? (y/n): " CONFIRM

    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then

        echo
        echo "Deployment cancelled."
        pause
        return
    fi


    TEMP_DIR=$(mktemp -d)

    # Always clean temporary directory
    trap 'rm -rf "$TEMP_DIR"' RETURN


    # --------------------------------------------------------
    # Clone
    # --------------------------------------------------------

    echo
    echo "[1/6] Cloning repository..."

    if ! git clone "$REPO_URL" "$TEMP_DIR"; then

        echo
        echo "ERROR: Git clone failed."
        pause
        return
    fi


    # --------------------------------------------------------
    # Validate application
    # --------------------------------------------------------

    echo
    echo "[2/6] Validating application..."

    if [[ ! -f "$TEMP_DIR/server.py" ]]; then

        echo
        echo "ERROR: server.py not found."
        pause
        return
    fi

    if [[ ! -f "$TEMP_DIR/index.html" ]]; then

        echo
        echo "WARNING: index.html not found."
        echo "The application may not display a web page."
    fi

    if [[ ! -f "$TEMP_DIR/style.css" ]]; then
        echo "WARNING: style.css not found."
    fi

    if [[ ! -f "$TEMP_DIR/script.js" ]]; then
        echo "WARNING: script.js not found."
    fi

    echo "Application validation complete."


    # --------------------------------------------------------
    # Deploy
    # --------------------------------------------------------

    echo
    echo "[3/6] Deploying application..."

    mv "$TEMP_DIR" "$APP_PATH"


    # --------------------------------------------------------
    # User
    # --------------------------------------------------------

    echo
    echo "[4/6] Configuring service user..."

    if id "$SERVICE_USER" &>/dev/null; then

        echo "User '$SERVICE_USER' already exists."

    else

        useradd \
            --system \
            --no-create-home \
            --shell /usr/sbin/nologin \
            "$SERVICE_USER"

        echo "User '$SERVICE_USER' created."
    fi


    # --------------------------------------------------------
    # Permissions
    # --------------------------------------------------------

    echo
    echo "[5/6] Configuring permissions..."

    chown -R "$SERVICE_USER:$SERVICE_USER" "$APP_PATH"

    find "$APP_PATH" \
        -type d \
        -exec chmod 755 {} \;

    find "$APP_PATH" \
        -type f \
        -exec chmod 644 {} \;

    chmod 755 "$APP_PATH/server.py"


    # --------------------------------------------------------
    # systemd
    # --------------------------------------------------------

    echo
    echo "[6/6] Creating systemd service..."

    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=$APP_NAME Web Application
After=network.target

[Service]
Type=simple

User=$SERVICE_USER
Group=$SERVICE_USER

WorkingDirectory=$APP_PATH

ExecStart=/usr/bin/python3 $APP_PATH/server.py $PORT

Restart=on-failure
RestartSec=5

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true

# Allow the application to access its own directory
ReadWritePaths=$APP_PATH

[Install]
WantedBy=multi-user.target
EOF


    # --------------------------------------------------------
    # Validate systemd unit
    # --------------------------------------------------------

    systemctl daemon-reload

    if ! systemd-analyze verify "$SERVICE_FILE"; then

        echo
        echo "ERROR: systemd service validation failed."

        rm -f "$SERVICE_FILE"

        systemctl daemon-reload

        echo
        echo "Deployment was not completed."

        pause
        return
    fi


    systemctl enable "$APP_NAME.service"


    # --------------------------------------------------------
    # Complete
    # --------------------------------------------------------

    echo
    echo "================================================"
    echo "              DEPLOYMENT COMPLETE"
    echo "================================================"
    echo

    echo "Application:  $APP_NAME"
    echo "Location:     $APP_PATH"
    echo "User:         $SERVICE_USER"
    echo "Port:         $PORT"
    echo "Service:      $APP_NAME.service"
    echo "Boot:         enabled"

    echo
    echo "Security:"
    echo "  NoNewPrivileges=true"
    echo "  PrivateTmp=true"
    echo "  ProtectSystem=strict"
    echo "  ProtectHome=true"

    echo
    echo "The application has NOT been started."

    echo
    echo "Start/manage it using:"
    echo
    echo "sudo ./application-manager.sh"

    pause
}


# ============================================================
# VIEW DEPLOYMENTS
# ============================================================

view_deployments() {

    select_deployment || return

    clear

    echo "================================================"
    echo "             DEPLOYMENT INFORMATION"
    echo "================================================"
    echo

    echo "Application:  $SELECTED_APP"
    echo "Path:         $SELECTED_PATH"
    echo "User:         $(get_service_user "$SELECTED_APP")"
    echo "Service:      $SELECTED_APP.service"
    echo "Port:         $(get_service_port "$SELECTED_APP")"
    echo "Status:       $(get_service_status "$SELECTED_APP")"
    echo "Boot:         $(get_service_enabled "$SELECTED_APP")"

    echo
    echo "Application files"
    echo "-----------------------------------------------"

    ls -la "$SELECTED_PATH"

    pause
}


# ============================================================
# REMOVE DEPLOYMENT
# ============================================================

remove_deployment() {

    select_deployment || return

    APP_NAME="$SELECTED_APP"
    APP_PATH="$SELECTED_PATH"
    SERVICE_FILE="/etc/systemd/system/$APP_NAME.service"
    SERVICE_USER="$(get_service_user "$APP_NAME")"


    clear

    echo "================================================"
    echo "                REMOVE DEPLOYMENT"
    echo "================================================"
    echo

    echo "Application: $APP_NAME"
    echo "Path:        $APP_PATH"
    echo "User:        $SERVICE_USER"
    echo "Service:     $APP_NAME.service"

    echo
    echo "WARNING: This permanently removes the application."
    echo

    read -rp "Type DELETE to confirm: " CONFIRM

    if [[ "$CONFIRM" != "DELETE" ]]; then

        echo
        echo "Removal cancelled."
        pause
        return
    fi


    echo
    echo "Stopping service..."

    systemctl stop "$APP_NAME.service" 2>/dev/null || true


    echo "Disabling service..."

    systemctl disable "$APP_NAME.service" 2>/dev/null || true


    echo "Removing service..."

    rm -f "$SERVICE_FILE"

    systemctl daemon-reload


    echo "Removing application..."

    rm -rf "$APP_PATH"


    # --------------------------------------------------------
    # Remove dedicated system user
    # --------------------------------------------------------

    if id "$SERVICE_USER" &>/dev/null; then

        echo "Removing service user..."

        userdel "$SERVICE_USER" 2>/dev/null || true

    fi


    echo
    echo "================================================"
    echo "             DEPLOYMENT REMOVED"
    echo "================================================"

    pause
}


# ============================================================
# MAIN MENU
# ============================================================

check_root
check_dependencies


while true; do

    clear

    echo "================================================"
    echo "        APPLICATION DEPLOYMENT MANAGER"
    echo "================================================"
    echo

    echo "1. Deploy New Application"
    echo "2. View Existing Deployments"
    echo "3. Remove Deployment"
    echo "4. Exit"

    echo

    read -rp "Choose an option [1-4]: " CHOICE


    case "$CHOICE" in

        1)
            deploy_application
            ;;

        2)
            view_deployments
            ;;

        3)
            remove_deployment
            ;;

        4)
            echo
            echo "Exiting deployment manager."
            exit 0
            ;;

        *)
            echo
            echo "Invalid option."
            sleep 2
            ;;

    esac

done