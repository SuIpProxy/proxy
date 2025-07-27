#!/bin/bash

# 3proxy一键安装脚本 - Debian 11/12 兼容版本
# 用法: ./install_3proxy.sh [socks5_port] [username] [password]

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 默认配置
DEFAULT_SOCKS5_PORT=1080
DEFAULT_USERNAME="proxy_user"
DEFAULT_PASSWORD="proxy_pass"

# 系统信息
DEBIAN_VERSION=""
SYSTEM_ARCH=""

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

log_blue() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# 显示使用帮助
show_help() {
    echo "=========================================="
    echo "3proxy一键安装脚本 - Debian 11/12"
    echo "=========================================="
    echo
    echo "用法:"
    echo "  $0 [socks5_port] [username] [password]"
    echo
    echo "参数说明:"
    echo "  socks5_port  - SOCKS5端口 (默认: $DEFAULT_SOCKS5_PORT)"
    echo "  username     - 用户名 (默认: $DEFAULT_USERNAME)"
    echo "  password     - 密码 (默认: $DEFAULT_PASSWORD)"
    echo
    echo "示例:"
    echo "  $0                                    # 使用默认配置"
    echo "  $0 50595                              # 指定端口"
    echo "  $0 50595 myuser                       # 指定端口和用户名"
    echo "  $0 50595 myuser mypass                # 指定所有参数"
    echo
    echo "注意: HTTPS端口会自动设置为SOCKS5端口+1"
    echo "支持系统: Debian 11 (Bullseye), Debian 12 (Bookworm)"
    echo "=========================================="
}

# 检测系统版本
detect_system() {
    log_info "检测系统信息..."
    
    # 检测Debian版本
    if [ -f /etc/debian_version ]; then
        DEBIAN_VERSION=$(cat /etc/debian_version)
        log_info "检测到Debian版本: $DEBIAN_VERSION"
        
        # 判断主版本号
        MAJOR_VERSION=$(echo $DEBIAN_VERSION | cut -d. -f1)
        if [[ "$MAJOR_VERSION" != "11" ]] && [[ "$MAJOR_VERSION" != "12" ]]; then
            log_warn "未经测试的Debian版本: $DEBIAN_VERSION"
            log_warn "脚本针对Debian 11/12优化，继续安装可能遇到问题"
            read -p "是否继续安装？(y/N): " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                log_info "安装已取消"
                exit 0
            fi
        fi
    else
        log_error "无法检测到Debian系统"
        exit 1
    fi
    
    # 检测系统架构
    SYSTEM_ARCH=$(uname -m)
    log_info "系统架构: $SYSTEM_ARCH"
    
    # 检查支持的架构
    case "$SYSTEM_ARCH" in
        x86_64|amd64)
            log_info "支持的架构: x86_64"
            ;;
        i386|i686)
            log_info "支持的架构: i386"
            ;;
        aarch64|arm64)
            log_info "支持的架构: ARM64"
            ;;
        armv7l)
            log_info "支持的架构: ARM v7"
            ;;
        *)
            log_warn "未经测试的架构: $SYSTEM_ARCH"
            ;;
    esac
}

# 解析命令行参数
parse_args() {
    # 如果第一个参数是help相关，显示帮助
    if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]] || [[ "$1" == "help" ]]; then
        show_help
        exit 0
    fi
    
    # 解析参数
    SOCKS5_PORT=${1:-$DEFAULT_SOCKS5_PORT}
    USERNAME=${2:-$DEFAULT_USERNAME}
    PASSWORD=${3:-$DEFAULT_PASSWORD}
    
    # 计算HTTPS端口
    HTTPS_PORT=$((SOCKS5_PORT + 1))
    
    # 验证端口范围
    if [[ $SOCKS5_PORT -lt 1024 ]] || [[ $SOCKS5_PORT -gt 65535 ]]; then
        log_error "端口必须在1024-65535范围内"
        exit 1
    fi
    
    if [[ $HTTPS_PORT -gt 65535 ]]; then
        log_error "HTTPS端口超出范围，请选择较小的SOCKS5端口"
        exit 1
    fi
    
    # 验证用户名和密码
    if [[ ${#USERNAME} -lt 3 ]]; then
        log_error "用户名长度不能少于3个字符"
        exit 1
    fi
    
    if [[ ${#PASSWORD} -lt 6 ]]; then
        log_error "密码长度不能少于6个字符"
        exit 1
    fi
    
    log_blue "配置信息:"
    log_blue "  SOCKS5端口: $SOCKS5_PORT"
    log_blue "  HTTPS端口: $HTTPS_PORT"
    log_blue "  用户名: $USERNAME"
    log_blue "  密码: $PASSWORD"
    echo
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请使用root权限运行此脚本"
        exit 1
    fi
}

# 检查端口是否被占用
check_ports() {
    log_info "检查端口占用情况..."
    
    # 安装netstat（如果不存在）
    if ! command -v netstat >/dev/null 2>&1; then
        log_info "安装网络工具..."
        apt update >/dev/null 2>&1
        apt install -y net-tools >/dev/null 2>&1
    fi
    
    if netstat -tuln 2>/dev/null | grep -q ":$SOCKS5_PORT "; then
        log_error "端口 $SOCKS5_PORT 已被占用"
        exit 1
    fi
    
    if netstat -tuln 2>/dev/null | grep -q ":$HTTPS_PORT "; then
        log_error "端口 $HTTPS_PORT 已被占用"
        exit 1
    fi
    
    log_info "端口检查通过"
}

# 更新系统并安装依赖
install_dependencies() {
    log_info "更新系统并安装依赖包..."
    
    # 更新包列表
    apt update
    
    # 基础依赖包
    local packages="wget gcc make libc6-dev net-tools curl"
    
    # Debian 11可能需要额外的包
    if [[ "$DEBIAN_VERSION" == "11"* ]]; then
        packages="$packages build-essential"
    fi
    
    # 安装依赖
    apt install -y $packages
    
    log_info "依赖包安装完成"
}

# 下载并编译3proxy
install_3proxy() {
    log_info "下载并编译3proxy..."
    
    cd /tmp
    
    # 清理可能存在的旧文件
    rm -rf 3proxy-*
    
    # 尝试下载最新版本
    local download_success=false
    
    # 尝试下载0.9.4版本
    if wget -O 3proxy-0.9.4.tar.gz https://github.com/3proxy/3proxy/archive/0.9.4.tar.gz 2>/dev/null; then
        tar -xzf 3proxy-0.9.4.tar.gz
        cd 3proxy-0.9.4
        download_success=true
        log_info "下载3proxy 0.9.4版本成功"
    else
        log_warn "GitHub下载失败，尝试备用源..."
        # 如果GitHub下载失败，可以添加备用下载源
        log_error "下载失败，请检查网络连接"
        exit 1
    fi
    
    if [ "$download_success" = false ]; then
        log_error "无法下载3proxy源码"
        exit 1
    fi
    
    # 编译
    log_info "开始编译3proxy..."
    
    # 根据系统选择编译选项
    if [[ "$SYSTEM_ARCH" == "aarch64" ]] || [[ "$SYSTEM_ARCH" == "arm64" ]]; then
        make -f Makefile.Linux CC=gcc CFLAGS="-O2 -fPIC"
    else
        make -f Makefile.Linux
    fi
    
    if [ $? -ne 0 ]; then
        log_error "编译失败"
        exit 1
    fi
    
    # 创建目录并安装
    mkdir -p /etc/3proxy
    mkdir -p /var/log/3proxy
    
    # 复制二进制文件
    if [ -f bin/3proxy ]; then
        cp bin/3proxy /usr/local/bin/
        chmod +x /usr/local/bin/3proxy
        log_info "3proxy安装完成"
    else
        log_error "编译后未找到3proxy可执行文件"
        exit 1
    fi
}

# 创建配置文件
create_config() {
    log_info "创建3proxy配置文件..."
    
    cat > /etc/3proxy/3proxy.cfg << EOF
# 3proxy配置文件
# 生成时间: $(date)
# 系统版本: Debian $DEBIAN_VERSION
# SOCKS5端口: $SOCKS5_PORT
# HTTPS端口: $HTTPS_PORT
# 用户名: $USERNAME

daemon
pidfile /var/run/3proxy.pid

# DNS服务器配置
nserver 8.8.8.8
nserver 8.8.4.4
nserver 1.1.1.1
nscache 65536

# 超时设置
timeouts 1 5 30 60 180 1800 15 60

# 日志配置
log /var/log/3proxy/3proxy.log D
logformat "- +_L%t.%. %N.%p %E %U %C:%c %R:%r %O %I %h %T"
rotate 30

# 用户认证
users $USERNAME:CL:$PASSWORD

# 访问控制
auth strong

# 允许认证用户访问
allow $USERNAME

# SOCKS5代理 - 端口$SOCKS5_PORT
socks -p$SOCKS5_PORT

# HTTPS代理 - 端口$HTTPS_PORT
proxy -p$HTTPS_PORT
EOF

    chmod 600 /etc/3proxy/3proxy.cfg
    log_info "配置文件创建完成"
}

# 创建systemd服务
create_service() {
    log_info "创建systemd服务..."
    
    cat > /etc/systemd/system/3proxy.service << EOF
[Unit]
Description=3proxy Proxy Server
After=network.target
Documentation=https://github.com/3proxy/3proxy

[Service]
Type=forking
PIDFile=/var/run/3proxy.pid
ExecStart=/usr/local/bin/3proxy /etc/3proxy/3proxy.cfg
ExecReload=/bin/kill -HUP \$MAINPID
ExecStop=/bin/kill -TERM \$MAINPID
KillMode=process
Restart=on-failure
RestartSec=5s
User=root
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable 3proxy
    
    log_info "systemd服务创建完成"
}

# 配置防火墙
configure_firewall() {
    log_info "配置防火墙规则..."
    
    # 检查是否安装了ufw
    if command -v ufw >/dev/null 2>&1; then
        # 检查ufw状态
        if ufw status | grep -q "Status: active"; then
            ufw allow $SOCKS5_PORT/tcp comment "3proxy SOCKS5"
            ufw allow $HTTPS_PORT/tcp comment "3proxy HTTPS"
            log_info "UFW防火墙规则已添加"
        else
            log_info "UFW未启用，跳过UFW配置"
        fi
    fi
    
    # 检查是否有iptables
    if command -v iptables >/dev/null 2>&1; then
        iptables -I INPUT -p tcp --dport $SOCKS5_PORT -j ACCEPT
        iptables -I INPUT -p tcp --dport $HTTPS_PORT -j ACCEPT
        
        # 尝试保存iptables规则
        if command -v iptables-save >/dev/null 2>&1; then
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
            
            # Debian 11可能需要安装iptables-persistent
            if [[ "$DEBIAN_VERSION" == "11"* ]]; then
                if ! dpkg -l | grep -q iptables-persistent; then
                    log_info "安装iptables-persistent以保存规则..."
                    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
                    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
                    apt install -y iptables-persistent >/dev/null 2>&1
                fi
            fi
        fi
        log_info "iptables防火墙规则已添加"
    fi
}

# 启动服务
start_service() {
    log_info "启动3proxy服务..."
    
    # 停止可能已经运行的服务
    systemctl stop 3proxy 2>/dev/null || true
    sleep 1
    
    systemctl start 3proxy
    sleep 3
    
    if systemctl is-active --quiet 3proxy; then
        log_info "3proxy服务启动成功"
    else
        log_error "3proxy服务启动失败"
        echo "错误详情:"
        systemctl status 3proxy --no-pager
        echo
        echo "日志信息:"
        journalctl -u 3proxy --no-pager -n 20
        echo
        echo "配置文件检查:"
        /usr/local/bin/3proxy -t /etc/3proxy/3proxy.cfg
        exit 1
    fi
}

# 测试端口连通性
test_ports() {
    log_info "测试端口连通性..."
    
    sleep 2
    
    # 测试SOCKS5端口
    if netstat -tuln | grep -q ":$SOCKS5_PORT "; then
        log_info "SOCKS5端口 $SOCKS5_PORT 监听正常"
    else
        log_warn "SOCKS5端口 $SOCKS5_PORT 可能未正常监听"
    fi
    
    # 测试HTTPS端口
    if netstat -tuln | grep -q ":$HTTPS_PORT "; then
        log_info "HTTPS端口 $HTTPS_PORT 监听正常"
    else
        log_warn "HTTPS端口 $HTTPS_PORT 可能未正常监听"
    fi
}

# 显示配置信息
show_info() {
    local server_ip=$(curl -s --connect-timeout 10 http://ipv4.icanhazip.com 2>/dev/null || curl -s --connect-timeout 10 http://ipinfo.io/ip 2>/dev/null || echo "获取IP失败")
    
    echo
    echo "=========================================="
    echo -e "${GREEN}3proxy代理服务安装完成！${NC}"
    echo "=========================================="
    echo
    echo -e "${BLUE}系统信息:${NC}"
    echo "  系统版本: Debian $DEBIAN_VERSION"
    echo "  系统架构: $SYSTEM_ARCH"
    echo "  服务器IP: $server_ip"
    echo "  安装时间: $(date)"
    echo
    echo -e "${BLUE}SOCKS5代理配置:${NC}"
    echo "  服务器: $server_ip"
    echo "  端口: $SOCKS5_PORT"
    echo "  用户名: $USERNAME"
    echo "  密码: $PASSWORD"
    echo
    echo -e "${BLUE}HTTPS代理配置:${NC}"
    echo "  服务器: $server_ip"
    echo "  端口: $HTTPS_PORT"
    echo "  用户名: $USERNAME"
    echo "  密码: $PASSWORD"
    echo
    echo -e "${BLUE}服务管理命令:${NC}"
    echo "  启动服务: systemctl start 3proxy"
    echo "  停止服务: systemctl stop 3proxy"
    echo "  重启服务: systemctl restart 3proxy"
    echo "  查看状态: systemctl status 3proxy"
    echo "  查看日志: tail -f /var/log/3proxy/3proxy.log"
    echo "  管理工具: 3proxy-manage {start|stop|restart|status|log|config}"
    echo
    echo -e "${BLUE}配置文件:${NC}"
    echo "  配置文件: /etc/3proxy/3proxy.cfg"
    echo "  服务文件: /etc/systemd/system/3proxy.service"
    echo "  日志文件: /var/log/3proxy/3proxy.log"
    echo
    echo -e "${BLUE}测试连接:${NC}"
    echo "  SOCKS5: curl --proxy socks5://$USERNAME:$PASSWORD@$server_ip:$SOCKS5_PORT http://ipinfo.io/ip"
    echo "  HTTPS:  curl --proxy http://$USERNAME:$PASSWORD@$server_ip:$HTTPS_PORT http://ipinfo.io/ip"
    echo "=========================================="
}

# 创建管理脚本
create_management_script() {
    log_info "创建管理脚本..."
    
    cat > /usr/local/bin/3proxy-manage << 'EOF'
#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

case "$1" in
    start)
        systemctl start 3proxy
        if systemctl is-active --quiet 3proxy; then
            echo -e "${GREEN}3proxy服务已启动${NC}"
        else
            echo -e "${RED}3proxy服务启动失败${NC}"
        fi
        ;;
    stop)
        systemctl stop 3proxy
        echo -e "${YELLOW}3proxy服务已停止${NC}"
        ;;
    restart)
        systemctl restart 3proxy
        if systemctl is-active --quiet 3proxy; then
            echo -e "${GREEN}3proxy服务已重启${NC}"
        else
            echo -e "${RED}3proxy服务重启失败${NC}"
        fi
        ;;
    status)
        systemctl status 3proxy --no-pager
        echo
        echo "端口监听状态:"
        netstat -tuln | grep -E ":($(grep -o 'p[0-9]\+' /etc/3proxy/3proxy.cfg | sed 's/p//g' | tr '\n' '|' | sed 's/|$//'))"
        ;;
    log)
        tail -f /var/log/3proxy/3proxy.log
        ;;
    config)
        if command -v nano >/dev/null 2>&1; then
            nano /etc/3proxy/3proxy.cfg
        elif command -v vim >/dev/null 2>&1; then
            vim /etc/3proxy/3proxy.cfg
        else
            vi /etc/3proxy/3proxy.cfg
        fi
        echo "配置修改后需要重启服务: systemctl restart 3proxy"
        ;;
    test)
        echo "测试配置文件语法..."
        /usr/local/bin/3proxy -t /etc/3proxy/3proxy.cfg
        ;;
    *)
        echo "3proxy管理工具"
        echo "用法: $0 {start|stop|restart|status|log|config|test}"
        echo "  start   - 启动服务"
        echo "  stop    - 停止服务"
        echo "  restart - 重启服务"
        echo "  status  - 查看状态"
        echo "  log     - 查看日志"
        echo "  config  - 编辑配置"
        echo "  test    - 测试配置"
        exit 1
        ;;
esac
EOF

    chmod +x /usr/local/bin/3proxy-manage
    log_info "管理脚本创建完成: 3proxy-manage"
}

# 清理临时文件
cleanup() {
    log_info "清理临时文件..."
    rm -rf /tmp/3proxy-*
}

# 主函数
main() {
    echo "=========================================="
    echo "3proxy一键安装脚本 - Debian 11/12"
    echo "=========================================="
    
    detect_system
    parse_args "$@"
    check_root
    check_ports
    install_dependencies
    install_3proxy
    create_config
    create_service
    configure_firewall
    start_service
    test_ports
    create_management_script
    cleanup
    show_info
}

# 运行主函数
main "$@"
