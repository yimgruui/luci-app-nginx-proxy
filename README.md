# luci-app-nginx-proxy

在现有 nginx 上做「域名 → 内网 host:port」的最小反向代理管理页。

- 只生成 `/etc/nginx/conf.d/proxy.d/*.conf`，入口是固定文件 `/etc/nginx/conf.d/50-proxy.conf`
- **不修改** `uci.conf` / `nginx.conf` / `luci.locations`，与 nginx-util、LuCI 主站完全解耦
- 保存时先 `nginx -t -c /etc/nginx/uci.conf` 再 reload；失败自动回滚到上一份可用配置，并把错误原文显示在页面上
- 证书：复用 `/etc/ssl/acme/*.crt`（自动续期），也可以页面上传 PEM 到 `/etc/nginx-proxy/certs/`
- 目标地址支持 `host:port`、`http://host:port`、`https://host:port`（反代到上游的 https 时自动 `proxy_ssl_server_name on`）
- 可选 basic auth（密码只存 apr1 哈希）、可选 WebSocket、可选「允许公网访问」——只放行该监听端口
- 用证书的规则自动启用 TLSv1.2/1.3 并加 HSTS；可选「HTTP 301 跳转到 HTTPS」

## 菜单

服务 → Nginx 反向代理

## 配置

`/etc/config/nginx_proxy`，每条规则一个 `config proxy` 段：

```
config proxy 'proxy_luci'
	option name 'luci'
	option domain 'router.example.com'
	option listen '443'
	option target '192.168.11.1:80'
	option cert '/etc/ssl/acme/example.com.crt'
	option key '/etc/ssl/acme/example.com.key'
	option websocket '1'
	option auth_user 'admin'
	option allow_wan '1'
	option ip_family 'both'      # both / ipv4 / ipv6
	option redirect '1'          # 监听 80 并 301 到本规则的 https 端口（需证书 + 域名）
	option enabled '1'
	option extra 'proxy_cookie_path  /  "/; Secure";'   # 可选，多行用 \n 分隔
```

`ip_family`：

| 值 | 监听 | 防火墙 |
|---|---|---|
| `both`（默认） | `listen PORT` + `listen [::]:PORT` | IPv4 + IPv6 都放行 |
| `ipv4` | 只 `listen PORT` | 只放行 IPv4 |
| `ipv6` | 只 `listen [::]:PORT ipv6only=on` | 只放行 IPv6 |

`redirect`：再渲染一个 `listen 80` 的 server（`server_name` 用规则域名），
`return 301 https://$host[:端口]$request_uri`。监听 443 时不带端口，其他端口会带上；
需要证书和域名（空域名会变成 catch-all，不允许）。

目标地址的 schema：不写默认 `http`；写 `https://` 时渲染 `proxy_pass https://...` 并带
`proxy_ssl_server_name on` / `proxy_ssl_name <host>`，自签上游也能连（不校验证书链）。

`extra` 是逐行插入 `location /` 里的 nginx 指令（每行必须以 `;` 结尾、不能有花括号），
适合 `proxy_cookie_path`、`proxy_buffering off`、`proxy_read_timeout` 这类微调；写错会被 `nginx -t` 拦下并回滚。

## CLI

```
nginx-proxy apply    # 渲染 + 测试 + reload（失败回滚）
nginx-proxy test     # 只跑 nginx -t
nginx-proxy render /tmp/x   # 只渲染到目录，不落盘
```

## 认证用户（Basic Auth）

认证用户是**全局共享**的，不再每条规则各填一套：

1. 「服务 → Nginx 反向代理」→「认证用户」卡片里添加用户和密码（可以加多个，适合家里几个人各自用）；
2. 规则表单里勾「需要认证」即启用，取消勾选即关闭；
3. 密码只以 `openssl passwd -apr1` 哈希形式存进 `/etc/config/nginx_proxy`（uci），
   **升级固件不会丢**；每次 apply 时重建 `/etc/nginx-proxy/htpasswd/users`，规则渲染成：

   ```
   auth_basic "luci";
   auth_basic_user_file /etc/nginx-proxy/htpasswd/users;
   ```

4. 验证：

   ```sh
   curl -i http://192.168.11.1:8088/                   # 401 + WWW-Authenticate
   curl -i -u alice:她的密码 http://192.168.11.1:8088/  # 200
   ```

注意：

- **认证用户列表为空时，勾了「需要认证」的规则会对所有人 401**（宁可拒绝，也不裸奔），先加用户再勾选；
- 建议：凡是勾了「允许公网访问」的规则都开认证——这个勾选只做端口放行，不做访问控制；
- 改密码 = 在「认证用户」里同名再添加一次（覆盖哈希）；
- 忘记密码无法找回（只有 apr1 哈希），删除该用户重加即可；
- 哈希存 uci，`/etc/config/nginx_proxy` 本来就在 sysupgrade 保留范围内，所以重刷固件后用户还在。

## 80 → 443 跳转

镜像默认由 nginx 的静态 server 块完成，不需要建任何反代规则：

```
# /etc/nginx/conf.d/luci-http.conf
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 301 https://$host$request_uri;
}
```

想改回 80 明文的，把 `return 301 ...` 换成 `include /etc/nginx/conf.d/luci.locations;`。
规则表单里的「HTTP 301 to HTTPS」是另一件事：它把 `http://该域名` 跳到**这条规则自己的 https 端口**
（比如 10032），只在需要 `http://域名` 直达反代端口时才勾。

## TLS

- 下拉框会列出 `/etc/ssl/acme/*.crt`（acme 续期后自动生效，无需重新保存规则）和上传的
  `/etc/nginx-proxy/certs/*.crt`；
- 也可以直接粘贴 PEM 证书 + 私钥上传，文件名即下拉框里的 `uploaded: <名字>`；
- 监听端口写 443 或任意端口都行，选了证书就渲染 `listen <port> ssl`。

## 公网访问

勾「允许公网访问」后，应用时按协议族合并成**最多两条**防火墙规则（`npxy_v4` / `npxy_v6`，仅 tcp），
端口写进 nft 集合（`meta nfproto ipv4 tcp dport { 8080, 8443 } accept`），不再一个端口一条规则；
取消勾选或删规则会自动把端口从集合里移除，集合空了就删掉该 firewall 段。
CGNAT 环境下仍需 IPv6 或内网穿透才能从公网到达。


## 页面行为

- 保存即应用：`uci commit` → 渲染 → `nginx -t` → reload，失败自动回滚；
- 列表里的「启用」是勾选框，勾/取消即时生效（不需要再点保存）；
- 每行「查看配置」直接显示这条规则渲染出来的 nginx 片段；
- 表格里的协议族（IPv4 / IPv6 / v4+v6）与 TLS 用小标签显示，避免占一列长文本。
