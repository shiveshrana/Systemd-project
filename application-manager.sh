#!/bin/bash

# ============================================================
# APPLICATION-MANAGER.SH
# Production Application Lifecycle Manager
#
# Responsibilities:
#   - Start
#   - Stop
#   - Restart
#   - Status
#   - Logs
#   - Live logs
#   - Enable / Disable
#   - Health check
#   - Application information
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


pause() {

    echo
    read -rp "Press Enter to continue..."
}


# ============================================================
# DISCOVER APPLICATIONS
# ============================================================

get_deployments() {

    DEPLOYMENTS=()

    for directory in "$APP_BASE_DIR"/*; do

        if [[ -d "$directory" &&
              -f "$directory/server.py" ]]; then

            DEPLOYMENTS+=("$(basename "$directory")")

        fi

    done
}


# ============================================================
# INFORMATION
# ============================================================

get_service_user() {

    local app="$1"
    local service="/etc/systemd/system/$app.service"

    if [[ -f "$service" ]]; then

        grep "^User=" "$service" \
            | head -n 1 \
            | cut -d'=' -f2

    else

        echo "Unknown"

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

        echo "Unknown"

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
# SELECT APPLICATION
# ============================================================

select_application() {

    get_deployments


    if [[ ${#DEPLOYMENTS[@]} -eq 0 ]]; then

        echo
        echo "No deployed applications found."

        pause

        return 1
    fi


    clear

    echo "================================================"
    echo "              SELECT APPLICATION"
    echo "================================================"
    echo


    local index=1


    for app in "${DEPLOYMENTS[@]}"; do

        echo "[$index] $app"
        echo "    Path:    $APP_BASE_DIR/$app"
        echo "    User:    $(get_service_user "$app")"
        echo "    Service: $app.service"
        echo "    Port:    $(get_service_port "$app")"
        echo "    Status: $(get_service_status "$app")"
        echo "    Boot:    $(get_service_enabled "$app")"
        echo

        ((index++))

    done


    echo "[0] Return"
    echo

    read -rp "Select application: " CHOICE


    if [[ "$CHOICE" == "0" ]]; then
        return 1
    fi


    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] ||
       (( CHOICE < 1 || CHOICE > ${#DEPLOYMENTS[@]} )); then

        echo
        echo "Invalid selection."

        pause

        return 1
    fi


    SELECTED_APP="${DEPLOYMENTS[$((CHOICE - 1))]}"
    SELECTED_PATH="$APP_BASE_DIR/$SELECTED_APP"
    SELECTED_SERVICE="$SELECTED_APP.service"
    SELECTED_USER="$(get_service_user "$SELECTED_APP")"
    SELECTED_PORT="$(get_service_port "$SELECTED_APP")"


    if [[ ! -f "/etc/systemd/system/$SELECTED_SERVICE" ]]; then

        echo
        echo "ERROR: systemd service not found."

        echo
        echo "Expected:"
        echo "/etc/systemd/system/$SELECTED_SERVICE"

        pause

        return 1
    fi


    return 0
}


# ============================================================
# START
# ============================================================

start_service() {

    select_application || return


    echo
    echo "Starting $SELECTED_SERVICE..."

    systemctl start "$SELECTED_SERVICE"

    sleep 2


    if systemctl is-active --quiet "$SELECTED_SERVICE"; then

        echo
        echo "SUCCESS: Application is running."

    else

        echo
        echo "ERROR: Application failed to start."

        echo
        echo "Recent logs:"
        journalctl \
            -u "$SELECTED_SERVICE" \
            -n 20 \
            --no-pager

    fi


    pause
}


# ============================================================
# STOP
# ============================================================

stop_service() {

    select_application || return


    echo
    echo "Stopping $SELECTED_SERVICE..."

    systemctl stop "$SELECTED_SERVICE"


    if ! systemctl is-active --quiet "$SELECTED_SERVICE"; then

        echo
        echo "SUCCESS: Application stopped."

    else

        echo
        echo "ERROR: Application is still running."

    fi


    pause
}


# ============================================================
# RESTART
# ============================================================

restart_service() {

    select_application || return


    echo
    echo "Restarting $SELECTED_SERVICE..."

    systemctl restart "$SELECTED_SERVICE"

    sleep 2


    if systemctl is-active --quiet "$SELECTED_SERVICE"; then

        echo
        echo "SUCCESS: Application restarted."

    else

        echo
        echo "ERROR: Application failed to restart."

        echo
        journalctl \
            -u "$SELECTED_SERVICE" \
            -n 20 \
            --no-pager

    fi


    pause
}


# ============================================================
# STATUS
# ============================================================

service_status() {

    select_application || return


    clear

    echo "================================================"
    echo "             SYSTEMD SERVICE STATUS"
    echo "================================================"
    echo

    systemctl status \
        "$SELECTED_SERVICE" \
        --no-pager


    pause
}


# ============================================================
# RECENT LOGS
# ============================================================

view_logs() {

    select_application || return


    clear

    echo "================================================"
    echo "              APPLICATION LOGS"
    echo "================================================"
    echo


    read -rp "Number of lines [50]: " LINES

    LINES="${LINES:-50}"


    if ! [[ "$LINES" =~ ^[0-9]+$ ]]; then

        echo
        echo "Invalid number."

        pause
        return
    fi


    journalctl \
        -u "$SELECTED_SERVICE" \
        -n "$LINES" \
        --no-pager


    pause
}


# ============================================================
# LIVE LOGS
# ============================================================

live_logs() {

    select_application || return


    clear

    echo "================================================"
    echo "               LIVE APPLICATION LOGS"
    echo "================================================"
    echo
    echo "Press Ctrl+C to stop."
    echo


    journalctl \
        -u "$SELECTED_SERVICE" \
        -f
}


# ============================================================
# ENABLE
# ============================================================

enable_service() {

    select_application || return


    echo
    echo "Enabling $SELECTED_SERVICE..."

    systemctl enable "$SELECTED_SERVICE"


    echo
    echo "SUCCESS: Application enabled at boot."

    pause
}


# ============================================================
# DISABLE
# ============================================================

disable_service() {

    select_application || return


    echo
    echo "Disabling $SELECTED_SERVICE..."

    systemctl disable "$SELECTED_SERVICE"


    echo
    echo "SUCCESS: Application disabled at boot."

    pause
}


# ============================================================
# HEALTH CHECK
# ============================================================

health_check() {

    select_application || return


    clear

    echo "================================================"
    echo "             APPLICATION HEALTH CHECK"
    echo "================================================"
    echo

    echo "Application: $SELECTED_APP"
    echo "Service:     $SELECTED_SERVICE"
    echo "User:        $SELECTED_USER"
    echo "Port:        $SELECTED_PORT"

    echo


    # --------------------------------------------------------
    # systemd check
    # --------------------------------------------------------

    if systemctl is-active --quiet "$SELECTED_SERVICE"; then

        echo "systemd:     RUNNING"

    else

        echo "systemd:     NOT RUNNING"

    fi


    # --------------------------------------------------------
    # HTTP check
    # --------------------------------------------------------

    if [[ "$SELECTED_PORT" == "Unknown" ||
          -z "$SELECTED_PORT" ]]; then

        echo "HTTP:        UNKNOWN"

        pause
        return
    fi


    if ! command -v curl &>/dev/null; then

        echo "HTTP:        curl not installed"

        pause
        return
    fi


    HTTP_CODE=$(curl \
        -s \
        -o /dev/null \
        -w "%{http_code}" \
        --max-time 5 \
        "http://127.0.0.1:$SELECTED_PORT" \
        || true)


    if [[ "$HTTP_CODE" =~ ^[23][0-9][0-9]$ ]]; then

        echo "HTTP:        HEALTHY ($HTTP_CODE)"

    else

        echo "HTTP:        UNHEALTHY (${HTTP_CODE:-No response})"

    fi


    pause
}


# ============================================================
# APPLICATION INFORMATION
# ============================================================

application_info() {

    select_application || return


    clear

    echo "================================================"
    echo "            APPLICATION INFORMATION"
    echo "================================================"
    echo

    echo "Application:  $SELECTED_APP"
    echo "Path:         $SELECTED_PATH"
    echo "User:         $SELECTED_USER"
    echo "Service:      $SELECTED_SERVICE"
    echo "Port:         $SELECTED_PORT"
    echo "Status:       $(get_service_status "$SELECTED_APP")"
    echo "Boot:         $(get_service_enabled "$SELECTED_APP")"

    echo
    echo "systemd security"
    echo "-----------------------------------------------"

    echo "NoNewPrivileges:  $(systemctl show "$SELECTED_SERVICE" -p NoNewPrivileges --value)"
    echo "PrivateTmp:       $(systemctl show "$SELECTED_SERVICE" -p PrivateTmp --value)"
    echo "ProtectSystem:    $(systemctl show "$SELECTED_SERVICE" -p ProtectSystem --value)"
    echo "ProtectHome:      $(systemctl show "$SELECTED_SERVICE" -p ProtectHome --value)"

    echo
    echo "Application files"
    echo "-----------------------------------------------"

    ls -la "$SELECTED_PATH"

    pause
}


# ============================================================
# MAIN MENU
# ============================================================

check_root


while true; do

    clear

    echo "================================================"
    echo "        APPLICATION LIFECYCLE MANAGER"
    echo "================================================"
    echo

    echo "1.  Start Application"
    echo "2.  Stop Application"
    echo "3.  Restart Application"
    echo "4.  Check Status"
    echo "5.  View Recent Logs"
    echo "6.  Follow Live Logs"
    echo "7.  Enable Auto-start"
    echo "8.  Disable Auto-start"
    echo "9.  Health Check"
    echo "10. Application Information"
    echo "11. Exit"

    echo

    read -rp "Choose an option [1-11]: " CHOICE


    case "$CHOICE" in

        1)
            start_service
            ;;

        2)
            stop_service
            ;;

        3)
            restart_service
            ;;

        4)
            service_status
            ;;

        5)
            view_logs
            ;;

        6)
            live_logs
            ;;

        7)
            enable_service
            ;;

        8)
            disable_service
            ;;

        9)
            health_check
            ;;

        10)
            application_info
            ;;

        11)
            echo
            echo "Exiting Application Lifecycle Manager."
            exit 0
            ;;

        *)
            echo
            echo "Invalid option."
            sleep 2
            ;;

    esac

done