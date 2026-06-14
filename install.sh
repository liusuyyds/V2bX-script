#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

cur_dir=$(pwd)
panel_cmd="qs"
release_repo="${QINGSU_RELEASE_REPO:-liusuyyds/V2bX-liusu}"
script_repo="${QINGSU_SCRIPT_REPO:-liusuyyds/V2bX-script}"
docs_url="${QINGSU_DOCS_URL:-https://github.com/liusuyyds/V2bX-liusu}"
telemetry_url="${QINGSU_TELEMETRY_URL:-}"
script_raw_base="https://raw.githubusercontent.com/${script_repo}/master"
release_api="https://api.github.com/repos/${release_repo}/releases/latest"
release_latest_url="https://github.com/${release_repo}/releases/latest"
release_download_base="https://github.com/${release_repo}/releases/download"

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}错误：${plain} 必须使用root用户运行此脚本！\n" && exit 1

# check os
if [[ -f /etc/redhat-release ]]; then
    release="centos"
elif cat /etc/issue | grep -Eqi "alpine"; then
    release="alpine"
elif cat /etc/issue | grep -Eqi "debian"; then
    release="debian"
elif cat /etc/issue | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /etc/issue | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
    release="centos"
elif cat /proc/version | grep -Eqi "debian"; then
    release="debian"
elif cat /proc/version | grep -Eqi "ubuntu"; then
    release="ubuntu"
elif cat /proc/version | grep -Eqi "centos|red hat|redhat|rocky|alma|oracle linux"; then
    release="centos"
elif cat /proc/version | grep -Eqi "arch"; then
    release="arch"
else
    echo -e "${red}未检测到系统版本，请联系脚本作者！${plain}\n" && exit 1
fi

arch=$(uname -m)

if [[ $arch == "x86_64" || $arch == "x64" || $arch == "amd64" ]]; then
    arch="64"
elif [[ $arch == "aarch64" || $arch == "arm64" ]]; then
    arch="arm64-v8a"
elif [[ $arch == "s390x" ]]; then
    arch="s390x"
else
    arch="64"
    echo -e "${red}检测架构失败，使用默认架构: ${arch}${plain}"
fi

echo "架构: ${arch}"

if [ "$(getconf WORD_BIT)" != '32' ] && [ "$(getconf LONG_BIT)" != '64' ] ; then
    echo "本软件不支持 32 位系统(x86)，请使用 64 位系统(x86_64)，如果检测有误，请联系作者"
    exit 2
fi

# os version
if [[ -f /etc/os-release ]]; then
    os_version=$(awk -F'[= ."]' '/VERSION_ID/{print $3}' /etc/os-release)
fi
if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
    os_version=$(awk -F'[= ."]+' '/DISTRIB_RELEASE/{print $2}' /etc/lsb-release)
fi

if [[ x"${release}" == x"centos" ]]; then
    if [[ ${os_version} -le 6 ]]; then
        echo -e "${red}请使用 CentOS 7 或更高版本的系统！${plain}\n" && exit 1
    fi
    if [[ ${os_version} -eq 7 ]]; then
        echo -e "${red}注意： CentOS 7 无法使用hysteria1/2协议！${plain}\n"
    fi
elif [[ x"${release}" == x"ubuntu" ]]; then
    if [[ ${os_version} -lt 16 ]]; then
        echo -e "${red}请使用 Ubuntu 16 或更高版本的系统！${plain}\n" && exit 1
    fi
elif [[ x"${release}" == x"debian" ]]; then
    if [[ ${os_version} -lt 8 ]]; then
        echo -e "${red}请使用 Debian 8 或更高版本的系统！${plain}\n" && exit 1
    fi
fi

install_base() {
    if [[ x"${release}" == x"centos" ]]; then
        yum install epel-release wget curl unzip tar crontabs socat ca-certificates -y >/dev/null 2>&1
        update-ca-trust force-enable >/dev/null 2>&1
    elif [[ x"${release}" == x"alpine" ]]; then
        apk add wget curl unzip tar socat ca-certificates >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"debian" ]]; then
        apt-get update -y >/dev/null 2>&1
        apt install wget curl unzip tar cron socat ca-certificates -y >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"ubuntu" ]]; then
        apt-get update -y >/dev/null 2>&1
        apt install wget curl unzip tar cron socat -y >/dev/null 2>&1
        apt-get install ca-certificates wget -y >/dev/null 2>&1
        update-ca-certificates >/dev/null 2>&1
    elif [[ x"${release}" == x"arch" ]]; then
        pacman -Sy --noconfirm >/dev/null 2>&1
        pacman -S --noconfirm --needed wget curl unzip tar cron socat >/dev/null 2>&1
        pacman -S --noconfirm --needed ca-certificates wget >/dev/null 2>&1
    fi
}

# 0: running, 1: not running, 2: not installed
check_status() {
    if [[ ! -f /srv/qingsu/qingsu ]]; then
        return 2
    fi
    if [[ x"${release}" == x"alpine" ]]; then
        temp=$(service qingsu status | awk '{print $3}')
        if [[ x"${temp}" == x"started" ]]; then
            return 0
        else
            return 1
        fi
    else
        temp=$(systemctl status qingsu | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1)
        if [[ x"${temp}" == x"running" ]]; then
            return 0
        else
            return 1
        fi
    fi
}

fetch_latest_version_from_api() {
    curl -fsSL "${release_api}" 2>/dev/null | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

fetch_latest_version_from_redirect() {
    local effective_url
    effective_url=$(curl -fsSL -o /dev/null -w '%{url_effective}' "${release_latest_url}" 2>/dev/null)
    if [[ -z "${effective_url}" || "${effective_url}" == "${release_latest_url}" ]]; then
        effective_url=$(curl -fsSI "${release_latest_url}" 2>/dev/null | grep -i '^location:' | tail -n 1 | awk '{print $2}' | tr -d '\r')
    fi
    if [[ -n "${effective_url}" && "${effective_url}" != "${release_latest_url}" ]]; then
        printf '%s\n' "${effective_url##*/}"
    fi
}

fetch_latest_version() {
    local version
    version=$(fetch_latest_version_from_api)
    if [[ -n "${version}" ]]; then
        printf '%s\n' "${version}"
        return 0
    fi

    version=$(fetch_latest_version_from_redirect)
    if [[ -n "${version}" ]]; then
        printf '%s\n' "${version}"
        return 0
    fi

    return 1
}

install_qingsu() {
    if [[ -e /srv/qingsu/ ]]; then
        rm -rf /srv/qingsu/
    fi

    mkdir /srv/qingsu/ -p
    cd /srv/qingsu/

    if  [ $# == 0 ] ;then
        last_version=$(fetch_latest_version)
        if [[ ! -n "$last_version" ]]; then
            echo -e "${red}检测 qingsu 最新版本失败，可能是网络受限或 Github API 限流，请稍后再试，或手动指定 qingsu 版本安装${plain}"
            exit 1
        fi
        echo -e "检测到 qingsu 最新版本：${last_version}，开始安装"
        wget --no-check-certificate -N --progress=bar -O /srv/qingsu/qingsu-linux.zip ${release_download_base}/${last_version}/qingsu-linux-${arch}.zip
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 qingsu 失败，请确保你的服务器能够下载 Github 的文件${plain}"
            exit 1
        fi
    else
        last_version=$1
        url="${release_download_base}/${last_version}/qingsu-linux-${arch}.zip"
        echo -e "开始安装 qingsu $1"
        wget --no-check-certificate -N --progress=bar -O /srv/qingsu/qingsu-linux.zip ${url}
        if [[ $? -ne 0 ]]; then
            echo -e "${red}下载 qingsu $1 失败，请确保此版本存在${plain}"
            exit 1
        fi
    fi

    unzip qingsu-linux.zip
    rm qingsu-linux.zip -f
    chmod +x qingsu
    mkdir /etc/qingsu/ -p
    cp geoip.dat /etc/qingsu/
    cp geosite.dat /etc/qingsu/
    if [[ x"${release}" == x"alpine" ]]; then
        rm /etc/init.d/qingsu -f
        cat <<EOF > /etc/init.d/qingsu
#!/sbin/openrc-run

name="qingsu"
description="qingsu"

command="/srv/qingsu/qingsu"
command_args="server"
command_user="root"

pidfile="/run/qingsu.pid"
command_background="yes"

depend() {
        need net
}
EOF
        chmod +x /etc/init.d/qingsu
        rc-update add qingsu default
        echo -e "${green}qingsu ${last_version}${plain} 安装完成，已设置开机自启"
    else
        rm /etc/systemd/system/qingsu.service -f
        cat <<EOF > /etc/systemd/system/qingsu.service
[Unit]
Description=qingsu Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
User=root
Group=root
Type=simple
LimitAS=infinity
LimitRSS=infinity
LimitCORE=infinity
LimitNOFILE=999999
WorkingDirectory=/srv/qingsu/
ExecStart=/srv/qingsu/qingsu server
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl stop qingsu
        systemctl enable qingsu
        echo -e "${green}qingsu ${last_version}${plain} 安装完成，已设置开机自启"
    fi

    if [[ ! -f /etc/qingsu/config.json ]]; then
        cp config.json /etc/qingsu/
        echo -e ""
        echo -e "全新安装，请先参看教程：${docs_url}，配置必要的内容"
        first_install=true
    else
        if [[ x"${release}" == x"alpine" ]]; then
            service qingsu start
        else
            systemctl start qingsu
        fi
        sleep 2
        check_status
        echo -e ""
        if [[ $? == 0 ]]; then
            echo -e "${green}qingsu 重启成功${plain}"
        else
            echo -e "${red}qingsu 可能启动失败，请稍后使用 ${panel_cmd} log 查看日志信息，若无法启动，请前往说明页查看：${docs_url}${plain}"
        fi
        first_install=false
    fi

    if [[ ! -f /etc/qingsu/dns.json ]]; then
        cp dns.json /etc/qingsu/
    fi
    if [[ ! -f /etc/qingsu/route.json ]]; then
        cp route.json /etc/qingsu/
    fi
    if [[ ! -f /etc/qingsu/custom_outbound.json ]]; then
        cp custom_outbound.json /etc/qingsu/
    fi
    if [[ ! -f /etc/qingsu/custom_inbound.json ]]; then
        cp custom_inbound.json /etc/qingsu/
    fi
    curl -o /usr/bin/${panel_cmd} -Ls ${script_raw_base}/qingsu.sh
    chmod +x /usr/bin/${panel_cmd}
    rm -f /usr/bin/qingsu
    cd $cur_dir
    rm -f install.sh
    echo -e ""
    echo "qingsu 管理脚本使用方法: "
    echo "------------------------------------------"
    echo "${panel_cmd}              - 显示管理菜单 (功能更多)"
    echo "${panel_cmd} start        - 启动 qingsu"
    echo "${panel_cmd} stop         - 停止 qingsu"
    echo "${panel_cmd} restart      - 重启 qingsu"
    echo "${panel_cmd} status       - 查看 qingsu 状态"
    echo "${panel_cmd} enable       - 设置 qingsu 开机自启"
    echo "${panel_cmd} disable      - 取消 qingsu 开机自启"
    echo "${panel_cmd} log          - 查看 qingsu 日志"
    echo "${panel_cmd} x25519       - 生成 x25519 密钥"
    echo "${panel_cmd} generate     - 生成 qingsu 配置文件"
    echo "${panel_cmd} update       - 更新 qingsu"
    echo "${panel_cmd} update x.x.x - 更新 qingsu 指定版本"
    echo "${panel_cmd} install      - 安装 qingsu"
    echo "${panel_cmd} uninstall    - 卸载 qingsu"
    echo "${panel_cmd} version      - 查看 qingsu 版本"
    echo "------------------------------------------"
    if [[ -n "${telemetry_url}" ]]; then
        curl -fsS --max-time 10 "${telemetry_url}" || true
    fi
    # 首次安装询问是否生成配置文件
    if [[ $first_install == true ]]; then
        read -rp "检测到你为第一次安装qingsu,是否自动直接生成配置文件？(y/n): " if_generate
        if [[ $if_generate == [Yy] ]]; then
            curl -o ./initconfig.sh -Ls ${script_raw_base}/initconfig.sh
            source initconfig.sh
            rm initconfig.sh -f
            generate_config_file
        fi
    fi
}

echo -e "${green}开始安装${plain}"
install_base
install_qingsu $1
