#!/bin/bash

# sing-box VPS服务器部署脚本
# 适用于 Ubuntu 20.04/22.04 和 Debian 10/11

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查root权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "此脚本需要root权限运行"
        exit 1
    fi
}

# 更新系统
update_system() {
    log_info "正在更新系统包..."
    apt update && apt upgrade -y
    apt install -y curl wget unzip software-properties-common
}

# 安装sing-box
install_singbox() {
    log_info "正在下载和安装sing-box 1.12.1..."
    
    # 检测系统架构
    ARCH=$(uname -m)
    case $ARCH in
        x86_64)
            ARCH="amd64"
            ;;
        aarch64)
            ARCH="arm64"
            ;;
        *)
            log_error "不支持的系统架构: $ARCH"
            exit 1
            ;;
    esac
    
    # 下载sing-box
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v1.12.1/sing-box-1.12.1-linux-${ARCH}.tar.gz"
    wget -O sing-box.tar.gz "$DOWNLOAD_URL"
    
    # 解压和安装
    tar -xzf sing-box.tar.gz
    cp sing-box-1.12.1-linux-${ARCH}/sing-box /usr/local/bin/
    chmod +x /usr/local/bin/sing-box
    
    # 清理临时文件
    rm -rf sing-box.tar.gz sing-box-1.12.1-linux-${ARCH}
    
    log_info "sing-box安装完成"
}

# 安装和配置SSL证书
setup_ssl() {
    read -p "请输入您的域名: " DOMAIN
    
    if [[ -z "$DOMAIN" ]]; then
        log_error "域名不能为空"
        exit 1
    fi
    
    log_info "正在安装certbot..."
    apt install -y certbot
    
    log_info "正在申请SSL证书..."
    certbot certonly --standalone --agree-tos --register-unsafely-without-email -d "$DOMAIN"
    
    if [[ $? -ne 0 ]]; then
        log_error "SSL证书申请失败"
        exit 1
    fi
    
    log_info "SSL证书申请成功"
    
    # 设置证书自动续期
    echo "0 12 * * * /usr/bin/certbot renew --quiet && systemctl restart sing-box" | crontab -
}

# 创建配置文件
create_config() {
    log_info "正在创建sing-box配置文件..."
    
    mkdir -p /etc/sing-box
    
    # 生成随机密码
    PASSWORD=$(openssl rand -base64 16)
    
    cat > /etc/sing-box/config.json << EOF
{
    "log": {
        "disabled": false,
        "level": "info",
        "timestamp": true
    },
    "dns": {
        "servers": [
            {
                "tag": "cloudflare",
                "address": "1.1.1.1"
            },
            {
                "tag": "local",
                "address": "223.5.5.5",
                "detour": "direct"
            }
        ],
        "rules": [
            {
                "outbound": "any",
                "server": "local"
            }
        ],
        "final": "cloudflare",
        "strategy": "prefer_ipv4"
    },
    "inbounds": [
        {
            "type": "anytls",
            "listen": "::",
            "listen_port": 443,
            "users": [
                {
                    "name": "user",
                    "password": "$PASSWORD"
                }
            ],
            "padding_scheme": [
                "stop=8",
                "0=30-30",
                "1=100-400",
                "2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000",
                "3=9-9,500-1000",
                "4=500-1000",
                "5=500-1000",
                "6=500-1000",
                "7=500-1000"
            ],
            "tls": {
                "enabled": true,
                "server_name": "$DOMAIN",
                "certificate": "/etc/letsencrypt/live/$DOMAIN/fullchain.pem",
                "private_key": "/etc/letsencrypt/live/$DOMAIN/privkey.pem",
                "reality": {
                    "enabled": false
                }
            }
        }
    ],
    "outbounds": [
        {
            "type": "direct",
            "tag": "direct"
        },
        {
            "type": "block",
            "tag": "block"
        }
    ],
    "route": {
        "rules": [
            {
                "protocol": "dns",
                "outbound": "dns-out"
            },
            {
                "inbound": "anytls",
                "outbound": "direct"
            }
        ],
        "final": "direct",
        "auto_detect_interface": true
    },
    "experimental": {
        "cache_file": {
            "enabled": true,
            "path": "/var/lib/sing-box/cache.db"
        }
    }
}
EOF
    
    log_info "配置文件已创建: /etc/sing-box/config.json"
    log_info "用户名: user"
    log_info "密码: $PASSWORD"
}

# 创建systemd服务
create_service() {
    log_info "正在创建systemd服务..."
    
    cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=1800s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    
    # 创建数据目录
    mkdir -p /var/lib/sing-box
    
    # 重载systemd配置
    systemctl daemon-reload
    systemctl enable sing-box
    
    log_info "systemd服务配置完成"
}

# 配置防火墙
setup_firewall() {
    log_info "正在配置防火墙..."
    
    # 检查是否安装了ufw
    if command -v ufw > /dev/null; then
        ufw allow 22/tcp
        ufw allow 443/tcp
        ufw allow 80/tcp
        echo "y" | ufw enable
        log_info "UFW防火墙配置完成"
    elif command -v iptables > /dev/null; then
        iptables -A INPUT -p tcp --dport 22 -j ACCEPT
        iptables -A INPUT -p tcp --dport 443 -j ACCEPT
        iptables -A INPUT -p tcp --dport 80 -j ACCEPT
        iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
        iptables -A INPUT -i lo -j ACCEPT
        iptables -P INPUT DROP
        iptables-save > /etc/iptables/rules.v4
        log_info "iptables防火墙配置完成"
    else
        log_warn "未找到防火墙工具，请手动配置防火墙开放443端口"
    fi
}

# 启动服务
start_service() {
    log_info "正在启动sing-box服务..."
    
    systemctl start sing-box
    
    if systemctl is-active --quiet sing-box; then
        log_info "sing-box服务启动成功"
    else
        log_error "sing-box服务启动失败"
        log_info "查看错误日志: journalctl -u sing-box -f"
        exit 1
    fi
}

# 显示服务状态和连接信息
show_status() {
    log_info "服务部署完成！"
    echo "======================================"
    echo "服务状态: $(systemctl is-active sing-box)"
    echo "监听端口: 443"
    echo "域名: $DOMAIN"
    echo "协议: anytls"
    echo "用户名: user"
    echo "密码: $PASSWORD"
    echo "======================================"
    echo "管理命令:"
    echo "启动服务: systemctl start sing-box"
    echo "停止服务: systemctl stop sing-box"
    echo "重启服务: systemctl restart sing-box"
    echo "查看状态: systemctl status sing-box"
    echo "查看日志: journalctl -u sing-box -f"
    echo "======================================"
}

# 主函数
main() {
    log_info "开始部署sing-box服务器..."
    
    check_root
    update_system
    install_singbox
    setup_ssl
    create_config
    create_service
    setup_firewall
    start_service
    show_status
    
    log_info "部署完成！"
}

# 运行主函数
main "$@"
