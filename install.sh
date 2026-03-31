#!/usr/bin/env bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

APP_NAME="webaetheria"
APP_DIR="/var/www/$APP_NAME"
SERVICE_NAME="$APP_NAME"
DEFAULT_PORT="3000"
DOMAIN=""
EMAIL=""
PORT="$DEFAULT_PORT"
NODE_MAJOR="20"

banner() {
  clear
  echo -e "${PURPLE}============================================================${NC}"
  echo -e "${CYAN}                 WEBAETHERIA AUTO INSTALLER                 ${NC}"
  echo -e "${WHITE}         Auto deploy web ala pterodactyl installer         ${NC}"
  echo -e "${PURPLE}============================================================${NC}"
  echo
}

ok() { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[ERROR]${NC} $1"; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    fail "Jalankan script ini sebagai root"
    exit 1
  fi
}

ask_basic() {
  echo -ne "${CYAN}Masukkan domain web (contoh: web.aetheriacloud.my.id): ${NC}"
  read -r DOMAIN
  echo -ne "${CYAN}Masukkan email SSL: ${NC}"
  read -r EMAIL
  echo -ne "${CYAN}Port app internal [${DEFAULT_PORT}]: ${NC}"
  read -r INPUT_PORT
  PORT="${INPUT_PORT:-$DEFAULT_PORT}"

  if [ -z "$DOMAIN" ] || [ -z "$EMAIL" ]; then
    fail "Domain dan email wajib diisi"
    exit 1
  fi
}

install_dependencies() {
  info "Install dependency dasar..."
  apt update
  apt install -y curl git unzip tar sudo ca-certificates gnupg lsb-release software-properties-common nginx certbot python3-certbot-nginx
  ok "Dependency dasar terinstall"
}

install_node() {
  info "Install Node.js ${NODE_MAJOR}.x ..."
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" > /etc/apt/sources.list.d/nodesource.list
  apt update
  apt install -y nodejs
  npm install -g pm2
  ok "Node.js dan PM2 terinstall"
}

prepare_app() {
  info "Siapkan folder aplikasi..."
  mkdir -p "$APP_DIR"
  rsync -a --delete --exclude node_modules --exclude .git ./ "$APP_DIR/"
  cd "$APP_DIR"

  if [ -f package-lock.json ]; then
    npm install
  elif [ -f yarn.lock ]; then
    npm install -g yarn
    yarn install
  else
    npm install
  fi

  if [ -f package.json ]; then
    if grep -q '"build"' package.json; then
      npm run build || true
    fi
  fi

  chown -R www-data:www-data "$APP_DIR"
  ok "Source web siap di $APP_DIR"
}

create_env_if_missing() {
  cd "$APP_DIR"
  if [ ! -f .env ] && [ -f .env.example ]; then
    cp .env.example .env
    ok ".env dibuat dari .env.example"
  fi
}

create_service() {
  info "Membuat systemd service..."
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=WebAetheria Next.js Service
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=${APP_DIR}
Environment=NODE_ENV=production
Environment=PORT=${PORT}
ExecStart=/usr/bin/npm run start -- --port ${PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
  systemctl restart "$SERVICE_NAME"
  ok "Service ${SERVICE_NAME} aktif"
}

setup_nginx() {
  info "Setup nginx reverse proxy..."
  rm -f /etc/nginx/sites-enabled/default
  cat > "/etc/nginx/sites-available/${APP_NAME}.conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    location / {
        proxy_pass http://127.0.0.1:${PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  ln -sf "/etc/nginx/sites-available/${APP_NAME}.conf" "/etc/nginx/sites-enabled/${APP_NAME}.conf"
  nginx -t
  systemctl restart nginx
  ok "Nginx berhasil diset"
}

setup_ssl() {
  info "Memasang SSL Let's Encrypt..."
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect
  systemctl reload nginx
  ok "SSL berhasil dipasang untuk $DOMAIN"
}

show_status() {
  banner
  echo -e "${WHITE}Status service:${NC}"
  systemctl --no-pager --full status "$SERVICE_NAME" || true
  echo
  echo -e "${WHITE}Status nginx:${NC}"
  systemctl --no-pager --full status nginx || true
  echo
  echo -e "${WHITE}Port aktif:${NC}"
  ss -tulpn | grep -E ":${PORT}|:80|:443" || true
  echo
}

full_install() {
  ask_basic
  install_dependencies
  install_node
  create_env_if_missing
  prepare_app
  create_service
  setup_nginx
  setup_ssl
  ok "Install full selesai! Web siap di https://${DOMAIN}"
}

update_web() {
  info "Update source web..."
  rsync -a --delete --exclude node_modules --exclude .git ./ "$APP_DIR/"
  cd "$APP_DIR"
  npm install
  npm run build || true
  systemctl restart "$SERVICE_NAME"
  ok "Web berhasil diupdate"
}

reinstall_ssl() {
  ask_basic
  setup_nginx
  setup_ssl
}

restart_services() {
  systemctl restart "$SERVICE_NAME" || true
  systemctl restart nginx
  ok "Service berhasil direstart"
}

menu() {
  while true; do
    banner
    echo -e "${YELLOW}1)${NC} Install full web"
    echo -e "${YELLOW}2)${NC} Update web dari source sekarang"
    echo -e "${YELLOW}3)${NC} Pasang / ulang SSL domain"
    echo -e "${YELLOW}4)${NC} Lihat status deploy"
    echo -e "${YELLOW}5)${NC} Restart service"
    echo -e "${YELLOW}6)${NC} Keluar"
    echo
    echo -ne "${CYAN}Pilih menu [1-6]: ${NC}"
    read -r choice

    case "$choice" in
      1) full_install; read -rp "Tekan enter untuk lanjut..." ;;
      2) update_web; read -rp "Tekan enter untuk lanjut..." ;;
      3) reinstall_ssl; read -rp "Tekan enter untuk lanjut..." ;;
      4) show_status; read -rp "Tekan enter untuk lanjut..." ;;
      5) restart_services; read -rp "Tekan enter untuk lanjut..." ;;
      6) exit 0 ;;
      *) warn "Pilihan tidak valid"; sleep 1 ;;
    esac
  done
}

require_root
menu
