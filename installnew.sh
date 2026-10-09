#!/usr/bin/env bash

# 等待1秒, 避免curl下载脚本的打印与脚本本身的显示冲突, 吃掉了提示用户按回车继续的信息
sleep 1

echo -e "                     _ ___                   \n ___ ___ __ __ ___ _| |  _|___ __ __   _ ___ \n|-_ |_  |  |  |-_ | _ |   |- _|  |  |_| |_  |\n|___|___|  _  |___|___|_|_|___|  _  |___|___|\n        |_____|               |_____|        "
red='\e[91m'
green='\e[92m'
yellow='\e[93m'
magenta='\e[95m'
cyan='\e[96m'
none='\e[0m'
_red() { echo -e ${red}$*${none}; }
_green() { echo -e ${green}$*${none}; }
_yellow() { echo -e ${yellow}$*${none}; }
_magenta() { echo -e ${magenta}$*${none}; }
_cyan() { echo -e ${cyan}$*${none}; }

error() {
    echo -e "\n$red 输入错误! $none\n"
}

pause() {
    read -rsp "$(echo -e "按 $green Enter 回车键 $none 继续....或按 $red Ctrl + C $none 取消.")" -d $'\n'
    echo
}

# 只读取旧配置中的数据，不执行配置，也不复制旧模板或其他指令。
# 支持本脚本生成的单行字段，以及旧模板中的 tls 邮箱写法。
# 支持单行简单引号；转义、多行文本、import、片段和多组账号不猜测。
read_existing_naive_config() {
    local config_file=$1 parsed
    local -a fields=()
    old_tls_email=""
    old_naive_user=""
    old_naive_pass=""
    [[ -r "$config_file" ]] || return 1

    if ! parsed=$(LC_ALL=C awk '
        function plain(value) {
            return value != "" && value !~ /[[:space:][:cntrl:]{}"\\`#]/ && value !~ /^<</
        }
        # 仅识别可可靠还原的单行 token，避免把字符串里的指令当配置。
        function tokenize(line,    pos, ch, value, quoted, closed) {
            delete token
            delete is_quoted
            count = 0
            pos = 1
            while (pos <= length(line)) {
                ch = substr(line, pos, 1)
                if (ch ~ /[ \t]/) { pos++; continue }
                if (ch == "#") break
                value = ""
                quoted = ch == "\""
                if (quoted) {
                    pos++
                    closed = 0
                    while (pos <= length(line)) {
                        ch = substr(line, pos++, 1)
                        if (ch == "\"") { closed = 1; break }
                        if (ch == "\\") return 0
                        value = value ch
                    }
                    if (!closed || (pos <= length(line) && substr(line, pos, 1) !~ /[ \t]/)) return 0
                } else {
                    while (pos <= length(line) && substr(line, pos, 1) !~ /[ \t]/) {
                        ch = substr(line, pos++, 1)
                        if (ch == "\\" || ch == "`" || ch == "\"") return 0
                        value = value ch
                    }
                    if (value ~ /^<</) return 0
                }
                token[++count] = value
                is_quoted[count] = quoted
            }
            return 1
        }
        {
            sub(/\r$/, "")
            if ($0 ~ /[\001-\010\013-\037\177]/ || !tokenize($0)) { invalid = 1; exit }
            if (!count) next
            # 不展开外部文件、环境变量或片段，也不从未使用的片段提取凭据。
            if (token[1] == "import" || (depth == 0 && token[1] ~ /^\(/)) { invalid = 1; exit }
            if (!is_quoted[1] && token[1] == "}") {
                if (count != 1 || depth == 0) { invalid = 1; exit }
                if (depth == proxy_depth) proxy_depth = 0
                depth--
                next
            }
            opening = !is_quoted[count] && token[count] == "{"
            for (i = 1; i <= count - opening; i++) {
                if (!is_quoted[i] && (token[i] == "{" || token[i] == "}")) invalid = 1
            }
            if (invalid) exit
            if (depth == 0) {
                if (!opening) { invalid = 1; exit }
                global_block = count == 1
                if (!global_block) site++
            }
            if (!global_block && token[1] == "forward_proxy") {
                proxy_count++
                proxy_site = site
                if (!opening || count != 2 || depth < 1) { invalid = 1; exit }
                proxy_depth = depth + 1
            }
            if (global_block && depth == 1 && token[1] == "email") {
                email_count++
                if (count == 2 && plain(token[2]) && index(token[2], "@")) email = token[2]
            }
            if (!global_block && depth == 1 && token[1] == "tls") {
                tls_count[site]++
                if (count == 2 && plain(token[2]) && index(token[2], "@")) tls_email[site] = token[2]
            }
            if (proxy_depth && depth == proxy_depth && token[1] == "basic_auth") {
                auth_count++
                if (count == 3 && plain(token[2]) && plain(token[3])) {
                    username = token[2]
                    password = token[3]
                }
            }
            if (opening) depth++
        }
        END {
            if (invalid || depth != 0 || proxy_count != 1) exit 1
            print "yes"
            # 站点 tls 邮箱优先于全局默认值，绝不借用其他站点的邮箱。
            if (tls_count[proxy_site] == 1) print tls_email[proxy_site]
            else if (tls_count[proxy_site] == 0 && email_count == 1) print email
            else print ""
            print auth_count == 1 ? username : ""
            print auth_count == 1 ? password : ""
            print "_end_"
        }
    ' "$config_file"); then
        return 1
    fi
    mapfile -t fields <<< "$parsed"

    [[ ${#fields[@]} -eq 5 && ${fields[0]} == "yes" && ${fields[4]} == "_end_" ]] || return 1
    old_tls_email=${fields[1]}
    old_naive_user=${fields[2]}
    old_naive_pass=${fields[3]}
}

reuse_existing_naive_config() {
    local config_file=$1 reuse_old
    [[ -f "$config_file" ]] || return 0
    if ! read_existing_naive_config "$config_file"; then
        printf '%s\n' "未能从已有 Caddyfile 识别 NaïveProxy 配置，将按原流程设置邮箱和账号。"
        return 0
    fi
    if [[ -z "$old_tls_email" && -z "$old_naive_user" && -z "$old_naive_pass" ]]; then
        printf '%s\n' "检测到已有 NaïveProxy 配置，但无法唯一读取邮箱或账号，将按原流程设置。"
        return 0
    fi

    printf '\n%s\n' "检测到已有 NaïveProxy 配置，可复用以下信息："
    [[ -n "$old_tls_email" ]] && printf '邮箱: %s\n' "$old_tls_email"
    [[ -n "$old_naive_user" ]] && printf '用户名: %s\n密码: [已读取，不显示]\n' "$old_naive_user"
    printf '%s\n' "仅复用邮箱、用户名和密码，新配置始终使用本脚本自带模板。"
    printf '%s\n' "命令行指定的用户名、密码优先；未读取到的字段按原流程设置。"
    while :; do
        if ! read -r -p "是否复用已有信息？[Y/n]: " reuse_old; then
            printf '\n%s\n' "未收到复用选择，已取消安装。" >&2
            return 1
        fi
        case "$reuse_old" in
            "" | [yY] | [yY][eE][sS])
                tls_email=$old_tls_email
                [[ -n "${naive_user:-}" ]] || naive_user=$old_naive_user
                [[ -n "${naive_pass:-}" ]] || naive_pass=$old_naive_pass
                break
                ;;
            [nN] | [nN][oO]) break ;;
            *) printf '%s\n' "请输入 Y 或 n。" ;;
        esac
    done
    return 0
}

# 按字节编码 URI userinfo，保留密码中的 @、:、%、? 等字面值。
urlencode() {
    local LC_ALL=C value=$1 char encoded i
    for ((i = 0; i < ${#value}; i++)); do
        char=${value:i:1}
        case "$char" in
            [a-zA-Z0-9.~_-]) printf '%s' "$char" ;;
            *) printf -v encoded '%%%02X' "'$char"; printf '%s' "$encoded" ;;
        esac
    done
}

# 说明
echo
echo -e "$yellow此脚本仅兼容于Debian 10+系统. 如果你的系统不符合,请Ctrl+C退出脚本$none"
echo -e "可以查看脚本整体思路和关键命令, 以便针对你自己的系统做出调整."
echo "本脚本支持带参数执行, 在参数中输入域名, 网络栈, 端口, 用户名, 密码. 详见GitHub."
echo "----------------------------------------------------------------"

# 本机 IP
InFaces=($(ls /sys/class/net/ | grep -E '^(eth|ens|eno|esp|enp|venet|vif)'))

for i in "${InFaces[@]}"; do  # 从网口循环获取IP
    # 增加超时时间, 以免在某些网络环境下请求IPv6等待太久
    Public_IPv4=$(curl -4s --interface "$i" -m 2 https://www.cloudflare.com/cdn-cgi/trace | grep -oP "ip=\K.*$")
    Public_IPv6=$(curl -6s --interface "$i" -m 2 https://www.cloudflare.com/cdn-cgi/trace | grep -oP "ip=\K.*$")

    if [[ -n "$Public_IPv4" ]]; then  # 检查是否获取到IP地址
        IPv4="$Public_IPv4"
    fi
    if [[ -n "$Public_IPv6" ]]; then  # 检查是否获取到IP地址            
        IPv6="$Public_IPv6"
    fi
done

# 执行脚本带参数
if [ $# -ge 1 ]; then
    # 默认不重新编译
    not_rebuild="Y"

    # 第1个参数是 域名
    naive_domain=${1:-}

    # 第2个参数是搭在ipv4还是ipv6上
    case ${2:-} in
    4)
        netstack=4
        ;;
    6)
        netstack=6
        ;;    
    *) # initial
        netstack="i"
        ;;    
    esac
    
    # 第3个参数是 端口
    naive_port=${3:-}
    if [[ -z $naive_port ]]; then
        naive_port=443
    fi
    
    #第4个参数是 用户名
    naive_user=${4:-}

    #第5个参数是 密码
    naive_pass=${5:-}
fi

# 在安装软件、停止服务或覆盖 Caddyfile 之前读取旧值。
tls_email=""
reuse_existing_naive_config /etc/caddy/Caddyfile || exit 1

# 先处理旧配置复用，再为未提供的命令行参数生成默认值。
if [ $# -ge 1 ]; then
    if [[ -z $naive_user ]]; then
        naive_user=$(openssl rand -hex 8)
    fi
    if [[ -z $naive_pass ]]; then 
        # 默认与用户名相等
        naive_pass=$naive_user
    fi

    echo -e "域名: ${naive_domain}"
    echo -e "端口: ${naive_port}"
    echo -e "用户名: ${naive_user}"
    echo -e "密码: ${naive_pass}"
fi

pause

# 准备
apt update
apt install -y sudo curl wget git jq qrencode
apt install -y xz-utils

# 安装Caddy最新版
echo
echo -e "$yellow安装Caddy最新版本$none"
echo "----------------------------------------------------------------"
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg --yes
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install caddy

systemctl enable caddy

# 判断系统架构
case "$(uname -m)" in
    *aarch64* | *armv8*)
        SYSTEM_ARCH="arm64"
        not_rebuild="N"    #必须自己编译
        ;;
    'amd64' | 'x86_64')
        SYSTEM_ARCH="amd64"
        ;;
    *)
        SYSTEM_ARCH="$(uname -m)"
        echo -e "${red}${SYSTEM_ARCH}${none}"
        not_rebuild="N"    #必须自己编译
        ;;
esac

# 是否自己编译
if [[ -z $not_rebuild ]]; then
    echo
    echo -e "${yellow}本系统架构是${magenta}${SYSTEM_ARCH}${none}${yellow}, 你同意直接下载NaïveProxy作者编译好的Caddy吗?${none}"
    echo -e "${magenta}Y${none}, 使用编译好的Caddy; ${magenta}n${none}, 重新编译. (直接回车默认${magenta}Y${none})"
    while :; do 
        read -p "(Y/n): " not_rebuild
        [[ -z $not_rebuild ]] && not_rebuild="Y"
        case "$not_rebuild" in
            [yYnN])
                break
                ;;
            *)
                error
                ;;
        esac
    done
fi

if [[ "$not_rebuild" == [yY] ]]; then
    echo
    echo -e "$yellow下载NaïveProxy作者编译的Caddy$none"
    echo "----------------------------------------------------------------"
    cd /tmp
    rm caddy-forwardproxy-naive.tar.xz
    rm -r caddy-forwardproxy-naive
    wget https://github.com/klzgrad/forwardproxy/releases/download/v2.11.7-naive/caddy-forwardproxy-naive.tar.xz
    tar -xf caddy-forwardproxy-naive.tar.xz
    cd caddy-forwardproxy-naive
    ./caddy version
elif [[ "$not_rebuild" == [nN] ]]; then
    echo
    echo -e "$yellow自己编译NaïveProxy的Caddy$none"
    echo "----------------------------------------------------------------"
    cd /tmp
    bash <( curl -L https://github.com/ponyspeed/installnaive/raw/main/buildcaddy.sh)
else
    error
fi

# 替换caddy可执行文件
echo
echo -e "$yellow替换Caddy可执行文件$none"
echo "----------------------------------------------------------------"
service caddy stop
cp caddy /usr/bin/

# 自定义WEB站点页面
echo
echo -e "$yellow 空白页面 $none"
echo "----------------------------------------------------------------"
rm -r /var/www/chtml
mkdir -p /var/www/chtml
echo "<html></html>" > /var/www/chtml/index.html


# 域名
if [[ -z $naive_domain ]]; then
    while :; do
        echo
        echo -e "请输入一个 ${magenta}正确的域名${none} Input your domain"
        read -p "(例如: mydomain.com): " naive_domain
        [ -z "$naive_domain" ] && error && continue
        echo
        echo
        echo -e "$yellow 你的域名Domain = $cyan$naive_domain$none"
        echo "----------------------------------------------------------------"
        break
    done
fi

# 网络栈
if [[ -z $netstack ]]; then
    echo -e "如果你的小鸡是${magenta}双栈(同时有IPv4和IPv6的IP)${none}，请选择你把v2ray搭在哪个'网口'上"
    echo "如果你不懂这段话是什么意思, 请直接回车"
    read -p "$(echo -e "Input ${cyan}4${none} for IPv4, ${cyan}6${none} for IPv6:") " netstack
    if [[ $netstack == "4" ]]; then
        domain_resolve=$(curl -sH 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=$naive_domain&type=A" | jq -r '.Answer[0].data')
    elif [[ $netstack == "6" ]]; then 
        domain_resolve=$(curl -sH 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=$naive_domain&type=AAAA" | jq -r '.Answer[0].data')
    else
        domain_resolve=$(curl -sH 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=$naive_domain&type=A" | jq -r '.Answer[0].data')
        if [[ "$domain_resolve" != "null" ]]; then
            netstack="4"
        else
            domain_resolve=$(curl -sH 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=$naive_domain&type=AAAA" | jq -r '.Answer[0].data')            
            if [[ "$domain_resolve" != "null" ]]; then
                netstack="6"
            fi
        fi
    fi

    # 本机 IP
    # 在脚本的一开头就检测了本机IP
    if [[ $netstack == "4" ]]; then
        ip=$IPv4
    elif [[ $netstack == "6" ]]; then
        ip=$IPv6
    else
        ip=$IPv4,$IPv6
    fi

    if [[ $domain_resolve != $ip ]]; then
        echo
        echo -e "$red 域名解析错误Domain resolution error....$none"
        echo
        echo -e " 你的域名: $yellow$domain$none 未解析到: $cyan$ip$none"
        echo
        if [[ $domain_resolve != "null" ]]; then
            echo -e " 你的域名当前解析到: $cyan$domain_resolve$none"
        else
            echo -e " $red检测不到域名解析Domain not resolved $none "
        fi
        echo
        echo -e "备注...如果你的域名是使用$yellow Cloudflare $none解析的话... 在 DNS 设置页面, 请将$yellow代理状态$none设置为$yellow仅限DNS$none, 小云朵变灰."
        echo "Notice...If you use Cloudflare to resolve your domain, on 'DNS' setting page, 'Proxy status' should be 'DNS only' but not 'Proxied'."
        echo
        exit 1
    else
        echo
        echo
        echo -e "$yellow 域名解析 = ${cyan}我确定已经有解析了$none"
        echo "----------------------------------------------------------------"
        echo
    fi
fi

# 端口
if [[ -z $naive_port ]]; then
    default=443
    while :; do
        echo -e "请输入 ${yellow}端口${none} [${magenta}1-65535${none}], 不能选择 ${magenta}80${none}端口"
        read -p "$(echo -e "(默认端口port: ${cyan}${default}$none):")" naive_port
        [ -z "$naive_port" ] && naive_port=$default
        case $naive_port in
        80)
            echo
            echo " ...都说了不能选择 80 端口了咯....."
            error
            ;;
        [1-9] | [1-9][0-9] | [1-9][0-9][0-9] | [1-9][0-9][0-9][0-9] | [1-5][0-9][0-9][0-9][0-9] | 6[0-4][0-9][0-9][0-9] | 65[0-4][0-9][0-9] | 655[0-3][0-5])
            echo
            echo
            echo -e "$yellow 端口Port = $cyan$naive_port$none"
            echo "----------------------------------------------------------------"
            echo
            break
            ;;
        *)
            error
            ;;
        esac
    done
fi

# 用户名
if [[ -z $naive_user ]]; then
    random=$(openssl rand -hex 8)
    while :; do
        echo
        echo -e "请输入 ${magenta}用户名${none} Input your username"
        read -p "$(echo -e "(默认: ${cyan}${random}$none):") " naive_user
        [ -z "$naive_user" ] && naive_user=$random
        echo
        echo
        echo -e "$yellow 你的用户名Username = $cyan$naive_user$none"
        echo "----------------------------------------------------------------"
        break
    done
fi

# 密码
if [[ -z $naive_pass ]]; then
    random=$(openssl rand -hex 8)
    while :; do
        echo
        echo -e "请输入 ${magenta}密码${none} Input your password"
        read -p "$(echo -e "(默认: ${cyan}${random}$none):") " naive_pass
        [ -z "$naive_pass" ] && naive_pass=$random
        echo
        echo
        echo -e "$yellow 你的密码Password = $cyan$naive_pass$none"
        echo "----------------------------------------------------------------"
        break
    done
fi

# 邮箱
if [[ -z "$tls_email" ]]; then
    randomuser=$(openssl rand -hex 8)
    while :; do
        echo
        echo -e "请输入证书邮箱${none} Input your email"
        read -p "$(echo -e "(默认: ${cyan}n${randomuser}@gmail.com$none):") " tls_email
        [ -z "$tls_email" ] && tls_email="n${randomuser}@gmail.com"
        echo
        echo
        echo -e "$yellow 你的邮箱 = $cyan$tls_email$none"
        echo "----------------------------------------------------------------"
        break
    done
fi

# 修改Caddyfile
echo
echo -e "$yellow修改Caddyfile$none"
echo "----------------------------------------------------------------"

# 写入新的配置
cat <<EOF > /etc/caddy/Caddyfile
# _naive_config_begin_
{
  order forward_proxy before file_server
  admin off
  email ${tls_email}
  acme_ca https://acme.zerossl.com/v2/DV90
}

:${naive_port}, ${naive_domain} {
  forward_proxy {
    basic_auth ${naive_user} ${naive_pass}
    hide_ip
    hide_via
    probe_resistance
  }
  
  root * /var/www/chtml
  file_server
}
# _naive_config_end_
EOF

# 启动NaïveProxy服务端(Caddy)
echo
echo -e "$yellow启动NaïveProxy服务端(Caddy)$none"
echo "----------------------------------------------------------------"
service caddy start

# 输出参数
echo
echo -e "${yellow}NaïveProxy配置参数${none}"
echo "----------------------------------------------------------------"
echo -e "域名Domain: ${naive_domain}"
echo -e "端口Port: ${naive_port}"
echo -e "用户名Username: ${naive_user}"
echo -e "密码Password: ${naive_pass}"

naive_url="naive+https://$(urlencode "$naive_user"):$(urlencode "$naive_pass")@${naive_domain}:${naive_port}?sni=${naive_domain}"
printf '%b%s%b\n' "$cyan" "$naive_url" "$none"
echo "以下两个二维码完全一样的内容"
qrencode -t UTF8 "$naive_url"
qrencode -t ANSI "$naive_url"

echo "---------- END -------------"
echo "以上节点信息保存在 ~/_naive_url_ 中"

# 链接包含凭据，创建和覆盖时均限制为仅当前用户可读写。
(umask 077; touch ~/_naive_url_) || exit 1
chmod 600 ~/_naive_url_ || exit 1
printf '%s\n' "$naive_url" > ~/_naive_url_ || exit 1
echo "以下两个二维码完全一样的内容" >> ~/_naive_url_
qrencode -t UTF8 "$naive_url" >> ~/_naive_url_
qrencode -t ANSI "$naive_url" >> ~/_naive_url_

echo
echo "----------------------------------------------------------------"
echo "END"
