# luci-app-nginx-proxy

在现有 nginx 上做「域名 → 内网 host:port」的最小反向代理管理页。没有数据库、没有独立守护进程，
保存即生成配置、测试、reload，失败自动回滚。

```
浏览器 ──https──▶ nginx (本机 443/LuCI)          ← nginx-util / uci.conf，本插件不碰
浏览器 ──https──▶ nginx (规则端口 10032) ──▶ 192.168.11.x:port
```

## 目录

- [特性](#特性)
- [兼容性](#兼容性)
- [安装](#安装)
- [快速开始](#快速开始)
- [规则字段](#规则字段)
- [配置示例](#配置示例)
- [地址族（IPv4 / IPv6）](#地址族ipv4--ipv6)
- [目标地址的协议](#目标地址的协议)
- [证书与 TLS](#证书与-tls)
- [认证用户（Basic Auth）](#认证用户basic-auth)
- [HTTP 301 跳转](#http-301-跳转)
- [公网访问](#公网访问)
- [自定义指令 extra](#自定义指令-extra)
- [命令行](#命令行)
- [安全建议](#安全建议)
- [故障排查](#故障排查)
- [许可](#许可)

## 特性

- 只生成 `/etc/nginx/conf.d/proxy.d/*.conf`，入口是固定文件 `/etc/nginx/conf.d/50-proxy.conf`
- **不修改** `uci.conf` / `nginx.conf` / `luci.locations`，与 nginx-util、LuCI 主站完全解耦
- 保存时先 `nginx -t -c /etc/nginx/uci.conf` 再 reload；失败自动回滚到上一份可用配置，错误原文显示在页面上
- 证书：复用 `/etc/ssl/acme/*.crt`（acme 续期后自动生效），也可以页面上传 PEM
- 目标地址支持 `host:port`、`http://host:port`、`https://host:port`
- 可选 basic auth（apr1 哈希存 uci）、WebSocket、允许公网访问、HTTP 301
- 用证书的规则自动 TLSv1.2/1.3 + HSTS
- 一个协议族只留一条防火墙规则，端口进 nft 集合（不是一端口一条）

## 兼容性

| 项目 | 说明 |
|---|---|
| OpenWrt | 23.05 及以上（nginx-util 的 `uci.conf` 布局） |
| ImmortalWrt | 24.10 / 25.12 实测 |
| 包管理 | opkg（23.05/24.10）与 apk（25.12）都可安装 |
| nginx | 需要 `nginx-ssl`（或任何提供 `nginx` 的变体）与 `nginx-util` |
| LuCI | 需要 `luci-compat`（Lua 控制器/模板运行时） |

不依赖 `uhttpd`，也不依赖 LuCI 的 JS 前端（纯 Lua 控制器 + 模板），因此在 nginx 替换 uhttpd 的镜像里同样工作。

## 安装

依赖：

```
luci-compat  nginx-ssl  openssl-util
```

把 `luci-app-nginx-proxy` 目录放进 OpenWrt 源码的 `package/`（或 feed），然后：

```sh
make package/luci-app-nginx-proxy/compile V=s
```

把生成的 `luci-app-nginx-proxy_*.ipk`（25.12 为 `.apk`）传到路由器安装：

```sh
opkg install /tmp/luci-app-nginx-proxy_*.ipk     # 23.05 / 24.10
apk add --allow-untrusted /tmp/luci-app-nginx-proxy-*.apk   # 25.12
```

安装后刷新 LuCI（`/tmp/luci-indexcache*` 会在 postinst 里清掉），菜单在 **服务 → Nginx 反向代理**。

> 如果你的镜像把 LuCI 跑在 uhttpd 上，这个插件照样能用；它只往 nginx 的 `conf.d` 里写文件，
> 前提是 nginx 本身在跑且 `nginx -t -c /etc/nginx/uci.conf` 能通过。

## 快速开始

1. 打开 **服务 → Nginx 反向代理**；
2. 「新增规则」填：名称 `nas`、监听端口 `8443`、目标 `192.168.11.10:5000`；
3. 要 https 就选一张证书（没有就先在 **系统 → ACME 证书** 申请，或在页面底部上传）；
4. 点「保存并应用」，页面会显示 `nginx -t` 的结果；成功即生效。

访问 `https://<路由器IP>:8443/`，或把域名解析到路由器后访问 `https://nas.example.com:8443/`。

## 规则字段

| 字段 | 说明 |
|---|---|
| 名称 | 规则标识，也用作 uci 段名（`proxy_<名称>`）与生成的文件名 |
| 域名 | `server_name`；留空表示接受任意 Host（仅建议内网使用） |
| 监听端口 | nginx `listen` 的端口，任意空闲端口；443 会和 LuCI 抢，除非换证书/域名 |
| 地址族 | `both` / `ipv4` / `ipv6`，同时决定监听地址与防火墙放行族 |
| 目标地址 | `host:port`、`http://host:port`、`https://host:port` |
| 证书 | 不选 = 明文 HTTP；选了就 `listen ... ssl` 并启用 TLS1.2/1.3 + HSTS |
| WebSocket | 加 `Upgrade`/`Connection` 头与 `proxy_read_timeout 1h` |
| 需要认证 | 用全局认证用户表（见下）做 basic auth |
| 允许公网访问 | 只做防火墙端口放行，不做访问控制 |
| HTTP 301 to HTTPS | 额外渲染一个 80 端口的跳转 server（需要证书 + 域名） |
| Extra directives | 逐行插入 `location /` 的指令，必须以 `;` 结尾、不能有 `{}` |
| 启用 | 列表里勾选框即时生效 |

## 配置示例

`/etc/config/nginx_proxy`：

```
config proxy 'proxy_nas'
	option name 'nas'
	option domain 'nas.example.com'
	option listen '8443'
	option target 'https://192.168.11.10:5000'
	option cert 'example.com'
	option auth '1'
	option websocket '1'
	option allow_wan '1'
	option ip_family 'both'
	option redirect '1'
	option extra 'proxy_cookie_path  /  "/; Secure";'
	option enabled '1'

config user 'user_alice'
	option username 'alice'
	option hash '$apr1$xxxxxxxx$yyyyyyyyyyyyyyyyyyyyyy'
```

`cert` 存的是证书名：`/etc/ssl/acme/<名字>.crt` 或 `/etc/nginx-proxy/certs/<名字>.crt`（同名 `.key`）。
`auth '1'` 表示引用全局认证用户表；用户存在 `config user` 段里，重刷固件不丢。

生成结果：

```
# /etc/nginx/conf.d/proxy.d/proxy_nas.conf
server {
	listen 8443 ssl;
	listen [::]:8443 ssl;
	server_name nas.example.com;
	ssl_certificate /etc/ssl/acme/example.com.crt;
	ssl_certificate_key /etc/ssl/acme/example.com.key;
	ssl_protocols TLSv1.2 TLSv1.3;
	add_header Strict-Transport-Security "max-age=31536000" always;

	auth_basic "nas";
	auth_basic_user_file /etc/nginx-proxy/htpasswd/users;

	location / {
		proxy_pass https://192.168.11.10:5000;
		proxy_ssl_server_name on;
		proxy_ssl_name 192.168.11.10;
		proxy_http_version 1.1;
		proxy_set_header Host $host;
		proxy_set_header X-Real-IP $remote_addr;
		proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
		proxy_set_header X-Forwarded-Proto $scheme;
		proxy_set_header Upgrade $http_upgrade;
		proxy_set_header Connection $connection_upgrade;
		proxy_read_timeout 1h;
		proxy_cookie_path  /  "/; Secure";
	}
}
```

## 地址族（IPv4 / IPv6）

| 值 | 监听 | 防火墙 |
|---|---|---|
| `both`（默认） | `listen PORT` + `listen [::]:PORT` | IPv4 + IPv6 都放行 |
| `ipv4` | 只 `listen PORT` | 只放行 IPv4 |
| `ipv6` | 只 `listen [::]:PORT ipv6only=on` | 只放行 IPv6 |

家里只有 IPv6 公网（CGNAT）时选 `ipv6` 即可；`both` 在部分内核上会因 `bindv6only=0` 出现
「IPv4 端口被 IPv6 监听占用」的错觉，实际是同一 socket，属正常。

## 目标地址的协议

- `192.168.11.10:8080` / `http://192.168.11.10:8080` → `proxy_pass http://...`
- `https://192.168.11.10:8443` → `proxy_pass https://...`，并自动加
  `proxy_ssl_server_name on` + `proxy_ssl_name <主机名>`（SNI 正常，上游自签也能连）

插件**不校验上游证书链**（内网自签很常见）；要严格校验请用 `extra` 加
`proxy_ssl_verify on;` 与 `proxy_ssl_trusted_certificate ...;`。

## 证书与 TLS

- 下拉框列出 `/etc/ssl/acme/*.crt`（**acme 续期后自动生效**，不用重新保存规则）和
  `/etc/nginx-proxy/certs/*.crt`（页面上传）；
- 上传时可粘贴 PEM 证书 + 私钥，文件名即下拉框里的 `uploaded: <名字>`；
- 选了证书的规则：`ssl_protocols TLSv1.2 TLSv1.3` + `Strict-Transport-Security`；
- 证书文件权限 0600，备份/升级会带到新系统（`/etc/nginx/certs` 与 `/etc/nginx-proxy` 在保留清单里）。

## 认证用户（Basic Auth）

认证用户是**全局共享**的，不是每条规则一套：

1. 「认证用户」卡片里添加用户名 + 密码（可加多个）；
2. 规则表单勾「需要认证」即启用，取消勾选即关闭；
3. 密码只以 `openssl passwd -apr1` 哈希存进 `/etc/config/nginx_proxy`（uci），
   **升级固件不会丢**；每次 apply 时重建 `/etc/nginx-proxy/htpasswd/users`。

验证：

```sh
curl -i http://192.168.11.1:8088/                   # 401 + WWW-Authenticate
curl -i -u alice:密码 http://192.168.11.1:8088/      # 200
```

注意：

- **用户表为空时，勾了「需要认证」的规则对所有人 401**（fail-closed），先加用户再勾选；
- 勾了「允许公网访问」的规则强烈建议同时开认证——那只做端口放行，不做访问控制；
- 改密码 = 同名再添加一次（覆盖哈希）；忘记密码只能删了重加（只有 apr1 哈希）；
- 认证失败日志在 `logread | grep nginx` 或 `/var/log/nginx/error.log`。

## HTTP 301 跳转

有两件事，别混：

1. **全局 80 → 443**：由镜像里的 `/etc/nginx/conf.d/luci-http.conf` 完成，**不需要建任何规则**：

   ```nginx
   server {
       listen 80 default_server;
       listen [::]:80 default_server;
       server_name _;
       return 301 https://$host$request_uri;
   }
   ```

   想改回 80 明文访问 LuCI，把 `return 301 ...` 换成 `include /etc/nginx/conf.d/luci.locations;`。

2. **规则级「HTTP 301 to HTTPS」**：把 `http://该域名` 跳到**这条规则自己的 https 端口**
   （例如 10032），需要证书 + 域名；监听 443 时跳转不带端口。

## 公网访问

勾「允许公网访问」后，apply 时按协议族合并成最多两条防火墙规则（`npxy_v4` / `npxy_v6`，仅 tcp）：

```
meta nfproto ipv4 tcp dport { 8443, 10032 } accept
```

取消勾选或删规则会把端口从集合里移除，集合空了就删掉整条规则。
CGNAT（WAN 是 `100.64/10`）环境下，公网只能走 IPv6 或内网穿透；IPv6 需要
AAAA 指向**路由器自己的地址**（不是某台客户端）。

## 自定义指令 extra

逐行插入 `location /` 内，每行必须以 `;` 结尾、不能含 `{}`。常见用法：

```nginx
proxy_cookie_path  /  "/; Secure";
proxy_buffering off;
proxy_read_timeout 300s;
client_max_body_size 0;
```

写错会被 `nginx -t` 拦下并整份回滚，不会留下半坏配置。

## 命令行

```sh
nginx-proxy apply        # 渲染 + nginx -t + reload（失败回滚）
nginx-proxy test         # 只跑 nginx -t
nginx-proxy render /tmp/x  # 只渲染到目录，不落盘
nginx-proxy show <段名>   # 打印这条规则渲染出的 server 块（页面「查看配置」用的就是它）
```

## 安全建议

- 公网暴露的规则一律开 basic auth；只靠端口不可猜是不够的；
- 不要把 LuCI 自己（`192.168.11.1:80`）直接反代到公网而不加认证；
- 只放行真正需要的端口，`允许公网访问` 一次只放行该监听端口；
- IPv6 场景下确认 AAAA 记录指向路由器（`ip -6 addr show br-lan`），否则流量到不了；
- 定期看 `logread | grep -i nginx`，401 暴增通常是被扫。

## 故障排查

| 现象 | 检查 |
|---|---|
| 保存后提示失败 | 页面会显示 `nginx -t` 原文；常见是端口冲突、证书路径、`extra` 语法 |
| 保存后浏览器「连接失败」 | 旧版本回滚用 restart 会掐断请求；1.5.2 起改为 reload，已修复 |
| `duplicate listen options for [::]:80` | 301 跳转块与 `luci-http.conf` 的 `default_server` 冲突；升级到 1.5.2+ |
| `server_names_hash_bucket_size` 报错 | `50-proxy.conf` 已设 128；域名特别多时可在 `extra` 之外调大 |
| 外网访问不通 | 看 `nft list ruleset \| grep npxy`；确认防火墙已 reload、AAAA/A 记录指向路由器 |
| 页面 401 但不是自己设的 | 规则勾了认证且用户表为空（fail-closed）；先加认证用户 |
| 规则生效但证书不对 | 证书名与文件不匹配，或 acme 证书尚未续期；看 `/etc/ssl/acme/` |

回滚目录：`/etc/nginx-proxy/last-good`；备份与差异在页面上可直接查看。

## 许可

MIT。见 [LICENSE](LICENSE)。
