#!/bin/bash
set -e

# Define colors for output:
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
NC="\033[0m" # Reset color

# Paths to configuration files
CONFIG_PATH="/usr/local/etc/v2ray/config.json"
CLIENTS_DIR="v2ray-profiles"
mkdir -p "$CLIENTS_DIR"

# Function to check and install dependencies
function ensure_installed() {
    local cmd="$1"
    local package="$1"
    if [ "$cmd" == "uuidgen" ]; then
        package="uuid-runtime"
    fi
    if ! command -v "$cmd" >/dev/null 2>&1; then
        apt-get update && apt-get install -y "$package"
    fi
}

ensure_installed curl
ensure_installed uuidgen
ensure_installed jq
ensure_installed iconv

# Function to open port 443 (quiet output)
function open_port443() {
    if command -v ufw >/dev/null 2>&1; then
        if ! ufw status numbered 2>/dev/null | grep -q "443/tcp"; then
            ufw allow 443/tcp >/dev/null 2>&1
        fi
    else
        if ! iptables -C INPUT -p tcp --dport 443 -j ACCEPT >/dev/null 2>&1; then
            iptables -I INPUT -p tcp --dport 443 -j ACCEPT >/dev/null 2>&1
        fi
        iptables-save >/dev/null 2>&1
    fi
}

open_port443

# Step 1. Install V2Ray if it's not installed
if ! systemctl is-active --quiet v2ray; then
    bash <(curl -Ls https://github.com/v2fly/fhs-install-v2ray/raw/master/install-release.sh)
    apt purge -y unzip
    systemctl enable v2ray
    systemctl start v2ray
    if ! systemctl is-active --quiet v2ray; then
        echo -e "${YELLOW}🚨 Error: V2Ray is not running after installation${NC}"
        exit 1
    fi
fi

# Function to convert a string: Cyrillic to Latin and replace non-alphabetical characters with _
function to_latin_with_underscore() {
    echo "$1" | iconv -f utf-8 -t ascii//translit | sed -r 's/[^a-zA-Z0-9]+/_/g' | tr '[:upper:]' '[:lower:]'
}

# Function to save configuration and restart the service
function save_config() {
    jq '.' "$CONFIG_PATH" > "$CONFIG_PATH.tmp" && mv "$CONFIG_PATH.tmp" "$CONFIG_PATH"
    systemctl restart v2ray
}

# Function to create a new client
function create_client() {
    while true; do
        read -p "✏️  Enter profile name: " PROFILE_NAME
        SLUG=$(to_latin_with_underscore "$PROFILE_NAME")
        if [ -z "$SLUG" ]; then
            echo -e "${YELLOW}⚠️  Profile name cannot be empty. Please try again.${NC}"
        else
            break
        fi
    done

    CLIENT_UUID=$(uuidgen)
    SERVER_IP=$(curl -s ifconfig.me || echo "YOUR_SERVER_IP")
    UPDATED_CONFIG=$(jq --arg id "$CLIENT_UUID" --arg profile "$SLUG" '
      .inbounds[0].settings.clients += [{id: $id, alterId: 0, profile: $profile}]
    ' "$CONFIG_PATH")
    echo "$UPDATED_CONFIG" > "$CONFIG_PATH"
    systemctl restart v2ray

    CLIENT_JSON=$(jq -n \
        --arg v "2" \
        --arg ps "$PROFILE_NAME" \
        --arg add "$SERVER_IP" \
        --arg port "443" \
        --arg id "$CLIENT_UUID" \
        --arg aid "0" \
        --arg net "ws" \
        --arg type "none" \
        --arg host "" \
        --arg path "$WS_PATH" \
        --arg tls "tls" \
        '{
            v: $v,
            ps: $ps,
            add: $add,
            port: $port,
            id: $id,
            aid: $aid,
            net: $net,
            type: $type,
            host: $host,
            path: $path,
            tls: $tls
        }'
    )

    JSON_PATH="$CLIENTS_DIR/${SLUG}.json"
    URL_PATH="$CLIENTS_DIR/${SLUG}.url"
    echo "$CLIENT_JSON" > "$JSON_PATH"
    VMESS_LINK="vmess://$(echo -n "$CLIENT_JSON" | base64 -w 0)"
    echo "$VMESS_LINK" > "$URL_PATH"
    echo -e "✅ Client '$PROFILE_NAME' created"
}

# Step 2. Generate basic server config if not exists
SERVER_PORT=443
if ! jq -e '.inbounds' "$CONFIG_PATH" >/dev/null 2>&1; then
    WS_PATH="/$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)"
    cat > "$CONFIG_PATH" <<EOF
{
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": $SERVER_PORT,
      "protocol": "vmess",
      "settings": {
        "clients": []
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "$WS_PATH"
        },
        "security": "tls",
        "tlsSettings": {
          "alpn": ["http/1.1"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF
    systemctl restart v2ray
    # Switch to main menu (do not call create_client automatically)
else
    WS_PATH=$(jq -r '.inbounds[0].streamSettings.wsSettings.path' "$CONFIG_PATH")
fi

# Function to list clients from the config
function list_clients() {
    jq -r '.inbounds[0].settings.clients[] | "\(.profile // "unnamed")|\(.id)"' "$CONFIG_PATH"
}


# Function to revoke a client
function revoke_client() {
    mapfile -t CLIENTS < <(list_clients)
    if [ ${#CLIENTS[@]} -eq 0 ]; then
        echo -e "${YELLOW}⚠️  No clients to revoke.${NC}"
        return
    fi

    echo -e "${GREEN}⬅  [0] Back${NC}"
    for i in "${!CLIENTS[@]}"; do
        NAME=$(cut -d'|' -f1 <<< "${CLIENTS[$i]}")
        ID=$(cut -d'|' -f2 <<< "${CLIENTS[$i]}")
        echo -e "☠️  ${GREEN}[$((i+1))] ${ID} ${NAME}${NC}"
    done

    read -p "Choose client number to revoke: " CHOICE
    if [[ "$CHOICE" == "0" ]]; then 
        return 
    fi

    INDEX=$((CHOICE-1))
    if [[ $INDEX -ge 0 && $INDEX -lt ${#CLIENTS[@]} ]]; then
        REVOKE_ID=$(cut -d'|' -f2 <<< "${CLIENTS[$INDEX]}")
        UPDATED_CONFIG=$(jq --arg id "$REVOKE_ID" '(.inbounds[0].settings.clients) |= map(select(.id != $id))' "$CONFIG_PATH")
        echo "$UPDATED_CONFIG" > "$CONFIG_PATH"
        systemctl restart v2ray

        for jsonfile in "$CLIENTS_DIR"/*.json; do
            if grep -q "$REVOKE_ID" "$jsonfile" 2>/dev/null; then
                base="${jsonfile%.json}"
                rm "$jsonfile"
                if [ -f "${base}.url" ]; then
                    rm "${base}.url"
                fi
            fi
        done
        echo -e "${GREEN}✅ Client revoked${NC}"
    else
        echo -e "${YELLOW}⚠️  Invalid choice.${NC}"
    fi
}

# Function for full removal of V2Ray and client files
function full_removal() {
    WS_PATH=$(jq -r '.inbounds[0].streamSettings.wsSettings.path' "$CONFIG_PATH")
    WS_NAME="${WS_PATH#/}"
    echo -e "${RED}🚨 Attention!!! This action is irreversible!${NC}"
    echo -e "${GREEN}To cancel, press${NC} ⏎"
    echo -e "${RED}To delete, enter${NC} ${YELLOW}${WS_NAME}${NC}"
    read -p "Enter the value to confirm deletion: " CONFIRM
    if [ "$CONFIRM" = "$WS_NAME" ]; then
        systemctl stop v2ray
        systemctl disable v2ray
        rm -rf /var/log/v2ray
        rm -rf "/usr/local/etc/v2ray"
        rm -rf "/usr/local/share/v2ray"
        rm -f "/usr/local/bin/v2ray"
        rm -rf "/etc/systemd/system/v2ray.service.d"
        rm -f "/etc/systemd/system/v2ray.service"
        rm -f "/etc/systemd/system/v2ray@.service"
        rm -f "/etc/systemd/system/multi-user.target.wants/v2ray.service"
        rm -rf "$CLIENTS_DIR"
        systemctl daemon-reload
        echo -e "${GREEN}💣 Deletion complete. Don't forget to remove ${YELLOW}v2ray.sh${NC}"
        exit 0
    else
        echo -e "${YELLOW}⚠️  Invalid input. Deletion canceled.${NC}"
    fi
}

# Main menu function
function main_menu() {
    echo -e "${GREEN}🚪 [0] Exit${NC}"
    echo -e "${GREEN}👨‍ [1] Create Client${NC}"
    echo -e "${GREEN}☠️  [2] Revoke Client${NC}"
    echo -e "${RED}💣 [3] Full Removal${NC}"
    read -p "Your choice: " OPTION

    case "$OPTION" in
        1)
            create_client
            ;;
        2)
            revoke_client
            ;;
        3)
            full_removal
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${YELLOW}⚠️  Invalid choice. Try again.${NC}"
            ;;
    esac
}

while true; do
    main_menu
done
