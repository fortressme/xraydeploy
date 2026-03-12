#!/bin/sh

set -u

XRAY_DIR="/etc/xray"
XRAY_CONF_DIR="/etc/xray/conf"
XRAY_CONFIG="/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
XRAY_LOG_DIR="/var/log/xray"
GEO_SOURCE_FILE="/etc/xray/geo_source.conf"

DEFAULT_GEO_SOURCE="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"

print_info() {
  printf "[INFO] %s\n" "$1"
}

print_warn() {
  printf "[WARN] %s\n" "$1"
}

print_error() {
  printf "[ERROR] %s\n" "$1" >&2
}

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    print_error "请使用 root 运行此脚本。"
    exit 1
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

install_packages() {
  pkgs="$*"

  if command_exists apk; then
    apk add --no-cache $pkgs
    return $?
  fi

  if command_exists apt-get; then
    apt-get update
    apt-get install -y $pkgs
    return $?
  fi

  if command_exists dnf; then
    dnf install -y $pkgs
    return $?
  fi

  if command_exists yum; then
    yum install -y $pkgs
    return $?
  fi

  print_error "未识别包管理器，请手动安装：$pkgs"
  return 1
}

ensure_dependencies() {
  missing=""

  for dep in curl unzip jq; do
    if ! command_exists "$dep"; then
      missing="$missing $dep"
    fi
  done

  if [ -n "${missing# }" ]; then
    print_info "安装依赖:${missing}"
    if ! install_packages $missing; then
      print_error "依赖安装失败。"
      exit 1
    fi
  fi
}

ensure_directories() {
  mkdir -p "$XRAY_DIR" "$XRAY_CONF_DIR" "$XRAY_LOG_DIR"
  chmod 700 "$XRAY_DIR" "$XRAY_CONF_DIR" || true

  if [ ! -f "$GEO_SOURCE_FILE" ]; then
    printf "GEO_BASE_URL=%s\n" "$DEFAULT_GEO_SOURCE" > "$GEO_SOURCE_FILE"
  fi
}

create_default_main_config() {
  if [ -f "$XRAY_CONFIG" ]; then
    return 0
  fi

  cat > "$XRAY_CONFIG" <<'EOF'
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "dns": {
    "servers": [
      "https+local://dns.google/dns-query"
    ]
  },
  "api": {
    "tag": "api",
    "services": [
      "HandlerService",
      "LoggerService",
      "StatsService"
    ]
  },
  "stats": {},
  "policy": {
    "levels": {
      "0": {
        "handshake": 5,
        "connIdle": 466,
        "uplinkOnly": 7,
        "downlinkOnly": 5,
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "inboundTag": [
          "api"
        ],
        "outboundTag": "api"
      },
      {
        "type": "field",
        "protocol": [
          "bittorrent"
        ],
        "marktag": "ban_bt",
        "outboundTag": "block"
      },
      {
        "type": "field",
        "ip": [
          "geoip:private"
        ],
        "outboundTag": "block"
      }
    ]
  },
  "inbounds": [
    {
      "tag": "api",
      "port": 46627,
      "listen": "127.0.0.1",
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      }
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    },
    {
      "tag": "api",
      "protocol": "freedom"
    }
  ]
}
EOF

  print_info "已生成默认主配置：$XRAY_CONFIG"
}

get_arch_suffix() {
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) echo "64" ;;
    i386|i686) echo "32" ;;
    aarch64|arm64) echo "arm64-v8a" ;;
    armv7l|armv7) echo "arm32-v7a" ;;
    armv6l) echo "arm32-v6" ;;
    s390x) echo "s390x" ;;
    riscv64) echo "riscv64" ;;
    mips64le) echo "mips64le" ;;
    *)
      print_error "不支持的架构：$arch"
      return 1
      ;;
  esac
}

get_latest_version() {
  curl -fsSL "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
    | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n 1
}

download_and_install_xray() {
  ensure_dependencies
  ensure_directories

  suffix="$(get_arch_suffix)" || return 1

  printf "请输入要安装的版本（默认 latest）: "
  read -r user_version

  if [ -z "$user_version" ] || [ "$user_version" = "latest" ]; then
    version="$(get_latest_version)"
  else
    version="$user_version"
  fi

  if [ -z "$version" ]; then
    print_error "获取版本失败。"
    return 1
  fi

  file_name="Xray-linux-${suffix}.zip"
  url="https://github.com/XTLS/Xray-core/releases/download/${version}/${file_name}"

  tmp_dir="$(mktemp -d)"
  zip_path="$tmp_dir/$file_name"

  print_info "下载：$url"
  if ! curl -fL "$url" -o "$zip_path"; then
    print_error "下载失败，请确认版本和网络。"
    rm -rf "$tmp_dir"
    return 1
  fi

  if ! unzip -o "$zip_path" -d "$tmp_dir" >/dev/null; then
    print_error "解压失败。"
    rm -rf "$tmp_dir"
    return 1
  fi

  if [ ! -f "$tmp_dir/xray" ]; then
    print_error "安装包中未找到 xray 可执行文件。"
    rm -rf "$tmp_dir"
    return 1
  fi

  install -m 755 "$tmp_dir/xray" "$XRAY_BIN"

  if [ -f "$tmp_dir/geoip.dat" ]; then
    install -m 644 "$tmp_dir/geoip.dat" "$XRAY_DIR/geoip.dat"
  fi

  if [ -f "$tmp_dir/geosite.dat" ]; then
    install -m 644 "$tmp_dir/geosite.dat" "$XRAY_DIR/geosite.dat"
  fi

  rm -rf "$tmp_dir"

  print_info "Xray Core 已安装到：$XRAY_BIN"
  setup_service
  create_default_main_config
  validate_config_or_warn
}

setup_service_systemd() {
  cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=$XRAY_BIN run -c $XRAY_CONFIG -confdir $XRAY_CONF_DIR
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable xray >/dev/null 2>&1 || true
}

setup_service_openrc() {
  cat > /etc/init.d/xray <<EOF
#!/sbin/openrc-run

name="xray"
description="Xray Service"
command="$XRAY_BIN"
command_args="run -c $XRAY_CONFIG -confdir $XRAY_CONF_DIR"
command_background=true
pidfile="/run/xray.pid"

command_user="root:root"

start_pre() {
  checkpath --directory --owner root:root /run
}

depend() {
  need net
}
EOF

  chmod +x /etc/init.d/xray
  if command_exists rc-update; then
    rc-update add xray default >/dev/null 2>&1 || true
  fi
}

setup_service() {
  if command_exists systemctl; then
    setup_service_systemd
    print_info "已配置 systemd 服务。"
    return 0
  fi

  if [ -x /sbin/openrc-run ] || command_exists rc-service; then
    setup_service_openrc
    print_info "已配置 OpenRC 服务（Alpine 兼容）。"
    return 0
  fi

  print_warn "未检测到 systemd/OpenRC，请手动创建服务。"
}

service_restart() {
  if command_exists systemctl; then
    systemctl restart xray
    return $?
  fi

  if command_exists rc-service; then
    rc-service xray restart
    return $?
  fi

  print_error "未检测到 systemd/OpenRC。"
  return 1
}

service_stop() {
  if command_exists systemctl; then
    systemctl stop xray
    return $?
  fi

  if command_exists rc-service; then
    rc-service xray stop
    return $?
  fi

  print_error "未检测到 systemd/OpenRC。"
  return 1
}

service_start() {
  if command_exists systemctl; then
    systemctl start xray
    return $?
  fi

  if command_exists rc-service; then
    rc-service xray start
    return $?
  fi

  print_error "未检测到 systemd/OpenRC。"
  return 1
}

service_status() {
  if command_exists systemctl; then
    systemctl status xray --no-pager
    return $?
  fi

  if command_exists rc-service; then
    rc-service xray status
    return $?
  fi

  print_warn "未检测到 systemd/OpenRC。"
  return 1
}

validate_config() {
  if [ ! -x "$XRAY_BIN" ]; then
    print_warn "未安装 xray，跳过配置校验。"
    return 0
  fi

  "$XRAY_BIN" run -test -c "$XRAY_CONFIG" -confdir "$XRAY_CONF_DIR" >/dev/null 2>&1
}

validate_config_or_warn() {
  if validate_config; then
    print_info "配置校验通过。"
  else
    print_warn "配置校验失败，请检查：$XRAY_CONFIG 和 $XRAY_CONF_DIR"
  fi
}

select_conf_file() {
  files="$(find "$XRAY_CONF_DIR" -maxdepth 1 -type f -name '*.json' | sort)"

  if [ -z "$files" ]; then
    print_warn "当前没有可选配置文件。"
    return 1
  fi

  i=1
  echo "$files" | while IFS= read -r f; do
    printf "%d) %s\n" "$i" "$(basename "$f")" >&2
    i=$((i + 1))
  done

  printf "请选择编号: " >&2
  read -r idx

  file="$(echo "$files" | sed -n "${idx}p")"

  if [ -z "$file" ]; then
    print_error "无效编号。"
    return 1
  fi

  printf "%s\n" "$file"
  return 0
}

safe_write_json() {
  src_file="$1"
  jq_expr="$2"
  backup_file="${src_file}.bak.$(date +%s)"

  cp "$src_file" "$backup_file"

  if ! jq "$jq_expr" "$src_file" > "${src_file}.tmp"; then
    print_error "JSON 处理失败，已保留原文件。"
    rm -f "${src_file}.tmp"
    return 1
  fi

  mv "${src_file}.tmp" "$src_file"

  if ! validate_config; then
    print_error "修改后配置校验失败，自动回滚。"
    mv "$backup_file" "$src_file"
    return 1
  fi

  rm -f "$backup_file"
  print_info "修改成功。"
  return 0
}

safe_write_json_with_arg() {
  src_file="$1"
  jq_filter="$2"
  jq_value="$3"
  backup_file="${src_file}.bak.$(date +%s)"

  cp "$src_file" "$backup_file"

  if ! jq --arg val "$jq_value" "$jq_filter" "$src_file" > "${src_file}.tmp"; then
    print_error "JSON 处理失败，已保留原文件。"
    rm -f "${src_file}.tmp"
    return 1
  fi

  mv "${src_file}.tmp" "$src_file"

  if ! validate_config; then
    print_error "修改后配置校验失败，自动回滚。"
    mv "$backup_file" "$src_file"
    return 1
  fi

  rm -f "$backup_file"
  print_info "修改成功。"
  return 0
}

generate_vless_decryption() {
  if [ -x "$XRAY_BIN" ]; then
    "$XRAY_BIN" vlessenc 2>/dev/null | sed '/^$/d' | tail -n 1
  fi
}

find_conf_matches() {
  keyword="$1"
  ensure_dependencies
  ensure_directories

  matches=""

  for file in "$XRAY_CONF_DIR"/*.json; do
    [ -f "$file" ] || continue

    base="$(basename "$file")"
    if printf "%s" "$base" | grep -Fqi -- "$keyword"; then
      if [ -z "$matches" ]; then
        matches="$file"
      else
        matches="$matches
$file"
      fi
      continue
    fi

    if jq -e --arg kw "$keyword" '
      (.inbounds // []) | any(
        ((.tag // "") | ascii_downcase | contains($kw | ascii_downcase)) or
        ((.port | tostring) == $kw)
      )
    ' "$file" >/dev/null 2>&1; then
      if [ -z "$matches" ]; then
        matches="$file"
      else
        matches="$matches
$file"
      fi
    fi
  done

  printf "%s\n" "$matches" | sed '/^$/d'
}

pick_single_match() {
  matches="$1"
  count="$(printf "%s\n" "$matches" | sed '/^$/d' | wc -l | tr -d ' ')"

  if [ "$count" = "0" ]; then
    print_error "未匹配到配置。"
    return 1
  fi

  if [ "$count" = "1" ]; then
    printf "%s\n" "$matches"
    return 0
  fi

  print_warn "匹配到多个配置："
  i=1
  printf "%s\n" "$matches" | while IFS= read -r f; do
    printf "%d) %s\n" "$i" "$(basename "$f")" >&2
    i=$((i + 1))
  done

  if [ -t 0 ]; then
    printf "请选择编号: " >&2
    read -r idx
    selected="$(printf "%s\n" "$matches" | sed -n "${idx}p")"
    [ -n "$selected" ] || { print_error "无效编号"; return 1; }
    printf "%s\n" "$selected"
    return 0
  fi

  print_error "非交互模式下匹配到多个配置，请提供更精确关键字。"
  return 1
}

add_shortcut() {
  proto="${1:-}"
  [ -n "$proto" ] || { print_error "用法: $0 add <ss|vlessenc|reality> ..."; return 1; }
  shift

  ensure_directories

  case "$proto" in
    ss|shadowsocks)
      port="${1:-}"
      password="${2:-}"
      method="${3:-2022-blake3-aes-256-gcm}"

      if [ -z "$port" ]; then
        port="$(gen_random_port)"
        print_info "未填写端口，已随机生成：$port"
      fi

      if [ -z "$password" ]; then
        password="$(gen_random_password)"
        print_info "未填写密码，已随机生成。"
      fi

      config_name="shadowsocks-${port}"
      file="$XRAY_CONF_DIR/${config_name}.json"
      if [ -f "$file" ]; then
        config_name="${config_name}-$(date +%s)"
        file="$XRAY_CONF_DIR/${config_name}.json"
      fi

      cat > "$file" <<EOF
{
  "inbounds": [
    {
      "tag": "${config_name}",
      "port": ${port},
      "listen": "0.0.0.0",
      "protocol": "shadowsocks",
      "settings": {
        "method": "${method}",
        "password": "${password}",
        "network": "tcp,udp"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      }
    }
  ]
}
EOF
      validate_config_or_warn
      print_info "已新增 SS 配置：$file"
      ;;
    vlessenc|vless-encryption|vless)
      port="${1:-}"
      decryption_input="${2:-auto}"
      uuid_input="${3:-}"

      if [ -z "$port" ]; then
        port="$(gen_random_port)"
        print_info "未填写端口，已随机生成：$port"
      fi

      if [ "$decryption_input" = "auto" ]; then
        decryption="$(generate_vless_decryption)"
        [ -n "$decryption" ] || decryption="none"
      else
        decryption="$decryption_input"
      fi

      if [ -n "$uuid_input" ]; then
        uuid="$uuid_input"
      else
        uuid="$(gen_uuid)" || return 1
      fi

      config_name="vless-${port}"
      file="$XRAY_CONF_DIR/${config_name}.json"
      if [ -f "$file" ]; then
        config_name="${config_name}-$(date +%s)"
        file="$XRAY_CONF_DIR/${config_name}.json"
      fi

      cat > "$file" <<EOF
{
  "inbounds": [
    {
      "tag": "${config_name}",
      "port": ${port},
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "email": "admin@xray.local"
          }
        ],
        "decryption": "${decryption}"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      }
    }
  ]
}
EOF
      validate_config_or_warn
      print_info "已新增 VLESS Encryption 配置：$file"
      print_info "客户端 UUID: ${uuid}"
      ;;
    reality|vless-reality|vless-reality-vision)
      port="${1:-}"
      dest="${2:-www.cloudflare.com:443}"
      server_name="${3:-www.cloudflare.com}"
      private_key="${4:-}"
      short_id="${5:-}"
      public_key=""

      if [ -z "$port" ]; then
        port="$(gen_random_port)"
        print_info "未填写端口，已随机生成：$port"
      fi

      uuid="$(gen_uuid)" || return 1

      if [ -z "$private_key" ] && [ -x "$XRAY_BIN" ]; then
        key_output="$($XRAY_BIN x25519 2>/dev/null || true)"
        private_key="$(echo "$key_output" | sed -n 's/.*Private key:[[:space:]]*\(.*\)$/\1/p' | head -n 1)"
        public_key="$(echo "$key_output" | sed -n 's/.*Public key:[[:space:]]*\(.*\)$/\1/p' | head -n 1)"
      fi

      [ -n "$private_key" ] || { print_error "缺少 privateKey，请手动传入第4个参数。"; return 1; }

      if [ -z "$short_id" ]; then
        short_id="$(hexdump -n 4 -e '4/1 "%02x"' /dev/urandom 2>/dev/null || true)"
        [ -n "$short_id" ] || short_id="6ba85179"
      fi

      config_name="reality-${port}"
      file="$XRAY_CONF_DIR/${config_name}.json"
      if [ -f "$file" ]; then
        config_name="${config_name}-$(date +%s)"
        file="$XRAY_CONF_DIR/${config_name}.json"
      fi

      cat > "$file" <<EOF
{
  "inbounds": [
    {
      "tag": "${config_name}",
      "port": ${port},
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${dest}",
          "xver": 0,
          "serverNames": [
            "${server_name}"
          ],
          "privateKey": "${private_key}",
          "shortIds": [
            "${short_id}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ]
}
EOF
      validate_config_or_warn
      print_info "已新增 VLESS-Reality-Vision 配置：$file"
      print_info "客户端 UUID: ${uuid}"
      [ -n "$public_key" ] && print_info "REALITY PublicKey: ${public_key}"
      print_info "REALITY shortId: ${short_id}"
      ;;
    *)
      print_error "不支持的协议：$proto"
      print_error "支持：ss, vlessenc, reality"
      return 1
      ;;
  esac
}

change_shortcut() {
  keyword="${1:-}"
  field="${2:-}"
  shift 2 >/dev/null 2>&1 || true
  value="$*"

  [ -n "$keyword" ] || { print_error "用法: $0 change <keyword> <field> <value>"; return 1; }
  [ -n "$field" ] || { print_error "字段不能为空"; return 1; }
  [ -n "$value" ] || { print_error "新值不能为空"; return 1; }

  matches="$(find_conf_matches "$keyword")"
  target_file="$(pick_single_match "$matches")" || return 1

  apply_field_change "$target_file" "$field" "$value"
}

apply_field_change() {
  target_file="$1"
  field="$2"
  value="$3"

  field_lc="$(printf "%s" "$field" | tr 'A-Z' 'a-z')"

  if [ "$field_lc" = "decryption" ] && [ "$value" = "auto" ]; then
    auto_dec="$(generate_vless_decryption)"
    if [ -n "$auto_dec" ]; then
      value="$auto_dec"
      print_info "已自动生成 decryption。"
    else
      print_warn "自动生成失败，回退为 none。"
      value="none"
    fi
  fi

  case "$field_lc" in
    sni|servername|server-name)
      jq_filter='if ((.inbounds[0].streamSettings.security // "") == "reality") then .inbounds[0].streamSettings.realitySettings.serverNames = [$val] else .inbounds[0].streamSettings.tlsSettings = ((.inbounds[0].streamSettings.tlsSettings // {}) + {"serverName":$val}) end'
      ;;
    port)
      jq_filter='.inbounds[0].port = ($val | tonumber)'
      ;;
    tag)
      jq_filter='.inbounds[0].tag = $val'
      ;;
    listen)
      jq_filter='.inbounds[0].listen = $val'
      ;;
    password)
      jq_filter='.inbounds[0].settings.password = $val'
      ;;
    method)
      jq_filter='.inbounds[0].settings.method = $val'
      ;;
    decryption)
      jq_filter='.inbounds[0].settings.decryption = $val'
      ;;
    uuid|id)
      jq_filter='.inbounds[0].settings.clients[0].id = $val'
      ;;
    email)
      jq_filter='.inbounds[0].settings.clients[0].email = $val'
      ;;
    flow)
      jq_filter='.inbounds[0].settings.clients[0].flow = $val'
      ;;
    network)
      jq_filter='.inbounds[0].streamSettings.network = $val'
      ;;
    security)
      jq_filter='.inbounds[0].streamSettings.security = $val'
      ;;
    dest)
      jq_filter='.inbounds[0].streamSettings.realitySettings.dest = $val'
      ;;
    shortid|short-id)
      jq_filter='.inbounds[0].streamSettings.realitySettings.shortIds = [$val]'
      ;;
    privatekey|private-key)
      jq_filter='.inbounds[0].streamSettings.realitySettings.privateKey = $val'
      ;;
    xver)
      jq_filter='.inbounds[0].streamSettings.realitySettings.xver = ($val | tonumber)'
      ;;
    *)
      print_error "暂不支持的字段：$field"
      print_error "当前支持字段：sni/serverName, port, tag, listen, password, method, decryption, uuid/id, email, flow, network, security, dest, shortId, privateKey, xver"
      return 1
      ;;
  esac

  print_info "匹配到配置：$(basename "$target_file")"
  safe_write_json_with_arg "$target_file" "$jq_filter" "$value"
}

interactive_modify_sub_config() {
  file="$1"
  protocol="$(jq -r '.inbounds[0].protocol // empty' "$file" 2>/dev/null)"
  security="$(jq -r '.inbounds[0].streamSettings.security // empty' "$file" 2>/dev/null)"

  [ -n "$protocol" ] || { print_error "无法识别协议，配置缺少 .inbounds[0].protocol"; return 1; }

  print_info "当前配置：$(basename "$file")"
  print_info "识别协议：${protocol}${security:+, security=${security}}"

  field=""

  case "$protocol" in
    shadowsocks)
      echo "\n可修改项（Shadowsocks）："
      echo "1) tag"
      echo "2) port"
      echo "3) listen"
      echo "4) method"
      echo "5) password"
      printf "输入编号: "
      read -r choice

      case "$choice" in
        1) field="tag" ;;
        2) field="port" ;;
        3) field="listen" ;;
        4) field="method" ;;
        5) field="password" ;;
        *) print_error "无效选项"; return 1 ;;
      esac
      ;;
    vless)
      if [ "$security" = "reality" ]; then
        echo "\n可修改项（VLESS + REALITY）："
        echo "1) tag"
        echo "2) port"
        echo "3) listen"
        echo "4) uuid"
        echo "5) flow"
        echo "6) decryption"
        echo "7) network"
        echo "8) security"
        echo "9) serverName"
        echo "10) dest"
        echo "11) shortId"
        echo "12) privateKey"
        echo "13) xver"
        printf "输入编号: "
        read -r choice

        case "$choice" in
          1) field="tag" ;;
          2) field="port" ;;
          3) field="listen" ;;
          4) field="uuid" ;;
          5) field="flow" ;;
          6) field="decryption" ;;
          7) field="network" ;;
          8) field="security" ;;
          9) field="serverName" ;;
          10) field="dest" ;;
          11) field="shortId" ;;
          12) field="privateKey" ;;
          13) field="xver" ;;
          *) print_error "无效选项"; return 1 ;;
        esac
      else
        echo "\n可修改项（VLESS）："
        echo "1) tag"
        echo "2) port"
        echo "3) listen"
        echo "4) uuid"
        echo "5) email"
        echo "6) decryption"
        echo "7) network"
        echo "8) security"
        echo "9) serverName"
        printf "输入编号: "
        read -r choice

        case "$choice" in
          1) field="tag" ;;
          2) field="port" ;;
          3) field="listen" ;;
          4) field="uuid" ;;
          5) field="email" ;;
          6) field="decryption" ;;
          7) field="network" ;;
          8) field="security" ;;
          9) field="serverName" ;;
          *) print_error "无效选项"; return 1 ;;
        esac
      fi
      ;;
    *)
      print_warn "暂未内置该协议的字段菜单：$protocol"
      print_warn "可使用命令行 change 快捷修改，或通过主配置 jq 模式手动改。"
      return 1
      ;;
  esac

  value=""
  case "$field" in
    port)
      echo "\n端口修改方式："
      echo "1) 手动输入"
      echo "2) 随机生成"
      printf "输入编号（默认 1）: "
      read -r sub_choice
      [ -n "$sub_choice" ] || sub_choice="1"

      case "$sub_choice" in
        1)
          printf "输入新端口: "
          read -r value
          ;;
        2)
          value="$(gen_random_port)"
          print_info "已随机生成端口：$value"
          ;;
        *)
          print_error "无效选项"
          return 1
          ;;
      esac
      ;;
    password)
      echo "\n密码修改方式："
      echo "1) 手动输入"
      echo "2) 随机生成"
      printf "输入编号（默认 1）: "
      read -r sub_choice
      [ -n "$sub_choice" ] || sub_choice="1"

      case "$sub_choice" in
        1)
          printf "输入新密码: "
          read -r value
          ;;
        2)
          value="$(gen_random_password)"
          print_info "已随机生成密码。"
          ;;
        *)
          print_error "无效选项"
          return 1
          ;;
      esac
      ;;
    method)
      echo "\n请选择加密方法："
      echo "1) 2022-blake3-aes-256-gcm"
      echo "2) 2022-blake3-chacha20-poly1305"
      echo "3) aes-256-gcm"
      echo "4) chacha20-ietf-poly1305"
      echo "5) 自定义"
      printf "输入编号（默认 1）: "
      read -r sub_choice
      [ -n "$sub_choice" ] || sub_choice="1"

      case "$sub_choice" in
        1) value="2022-blake3-aes-256-gcm" ;;
        2) value="2022-blake3-chacha20-poly1305" ;;
        3) value="aes-256-gcm" ;;
        4) value="chacha20-ietf-poly1305" ;;
        5) printf "输入自定义 method: "; read -r value ;;
        *) print_error "无效选项"; return 1 ;;
      esac
      ;;
    decryption)
      echo "\n请选择 decryption："
      echo "1) auto（自动生成）"
      echo "2) none"
      echo "3) 自定义"
      printf "输入编号（默认 1）: "
      read -r sub_choice
      [ -n "$sub_choice" ] || sub_choice="1"

      case "$sub_choice" in
        1) value="auto" ;;
        2) value="none" ;;
        3) printf "输入自定义 decryption: "; read -r value ;;
        *) print_error "无效选项"; return 1 ;;
      esac
      ;;
    network)
      echo "\n请选择 network："
      echo "1) tcp"
      echo "2) ws"
      echo "3) grpc"
      echo "4) httpupgrade"
      echo "5) 自定义"
      printf "输入编号（默认 1）: "
      read -r sub_choice
      [ -n "$sub_choice" ] || sub_choice="1"

      case "$sub_choice" in
        1) value="tcp" ;;
        2) value="ws" ;;
        3) value="grpc" ;;
        4) value="httpupgrade" ;;
        5) printf "输入自定义 network: "; read -r value ;;
        *) print_error "无效选项"; return 1 ;;
      esac
      ;;
    security)
      echo "\n请选择 security："
      echo "1) none"
      echo "2) tls"
      echo "3) reality"
      echo "4) 自定义"
      printf "输入编号（默认 1）: "
      read -r sub_choice
      [ -n "$sub_choice" ] || sub_choice="1"

      case "$sub_choice" in
        1) value="none" ;;
        2) value="tls" ;;
        3) value="reality" ;;
        4) printf "输入自定义 security: "; read -r value ;;
        *) print_error "无效选项"; return 1 ;;
      esac
      ;;
    flow)
      echo "\n请选择 flow："
      echo "1) xtls-rprx-vision"
      echo "2) 自定义"
      printf "输入编号（默认 1）: "
      read -r sub_choice
      [ -n "$sub_choice" ] || sub_choice="1"

      case "$sub_choice" in
        1) value="xtls-rprx-vision" ;;
        2) printf "输入自定义 flow: "; read -r value ;;
        *) print_error "无效选项"; return 1 ;;
      esac
      ;;
    *)
      printf "输入新值: "
      read -r value
      ;;
  esac

  [ -n "$value" ] || { print_error "新值不能为空"; return 1; }

  apply_field_change "$file" "$field" "$value"
}

delete_shortcut() {
  keyword="${1:-}"
  [ -n "$keyword" ] || { print_error "用法: $0 del <keyword>"; return 1; }

  matches="$(find_conf_matches "$keyword")"
  target_file="$(pick_single_match "$matches")" || return 1

  if [ -t 0 ]; then
    printf "确认删除 %s ? [y/N]: " "$(basename "$target_file")" >&2
    read -r confirm
    case "$confirm" in
      y|Y) ;;
      *) print_info "已取消"; return 0 ;;
    esac
  fi

  backup_file="${target_file}.bak.$(date +%s)"
  cp "$target_file" "$backup_file"
  rm -f "$target_file"

  if ! validate_config; then
    print_error "删除后配置校验失败，自动回滚。"
    mv "$backup_file" "$target_file"
    return 1
  fi

  rm -f "$backup_file"
  print_info "已删除配置：$(basename "$target_file")"
}

gen_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
    return 0
  fi

  if command_exists uuidgen; then
    uuidgen
    return 0
  fi

  if [ -x "$XRAY_BIN" ]; then
    "$XRAY_BIN" uuid
    return 0
  fi

  print_error "无法生成 UUID。"
  return 1
}

gen_random_port() {
  if command_exists od && [ -r /dev/urandom ]; then
    raw_port="$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d '[:space:]')"
    if [ -n "$raw_port" ]; then
      # 使用 10000-65534 范围，尽量避开系统常用端口
      echo $((raw_port % 55535 + 10000))
      return 0
    fi
  fi

  # 兜底：基于 awk 生成伪随机端口
  awk 'BEGIN{srand(); print int(10000 + rand() * 55535)}'
}

gen_random_password() {
  if command_exists head && command_exists base64 && [ -r /dev/urandom ]; then
    pwd_val="$(head -c 32 /dev/urandom | base64 2>/dev/null || true)"
    [ -n "$pwd_val" ] && { printf "%s\n" "$pwd_val"; return 0; }
  fi

  printf "CHANGE_ME_%s\n" "$(date +%s)"
}

create_ss_config() {
  printf "端口（示例 8936）: "
  read -r port
  if [ -z "$port" ]; then
    port="$(gen_random_port)"
    print_info "未填写端口，已随机生成：$port"
  fi

  printf "配置文件名（不含 .json，留空自动生成为 shadowsocks-%s）: " "$port"
  read -r name
  [ -n "$name" ] || name="shadowsocks-${port}"

  file="$XRAY_CONF_DIR/${name}.json"
  [ ! -f "$file" ] || { print_error "文件已存在：$file"; return 1; }

  printf "加密方法（默认 2022-blake3-aes-256-gcm）: "
  read -r method
  printf "密码（留空自动生成 32 字节）: "
  read -r password

  [ -n "$method" ] || method="2022-blake3-aes-256-gcm"
  if [ -z "$password" ]; then
    password="$(gen_random_password)"
    print_info "未填写密码，已随机生成。"
  fi

  cat > "$file" <<EOF
{
  "inbounds": [
    {
      "tag": "${name}",
      "port": ${port},
      "listen": "0.0.0.0",
      "protocol": "shadowsocks",
      "settings": {
        "method": "${method}",
        "password": "${password}",
        "network": "tcp,udp"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      }
    }
  ]
}
EOF

  validate_config_or_warn
  print_info "已新增 SS 配置：$file"
}

create_vless_encryption_config() {
  printf "端口: "
  read -r port
  if [ -z "$port" ]; then
    port="$(gen_random_port)"
    print_info "未填写端口，已随机生成：$port"
  fi

  printf "配置文件名（不含 .json，留空自动生成为 vless-%s）: " "$port"
  read -r name
  [ -n "$name" ] || name="vless-${port}"

  file="$XRAY_CONF_DIR/${name}.json"
  [ ! -f "$file" ] || { print_error "文件已存在：$file"; return 1; }

  uuid="$(gen_uuid)" || return 1

  printf "邮箱标识（默认 admin@xray.local）: "
  read -r email
  [ -n "$email" ] || email="admin@xray.local"

  echo "请选择 decryption 输入方式："
  echo "1) 自动生成（xray vlessenc）"
  echo "2) 手动输入"
  echo "3) 使用 none"
  printf "输入编号（默认 1）: "
  read -r dec_mode
  [ -n "$dec_mode" ] || dec_mode="1"

  decryption=""

  case "$dec_mode" in
    1)
      auto_dec="$(generate_vless_decryption)"

      if [ -n "$auto_dec" ]; then
        decryption="$auto_dec"
        print_info "已自动生成 decryption。"
      else
        print_warn "自动生成失败（未安装 xray 或当前版本不支持 vlessenc），请手动输入。"
        printf "decryption（留空则为 none）: "
        read -r decryption
        [ -n "$decryption" ] || decryption="none"
      fi
      ;;
    2)
      printf "decryption（留空则为 none）: "
      read -r decryption
      [ -n "$decryption" ] || decryption="none"
      ;;
    3)
      decryption="none"
      ;;
    *)
      print_warn "无效选项，默认使用 none。"
      decryption="none"
      ;;
  esac

  cat > "$file" <<EOF
{
  "inbounds": [
    {
      "tag": "${name}",
      "port": ${port},
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "email": "${email}"
          }
        ],
        "decryption": "${decryption}"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "none"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      }
    }
  ]
}
EOF

  validate_config_or_warn
  print_info "已新增 VLESS Encryption 配置：$file"
  print_info "客户端 UUID: ${uuid}"
}

create_vless_reality_vision_config() {
  printf "端口: "
  read -r port
  if [ -z "$port" ]; then
    port="$(gen_random_port)"
    print_info "未填写端口，已随机生成：$port"
  fi

  printf "配置文件名（不含 .json，留空自动生成为 reality-%s）: " "$port"
  read -r name
  [ -n "$name" ] || name="reality-${port}"

  file="$XRAY_CONF_DIR/${name}.json"
  [ ! -f "$file" ] || { print_error "文件已存在：$file"; return 1; }

  uuid="$(gen_uuid)" || return 1

  printf "REALITY dest（默认 www.cloudflare.com:443）: "
  read -r reality_dest
  [ -n "$reality_dest" ] || reality_dest="www.cloudflare.com:443"

  printf "REALITY serverName（默认 www.cloudflare.com）: "
  read -r server_name
  [ -n "$server_name" ] || server_name="www.cloudflare.com"

  private_key=""
  public_key=""

  if [ -x "$XRAY_BIN" ]; then
    key_output="$("$XRAY_BIN" x25519 2>/dev/null || true)"
    private_key="$(echo "$key_output" | sed -n 's/.*Private key:[[:space:]]*\(.*\)$/\1/p' | head -n 1)"
    public_key="$(echo "$key_output" | sed -n 's/.*Public key:[[:space:]]*\(.*\)$/\1/p' | head -n 1)"
  fi

  if [ -z "$private_key" ]; then
    printf "REALITY privateKey（必填）: "
    read -r private_key
  fi

  printf "shortId（默认随机 8 位十六进制）: "
  read -r short_id
  if [ -z "$short_id" ]; then
    short_id="$(hexdump -n 4 -e '4/1 "%02x"' /dev/urandom 2>/dev/null || true)"
    [ -n "$short_id" ] || short_id="6ba85179"
  fi

  cat > "$file" <<EOF
{
  "inbounds": [
    {
      "tag": "${name}",
      "port": ${port},
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${reality_dest}",
          "xver": 0,
          "serverNames": [
            "${server_name}"
          ],
          "privateKey": "${private_key}",
          "shortIds": [
            "${short_id}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }
  ]
}
EOF

  validate_config_or_warn
  print_info "已新增 VLESS-Reality-Vision 配置：$file"
  print_info "客户端 UUID: ${uuid}"
  [ -n "$public_key" ] && print_info "REALITY PublicKey: ${public_key}"
  print_info "REALITY shortId: ${short_id}"
}

add_config_menu() {
  ensure_directories

  echo "\n请选择要新增的配置类型："
  echo "1) Shadowsocks"
  echo "2) VLESS Encryption"
  echo "3) VLESS Reality Vision"
  printf "输入编号: "
  read -r choice

  case "$choice" in
    1) create_ss_config ;;
    2) create_vless_encryption_config ;;
    3) create_vless_reality_vision_config ;;
    *) print_error "无效选项" ;;
  esac
}

modify_config_item() {
  ensure_dependencies
  ensure_directories

  echo "\n请选择要修改的文件："
  echo "1) 主配置 $XRAY_CONFIG"
  echo "2) 子配置 $XRAY_CONF_DIR/*.json"
  printf "输入编号: "
  read -r target

  if [ "$target" = "1" ]; then
    file="$XRAY_CONFIG"

    if [ ! -f "$file" ]; then
      print_error "文件不存在：$file"
      return 1
    fi

    echo "示例路径：.inbounds[0].port"
    printf "输入 jq 路径: "
    read -r jq_path

    echo "示例值：443 或 \"new.example.com\" 或 [\"8.8.8.8\",\"1.1.1.1\"]"
    printf "输入新值（JSON 格式）: "
    read -r json_value

    [ -n "$jq_path" ] || { print_error "路径不能为空"; return 1; }
    [ -n "$json_value" ] || { print_error "值不能为空"; return 1; }

    safe_write_json "$file" "$jq_path = $json_value"
    return $?
  fi

  if [ "$target" = "2" ]; then
    file="$(select_conf_file)" || return 1

    if [ ! -f "$file" ]; then
      print_error "文件不存在：$file"
      return 1
    fi

    interactive_modify_sub_config "$file"
    return $?
  fi

  print_error "无效选项"
  return 1
}

delete_config() {
  ensure_directories

  file="$(select_conf_file)" || return 1

  printf "确认删除 %s ? [y/N]: " "$file"
  read -r confirm

  case "$confirm" in
    y|Y)
      rm -f "$file"
      print_info "已删除：$file"
      validate_config_or_warn
      ;;
    *)
      print_info "已取消"
      ;;
  esac
}

modify_dns() {
  ensure_dependencies
  ensure_directories

  if [ ! -f "$XRAY_CONFIG" ]; then
    print_error "主配置不存在：$XRAY_CONFIG"
    return 1
  fi

  echo "请选择 DNS（可多选，逗号分隔）："
  echo "1) 8.8.8.8 (Google UDP)"
  echo "2) 8.8.4.4 (Google UDP)"
  echo "3) https+local://dns.google/dns-query (Google DoH)"
  echo "4) 1.1.1.1 (Cloudflare UDP)"
  echo "5) 1.0.0.1 (Cloudflare UDP)"
  echo "6) https+local://cloudflare-dns.com/dns-query (Cloudflare DoH)"
  echo "7) 223.5.5.5 (AliDNS UDP)"
  echo "8) 119.29.29.29 (DNSPod UDP)"
  echo "9) https+local://dns.alidns.com/dns-query (AliDNS DoH)"
  echo "10) 自定义输入"
  printf "输入编号（示例: 3,6 或 4,10）: "
  read -r dns_choice

  [ -n "$dns_choice" ] || { print_error "DNS 选项不能为空"; return 1; }

  dns_input=""

  append_dns_value() {
    val="$1"
    if [ -z "$dns_input" ]; then
      dns_input="$val"
    else
      dns_input="$dns_input,$val"
    fi
  }

  old_ifs="$IFS"
  IFS=','
  set -- $dns_choice
  IFS="$old_ifs"

  for raw_choice in "$@"; do
    choice="$(printf "%s" "$raw_choice" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    case "$choice" in
      1) append_dns_value "8.8.8.8" ;;
      2) append_dns_value "8.8.4.4" ;;
      3) append_dns_value "https+local://dns.google/dns-query" ;;
      4) append_dns_value "1.1.1.1" ;;
      5) append_dns_value "1.0.0.1" ;;
      6) append_dns_value "https+local://cloudflare-dns.com/dns-query" ;;
      7) append_dns_value "223.5.5.5" ;;
      8) append_dns_value "119.29.29.29" ;;
      9) append_dns_value "https+local://dns.alidns.com/dns-query" ;;
      10)
        printf "输入自定义 DNS（逗号分隔）: "
        read -r custom_dns
        [ -n "$custom_dns" ] || { print_error "自定义 DNS 不能为空"; return 1; }
        append_dns_value "$custom_dns"
        ;;
      *)
        print_error "无效编号：$choice"
        return 1
        ;;
    esac
  done

  [ -n "$dns_input" ] || { print_error "DNS 输入不能为空"; return 1; }

  dns_json="$(echo "$dns_input" | awk -F',' '
  BEGIN { printf("[") }
  {
    for (i=1; i<=NF; i++) {
      gsub(/^ +| +$/, "", $i)
      if (length($i) > 0) {
        if (first == 1) { printf(",") }
        printf("\"%s\"", $i)
        first = 1
      }
    }
  }
  END { printf("]") }
  ')"

  safe_write_json "$XRAY_CONFIG" ".dns.servers = $dns_json"
}

load_geo_source() {
  if [ -f "$GEO_SOURCE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$GEO_SOURCE_FILE"
  fi

  [ -n "${GEO_BASE_URL:-}" ] || GEO_BASE_URL="$DEFAULT_GEO_SOURCE"
}

set_geo_source() {
  ensure_directories
  load_geo_source

  printf "当前 GEO 更新地址：%s\n" "$GEO_BASE_URL"
  printf "请输入新的 GEO 更新地址: "
  read -r new_url

  [ -n "$new_url" ] || { print_error "地址不能为空"; return 1; }

  printf "GEO_BASE_URL=%s\n" "$new_url" > "$GEO_SOURCE_FILE"
  chmod 600 "$GEO_SOURCE_FILE" || true

  print_info "已更新 GEO 地址。"
}

update_geo_files() {
  ensure_dependencies
  ensure_directories
  load_geo_source

  tmp_dir="$(mktemp -d)"

  geoip_url="$GEO_BASE_URL/geoip.dat"
  geosite_url="$GEO_BASE_URL/geosite.dat"

  print_info "下载 geoip.dat"
  if ! curl -fL "$geoip_url" -o "$tmp_dir/geoip.dat"; then
    print_error "下载 geoip.dat 失败。"
    rm -rf "$tmp_dir"
    return 1
  fi

  print_info "下载 geosite.dat"
  if ! curl -fL "$geosite_url" -o "$tmp_dir/geosite.dat"; then
    print_error "下载 geosite.dat 失败。"
    rm -rf "$tmp_dir"
    return 1
  fi

  install -m 644 "$tmp_dir/geoip.dat" "$XRAY_DIR/geoip.dat"
  install -m 644 "$tmp_dir/geosite.dat" "$XRAY_DIR/geosite.dat"

  rm -rf "$tmp_dir"
  print_info "GEO 文件更新完成。"
}

print_main_menu() {
  cat <<'EOF'

========= Xray 部署管理 =========
1) 增加配置
2) 修改配置项
3) 删除配置
4) 修改 DNS
5) 重启内核
6) 关闭内核
7) 启动内核
8) 指定 GEOIP 更新地址
9) 更新 GEOIP/GEOSITE
10) 下载/更新 Xray Core
11) 查看内核状态
0) 退出
=================================
EOF
}

run_menu() {
  ensure_directories
  create_default_main_config

  while true; do
    print_main_menu
    printf "请选择操作: "
    read -r action

    case "$action" in
      1) add_config_menu ;;
      2) modify_config_item ;;
      3) delete_config ;;
      4) modify_dns ;;
      5) service_restart ;;
      6) service_stop ;;
      7) service_start ;;
      8) set_geo_source ;;
      9) update_geo_files ;;
      10) download_and_install_xray ;;
      11) service_status ;;
      0) print_info "退出。"; break ;;
      *) print_error "无效选项" ;;
    esac
  done
}

print_help() {
  cat <<EOF
用法: $0 [命令]

无参数时进入交互菜单。

可选命令:
  install-core     下载/更新 Xray Core
  add-config       增加配置（SS/VLESS Encryption/VLESS Reality Vision）
  add             快捷增加配置（支持 ss/vlessenc/reality）
  change          模糊匹配修改配置（文件名/tag/端口）
  del             模糊匹配删除配置（文件名/tag/端口）
  edit-config      修改配置项（jq 路径）
  delete-config    删除子配置
  set-dns          修改主配置 DNS
  set-geo-source   指定 GEO 更新地址
  update-geo       更新 geoip.dat / geosite.dat
  start            启动内核
  stop             关闭内核
  restart          重启内核
  status           查看内核状态
  setup-service    写入 systemd/OpenRC 服务
  help             显示本帮助

示例:
  $0 add ss 8936 w8yXMskMJH00VzmukjN0pFIivjny+RyPOEJqhwDcYXw= 2022-blake3-aes-256-gcm
  $0 add vlessenc 33026 auto
  $0 change 33026 sni www.google.com
  $0 change 33026 decryption auto
  $0 del 33026
EOF
}

main() {
  require_root

  cmd="${1:-menu}"

  case "$cmd" in
    menu) run_menu ;;
    add)
      shift
      add_shortcut "$@"
      ;;
    change)
      shift
      change_shortcut "$@"
      ;;
    del|delete|rm)
      shift
      delete_shortcut "$@"
      ;;
    install-core) download_and_install_xray ;;
    add-config) add_config_menu ;;
    edit-config) modify_config_item ;;
    delete-config) delete_config ;;
    set-dns) modify_dns ;;
    set-geo-source) set_geo_source ;;
    update-geo) update_geo_files ;;
    start) service_start ;;
    stop) service_stop ;;
    restart) service_restart ;;
    status) service_status ;;
    setup-service) setup_service ;;
    help|-h|--help) print_help ;;
    *)
      print_error "未知命令：$cmd"
      print_help
      exit 1
      ;;
  esac
}

main "$@"
