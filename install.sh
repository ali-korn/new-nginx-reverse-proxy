#!/bin/bash

#colors
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
blue='\033[0;34m'
purple='\033[0;35m'
cyan='\033[0;36m'
rest='\033[0m'

# Check for root user
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

NGINX_AVAIL="/etc/nginx/sites-available"
NGINX_ENABLED="/etc/nginx/sites-enabled"
DOMAINS_LIST="/etc/nginx/nrp_domains.list"
touch "$DOMAINS_LIST"

# Detect the Linux distribution
detect_distribution() {
    if [ -f /etc/os-release ]; then
        source /etc/os-release
        if [[ "${ID}" = "ubuntu" || "${ID}" = "debian" || "${ID}" = "centos" || "${ID}" = "fedora" ]]; then
            p_m="apt-get"
            [ "${ID}" = "centos" ] && p_m="yum"
            [ "${ID}" = "fedora" ] && p_m="dnf"
        else
            echo "Unsupported distribution!"
            exit 1
        fi
    else
        echo "Unsupported distribution!"
        exit 1
    fi
}

# Check dependencies
check_dependencies() {
    detect_distribution
    "${p_m}" -y update
    local dependencies=("nginx" "git" "wget" "certbot" "ufw" "python3-certbot-nginx" "bc")
    for dep in "${dependencies[@]}"; do
        if ! command -v "${dep}" &> /dev/null && ! dpkg -l | grep -q "^ii  ${dep} "; then
            echo -e "${yellow}${dep} is not installed. Installing...${rest}"
            "${p_m}" install "${dep}" -y
        fi
    done
}

display_error() {
  echo -e "${red}Error: $1${rest}"
}

domain_exists() {
    grep -qx "$1" "$DOMAINS_LIST" 2>/dev/null
}

# --------------------------------------------------
# انتخاب یک دامنه از لیست دامنه‌های موجود
# --------------------------------------------------
select_domain() {
    if [ ! -s "$DOMAINS_LIST" ]; then
        echo -e "${red}هیچ دامنه‌ای ثبت نشده. اول از گزینه Add Domain استفاده کن.${rest}"
        return 1
    fi
    echo -e "${cyan}دامنه‌های موجود:${rest}"
    mapfile -t d_arr < "$DOMAINS_LIST"
    local i=1
    for d in "${d_arr[@]}"; do
        echo -e "  ${yellow}${i}) ${green}${d}${rest}"
        ((i++))
    done
    read -p "شماره دامنه را انتخاب کن: " d_idx
    if ! [[ "$d_idx" =~ ^[0-9]+$ ]] || [ "$d_idx" -lt 1 ] || [ "$d_idx" -gt "${#d_arr[@]}" ]; then
        display_error "انتخاب نامعتبر"
        return 1
    fi
    SELECTED_DOMAIN="${d_arr[$((d_idx-1))]}"
    return 0
}

# --------------------------------------------------
# افزودن دامنه جدید با path های xhttp و httpupgrade
# --------------------------------------------------
add_domain() {
    check_dependencies

    echo -e "${yellow}×××××××××××××××××××××××${rest}"
    read -p "Enter your domain name: " domain
    if [ -z "$domain" ]; then
        display_error "دامنه نمی‌تواند خالی باشد"
        return
    fi
    if domain_exists "$domain"; then
        echo -e "${yellow}این دامنه از قبل اضافه شده است.${rest}"
        return
    fi

    echo -e "${yellow}×××××××××××××××××××××××${rest}"
    read -p "Enter GRPC Path (Service Name) [default: grpc]: " grpc_path
    grpc_path=${grpc_path:-grpc}
    echo -e "${yellow}×××××××××××××××××××××××${rest}"
    read -p "Enter WebSocket Path [default: ws]: " ws_path
    ws_path=${ws_path:-ws}
    echo -e "${yellow}×××××××××××××××××××××××${rest}"
    read -p "Enter XHTTP Path [default: xhttp]: " xhttp_path
    xhttp_path=${xhttp_path:-xhttp}
    echo -e "${yellow}×××××××××××××××××××××××${rest}"
    read -p "Enter HTTPUpgrade Path [default: httpupgrade]: " httpupgrade_path
    httpupgrade_path=${httpupgrade_path:-httpupgrade}
    echo -e "${yellow}×××××××××××××××××××××××${rest}"

    mkdir -p "/var/www/$domain"
    echo "<h1>$domain</h1>" > "/var/www/$domain/index.html"

    # Copy default NGINX config as a starting point
    cp /etc/nginx/sites-available/default "$NGINX_AVAIL/$domain" || { display_error "Failed to copy NGINX config"; return; }
    ln -sf "$NGINX_AVAIL/$domain" "$NGINX_ENABLED/" || { display_error "Failed to enable site"; return; }

    sed -i -e 's/listen 80 default_server;/listen 80;/g' \
           -e 's/listen \[::\]:80 default_server;/listen \[::\]:80;/g' \
           -e "s/server_name _;/server_name $domain;/g" "$NGINX_AVAIL/$domain"

    systemctl restart nginx || { display_error "Failed to restart NGINX"; return; }

    ufw allow 80/tcp > /dev/null 2>&1
    ufw allow 443/tcp > /dev/null 2>&1

    echo -e "${green}Getting SSL certificate...${rest}"
    certbot --nginx -d "$domain" --register-unsafely-without-email --non-interactive --agree-tos --redirect
    if [ ! -d "/etc/letsencrypt/live/$domain" ]; then
        display_error "SSL certificate could not be obtained. Aborting."
        rm -f "$NGINX_AVAIL/$domain" "$NGINX_ENABLED/$domain"
        systemctl restart nginx
        return
    fi

    # Final config with xhttp + httpupgrade locations
    cat <<EOL > "$NGINX_AVAIL/$domain"
server {
        root /var/www/$domain;
        index index.html index.htm;
        server_name $domain;

        location / {
                try_files \$uri \$uri/ =404;
        }

        # GRPC_LOCATION
        location ~ ^/${grpc_path}/(?<port>\d+)/(.*)\$ {
            if (\$content_type !~ "application/grpc") {
                return 404;
            }
            client_max_body_size 0;
            client_body_buffer_size 512k;
            grpc_set_header X-Real-IP \$remote_addr;
            client_body_timeout 1w;
            grpc_read_timeout 1w;
            grpc_send_timeout 1w;
            grpc_pass grpc://127.0.0.1:\$port;
        }

        # WS_LOCATION
        location ~ ^/${ws_path}/(?<port>\d+)\$ {
            if (\$http_upgrade != "websocket") {
                return 404;
            }
            proxy_pass http://127.0.0.1:\$port/;
            proxy_redirect off;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        }

        # XHTTP_LOCATION
        location ~ ^/${xhttp_path}/(?<port>\d+)\$ {
            client_max_body_size 0;
            client_body_buffer_size 512k;
            proxy_http_version 1.1;
            proxy_pass http://127.0.0.1:\$port;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_redirect off;
            proxy_buffering off;
            proxy_read_timeout 1d;
            proxy_send_timeout 1d;
        }

        # HTTPUPGRADE_LOCATION
        location ~ ^/${httpupgrade_path}/(?<port>\d+)\$ {
            if (\$http_upgrade != "websocket") {
                return 404;
            }
            proxy_pass http://127.0.0.1:\$port;
            proxy_redirect off;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        }

    listen [::]:443 ssl http2 ipv6only=on; # managed by Certbot
    listen 443 ssl http2; # managed by Certbot
    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem; # managed by Certbot
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem; # managed by Certbot
    include /etc/letsencrypt/options-ssl-nginx.conf; # managed by Certbot
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem; # managed by Certbot
}
server {
    if (\$host = $domain) {
        return 301 https://\$host\$request_uri;
    } # managed by Certbot
        listen 80;
        listen [::]:80;
        server_name $domain;
    return 404; # managed by Certbot
}
EOL

    nginx -t && systemctl restart nginx || { display_error "NGINX config test failed"; return; }

    echo "$domain" >> "$DOMAINS_LIST"

    # Global certbot renewal cron (idempotent)
    (crontab -l 2>/dev/null | grep -v 'certbot renew --nginx --non-interactive --post-hook "nginx -s reload"' ; echo '0 0 1 * * certbot renew --nginx --non-interactive --post-hook "nginx -s reload" > /dev/null 2>&1;') | crontab -

    echo ""
    echo -e "${purple}Domain added successfully:${rest}"
    echo -e "${yellow}×××××××××××××××××××××××××××××××××××××××××××××××××××××${rest}"
    echo -e "${cyan}Domain:          ${green}$domain${rest}"
    echo -e "${cyan}GRPC Path:       ${green}/${grpc_path}/<port>/...${rest}"
    echo -e "${cyan}WebSocket Path:  ${green}/${ws_path}/<port>${rest}"
    echo -e "${cyan}XHTTP Path:      ${green}/${xhttp_path}/<port>${rest}"
    echo -e "${cyan}HTTPUpgrade Path:${green} /${httpupgrade_path}/<port>${rest}"
    echo -e "${yellow}×××××××××××××××××××××××××××××××××××××××××××××××××××××${rest}"
    echo -e "${cyan}🌟 Installed Successfully.🌟${rest}"
}

# --------------------------------------------------
# نمایش لیست دامنه‌ها همراه با مسیرهای فعلی هرکدام
# --------------------------------------------------
list_domains() {
    if [ ! -s "$DOMAINS_LIST" ]; then
        echo -e "${red}هیچ دامنه‌ای ثبت نشده.${rest}"
        return
    fi
    echo -e "${yellow}×××××××××××××××××××××××××××××××××××××××${rest}"
    while read -r d; do
        [ -z "$d" ] && continue
        conf="$NGINX_AVAIL/$d"
        gp=$(grep -A1 "# GRPC_LOCATION" "$conf" 2>/dev/null | grep -oP '(?<=\^/)[^/]+(?=/\(\?<port>)')
        wp=$(grep -A1 "# WS_LOCATION" "$conf" 2>/dev/null | grep -oP '(?<=\^/)[^/]+(?=/\(\?<port>)')
        xp=$(grep -A1 "# XHTTP_LOCATION" "$conf" 2>/dev/null | grep -oP '(?<=\^/)[^/]+(?=/\(\?<port>)')
        hp=$(grep -A1 "# HTTPUPGRADE_LOCATION" "$conf" 2>/dev/null | grep -oP '(?<=\^/)[^/]+(?=/\(\?<port>)')
        echo -e "${cyan}Domain: ${green}$d${rest}"
        echo -e "  GRPC:        /${gp}/<port>/..."
        echo -e "  WebSocket:   /${wp}/<port>"
        echo -e "  XHTTP:       /${xp}/<port>"
        echo -e "  HTTPUpgrade: /${hp}/<port>"
        echo -e "${yellow}-----------------------------------------${rest}"
    done < "$DOMAINS_LIST"
}

# --------------------------------------------------
# تغییر مسیر xhttp / httpupgrade برای یک دامنه
# --------------------------------------------------
change_path() {
    select_domain || return
    domain="$SELECTED_DOMAIN"
    conf="$NGINX_AVAIL/$domain"

    echo -e "${yellow}×××××××××××××××××××××××${rest}"
    read -p "Enter the new GRPC path [leave empty to keep current]: " new_grpc
    read -p "Enter the new WebSocket path [leave empty to keep current]: " new_ws
    read -p "Enter the new XHTTP path [leave empty to keep current]: " new_xhttp
    read -p "Enter the new HTTPUpgrade path [leave empty to keep current]: " new_httpupgrade
    echo -e "${yellow}×××××××××××××××××××××××${rest}"

    cp "$conf" "${conf}.bak.$(date +%s)"

    if [ -n "$new_grpc" ]; then
        awk -v np="$new_grpc" '
            /# GRPC_LOCATION/ { print; getline; print "        location ~ ^/" np "/(?<port>\\d+)/(.*)$ {"; next }
            { print }
        ' "$conf" > "${conf}.tmp" && mv "${conf}.tmp" "$conf"
    fi

    if [ -n "$new_ws" ]; then
        awk -v np="$new_ws" '
            /# WS_LOCATION/ { print; getline; print "        location ~ ^/" np "/(?<port>\\d+)$ {"; next }
            { print }
        ' "$conf" > "${conf}.tmp" && mv "${conf}.tmp" "$conf"
    fi

    if [ -n "$new_xhttp" ]; then
        awk -v np="$new_xhttp" '
            /# XHTTP_LOCATION/ { print; getline; print "        location ~ ^/" np "/(?<port>\\d+)$ {"; next }
            { print }
        ' "$conf" > "${conf}.tmp" && mv "${conf}.tmp" "$conf"
    fi

    if [ -n "$new_httpupgrade" ]; then
        awk -v np="$new_httpupgrade" '
            /# HTTPUPGRADE_LOCATION/ { print; getline; print "        location ~ ^/" np "/(?<port>\\d+)$ {"; next }
            { print }
        ' "$conf" > "${conf}.tmp" && mv "${conf}.tmp" "$conf"
    fi

    if nginx -t; then
        systemctl restart nginx
        echo -e "${green}Paths updated successfully for $domain${rest}"
    else
        display_error "NGINX config test failed, restoring backup"
        cp "${conf}.bak."* "$conf" 2>/dev/null
    fi
}

# --------------------------------------------------
# تغییر پورت HTTPS برای یک دامنه
# --------------------------------------------------
change_port() {
    select_domain || return
    domain="$SELECTED_DOMAIN"
    conf="$NGINX_AVAIL/$domain"

    current_port=$(grep -oP "listen \[::\]:\K\d+(?= ssl)" "$conf" | head -1)
    echo -e "${yellow}×××××××××××××××××××××××${rest}"
    echo -e "${cyan}Current HTTPS port for $domain: ${purple}$current_port${rest}"
    read -p "Enter the new HTTPS port [default: 443]: " new_port
    new_port=${new_port:-443}
    echo -e "${yellow}×××××××××××××××××××××××${rest}"

    sed -i "s/listen \[::\]:$current_port ssl http2 ipv6only=on;/listen [::]:$new_port ssl http2 ipv6only=on;/g" "$conf"
    sed -i "s/listen $current_port ssl http2;/listen $new_port ssl http2;/g" "$conf"

    if nginx -t; then
        systemctl restart nginx
        if [ "$new_port" != "443" ]; then
            ufw allow "$new_port"/tcp > /dev/null 2>&1
        fi
        echo -e "${green}✅ HTTPS port changed to $new_port for $domain${rest}"
    else
        display_error "NGINX config test failed"
    fi
}

# --------------------------------------------------
# حذف یک دامنه (کانفیگ + سرتیفیکیت)
# --------------------------------------------------
remove_domain() {
    select_domain || return
    domain="$SELECTED_DOMAIN"

    read -p "Are you sure you want to remove $domain? (y/n): " ans
    [ "$ans" != "y" ] && return

    rm -f "$NGINX_ENABLED/$domain" "$NGINX_AVAIL/$domain" "$NGINX_AVAIL/${domain}.bak."*
    rm -rf "/etc/letsencrypt/live/$domain" "/etc/letsencrypt/archive/$domain" "/etc/letsencrypt/renewal/${domain}.conf"
    rm -rf "/var/www/$domain"
    sed -i "\|^${domain}\$|d" "$DOMAINS_LIST"

    systemctl restart nginx
    echo -e "${green}Domain $domain removed.${rest}"
}

# --------------------------------------------------
# نصب سایت فیک (سایت پوششی) برای یک دامنه
# --------------------------------------------------
install_random_fake_site() {
    select_domain || return
    domain="$SELECTED_DOMAIN"

    if [ ! -d "/var/www/website-templates" ]; then
        echo -e "${yellow}Downloading Websites list...${rest}"
        git clone https://github.com/learning-zone/website-templates.git /var/www/website-templates
    fi

    cd /var/www/website-templates || return
    rm -rf "/var/www/$domain"/*
    random_folder=$(ls -d */ | shuf -n 1)
    mv "$random_folder"/* "/var/www/$domain"
    echo -e "${green}Fake site installed for $domain successfully${rest}"
}

# --------------------------------------------------
# محدودیت ترافیک (کلی روی سرور)
# --------------------------------------------------
add_limit() {
total_usage(){
    interface=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo" | head -n 1) > /dev/null 2>&1
    data=$(grep "$interface:" /proc/net/dev)
    download=$(echo "$data" | awk '{print $2}')
    upload=$(echo "$data" | awk '{print $10}')
    total_mb=$(echo "scale=2; ($download + $upload) / 1024 / 1024" | bc)
    echo -e "${cyan}Total Usage: ${purple}[$total_mb] ${cyan}MB${rest}"
}

    echo -e "${yellow}×××××××××××××××××××××××${rest}"
    echo -e "${cyan}This adds a traffic limit compared to the last 24 hours.${rest}"
    echo -e "${cyan}If traffic exceeds this limit, nginx will be stopped.${rest}"
    total_usage
    read -p "Enter the percentage limit [default: 50]: " percentage_limit
    percentage_limit=${percentage_limit:-50}
    echo -e "${yellow}×××××××××××××××××××××××${rest}"

    mkdir -p /root/usage

    cat <<EOL > /root/usage/limit.sh
#!/bin/bash
interface=\$(ip -o link show | awk -F': ' '{print \$2}' | grep -v "lo" | head -n 1)

get_total(){
    data=\$(grep "\$interface:" /proc/net/dev)
    download=\$(echo "\$data" | awk '{print \$2}')
    upload=\$(echo "\$data" | awk '{print \$10}')
    total_mb=\$(echo "scale=2; (\$download + \$upload) / 1024 / 1024" | bc)
    echo "\$total_mb"
}

check_traffic_increase() {
    current_total_mb=\$(get_total)
    if [ -f "/root/usage/\${interface}_traffic.txt" ]; then
        read -r prev_total_mb < "/root/usage/\${interface}_traffic.txt"
        increase=\$(echo "scale=2; (\$current_total_mb - \$prev_total_mb) / \$prev_total_mb * 100" | bc)
        if (( \$(echo "\$increase > $percentage_limit" | bc) )); then
            systemctl stop nginx
            echo "[$(date +'%Y-%m-%d %H:%M:%S')] Traffic on \$interface increased by more than $percentage_limit%" >> /root/usage/log.txt
        fi
    fi
    echo "\$current_total_mb" > "/root/usage/\${interface}_traffic.txt"
}

check_traffic_increase
EOL

chmod +x /root/usage/limit.sh && /root/usage/limit.sh
(crontab -l 2>/dev/null | grep -v '/root/usage/limit.sh' ; echo '0 0 * * * /root/usage/limit.sh > /dev/null 2>&1;') | crontab -
echo -e "${green}Traffic limit configured.${rest}"
}

# --------------------------------------------------
# حذف کامل (همه دامنه‌ها)
# --------------------------------------------------
uninstall_all() {
    read -p "This will remove ALL domains and certificates. Continue? (y/n): " ans
    [ "$ans" != "y" ] && return

    while read -r d; do
        [ -z "$d" ] && continue
        rm -rf "/etc/letsencrypt/live/$d" "/etc/letsencrypt/archive/$d" "/etc/letsencrypt/renewal/${d}.conf"
        rm -rf "/var/www/$d"
    done < "$DOMAINS_LIST"

    find "$NGINX_AVAIL" -mindepth 1 -maxdepth 1 ! -name 'default' -exec rm -rf {} +
    find "$NGINX_ENABLED" -mindepth 1 -maxdepth 1 ! -name 'default' -exec rm -rf {} +
    > "$DOMAINS_LIST"

    systemctl restart nginx
    echo -e "${green}All domains uninstalled successfully.${rest}"
}

# --------------------------------------------------
# منو
# --------------------------------------------------
clear
echo -e "${cyan}Multi-Domain Nginx Reverse Proxy (xhttp / httpupgrade)${rest}"
echo ""
echo -e "${purple}***********************${rest}"
echo -e "${yellow} 1) ${green}Add Domain${rest}          ${purple}*${rest}"
echo -e "${yellow} 2) ${green}List Domains${rest}        ${purple}*${rest}"
echo -e "${yellow} 3) ${green}Change Paths${rest}        ${purple}*${rest}"
echo -e "${yellow} 4) ${green}Change HTTPS Port${rest}   ${purple}*${rest}"
echo -e "${yellow} 5) ${green}Remove Domain${rest}       ${purple}*${rest}"
echo -e "${yellow} 6) ${green}Install Fake Site${rest}   ${purple}*${rest}"
echo -e "${yellow} 7) ${green}Add Traffic Limit${rest}   ${purple}*${rest}"
echo -e "${yellow} 8) ${green}Uninstall All${rest}       ${purple}*${rest}"
echo -e "${yellow} 0) ${purple}Exit${rest}                ${purple}*${rest}"
echo -e "${purple}***********************${rest}"
read -p "Enter your choice: " choice
case "$choice" in
    1) add_domain ;;
    2) list_domains ;;
    3) change_path ;;
    4) change_port ;;
    5) remove_domain ;;
    6) install_random_fake_site ;;
    7) add_limit ;;
    8) uninstall_all ;;
    0) echo -e "${cyan}Bye 🖐${rest}"; exit ;;
    *) echo -e "${red}Invalid choice.${rest}" ;;
esac
