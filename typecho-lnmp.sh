#!/bin/bash
# Typecho LNMP 一键安装脚本 (Ubuntu 22.04/24.04)
# 用法: sudo bash typecho-lnmp.sh
set -e

if [ "$EUID" -ne 0 ]; then echo "请用 sudo 运行"; exit 1; fi

echo "=== 1/7 系统更新 ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq

echo "=== 2/7 安装 nginx + MySQL + PHP ==="
apt-get install -y -qq nginx mysql-server \
  php-fpm php-mysql php-mbstring php-gd php-curl php-xml php-zip php-bcmath php-intl php-opcache \
  unzip curl

PHP_VER=$(php -v | head -1 | grep -oP '\d+\.\d+' | head -1)
echo "PHP 版本: $PHP_VER"

echo "=== 3/7 配置 MySQL ==="
systemctl enable --now mysql
DB_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
mysql <<MYSQL_EOF
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${DB_PASS}';
CREATE DATABASE IF NOT EXISTS typecho CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS 'typecho'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON typecho.* TO 'typecho'@'localhost';
FLUSH PRIVILEGES;
MYSQL_EOF
echo "$DB_PASS" > /root/.mysql_typecho_pass
chmod 600 /root/.mysql_typecho_pass

echo "=== 4/7 下载安装 Typecho ==="
mkdir -p /var/www/typecho
cd /tmp
TYPECHO_URL=$(curl -fsSL https://api.github.com/repos/typecho/typecho/releases/latest | grep -oP '"browser_download_url":\s*"\K[^"]+\.tar\.gz' | head -1)
if [ -z "$TYPECHO_URL" ]; then echo "无法获取 Typecho 下载地址"; exit 1; fi
curl -fsSL -o typecho.tar.gz "$TYPECHO_URL"
tar xzf typecho.tar.gz -C /var/www/typecho --strip-components=1
chown -R www-data:www-data /var/www/typecho
chmod -R 755 /var/www/typecho

echo "=== 5/7 配置 nginx ==="
cat > /etc/nginx/sites-available/typecho <<'NGINX_EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root /var/www/typecho;
    index index.html index.php;

    location / {
        if (-f $request_filename/index.html){ rewrite (.*) $1/index.html break; }
        if (-f $request_filename/index.php){ rewrite (.*) $1/index.php; }
        if (!-f $request_filename){ rewrite (.*) /index.php; }
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php-FPM-SOCK;
    }

    location ~ /\.ht { deny all; }
    location = /config.inc.php { deny all; }
}
NGINX_EOF
sed -i "s/php-FPM-SOCK/php${PHP_VER}-fpm.sock/" /etc/nginx/sites-available/typecho
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/typecho /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

echo "=== 6/7 PHP 调优 ==="
PHP_INI="/etc/php/${PHP_VER}/fpm/php.ini"
sed -i 's/^upload_max_filesize.*/upload_max_filesize = 20M/' $PHP_INI
sed -i 's/^post_max_size.*/post_max_size = 20M/' $PHP_INI
sed -i 's/^memory_limit.*/memory_limit = 256M/' $PHP_INI
systemctl restart php${PHP_VER}-fpm
systemctl enable nginx php${PHP_VER}-fpm mysql

echo "=== 7/7 防火墙 ==="
ufw --force enable 2>/dev/null || true
ufw allow 22/tcp 2>/dev/null || true
ufw allow 80/tcp 2>/dev/null || true
ufw allow 443/tcp 2>/dev/null || true

# Oracle Cloud 自带 iptables，放行 web 端口
iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true
iptables -I INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || true
netfilter-persistent save 2>/dev/null || true

echo ""
echo "=============================================="
echo " 安装完成！"
echo " 数据库名: typecho"
echo " 数据库用户: typecho"
echo " 数据库密码: $DB_PASS"
echo " (密码已保存到 /root/.mysql_typecho_pass)"
echo ""
echo " 下一步: 浏览器打开 http://服务器IP/"
echo " 按 Typecho 安装向导填写以上数据库信息即可"
echo "=============================================="
