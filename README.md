# luci-app-nginx-proxy

在现有 nginx 上做「域名 → 内网 host:port」的最小反向代理管理页。

- 只生成 `/etc/nginx/conf.d/proxy.d/*.conf`，入口是固定文件 `/etc/nginx/conf.d/50-proxy.conf`
- **不修改** `uci.conf` / `nginx.conf` / `luci.locations`，与 nginx-util、LuCI 主站完全解耦
- 保存时先 `nginx -t -c /etc/nginx/uci.conf` 再 reload；失败自动回滚到上一份可用配置，并把错误原文显示在页面上
- 证书：复用 `/etc/ssl/acme/*.crt`（自动续期），也可以页面上传 PEM 到 `/etc/nginx-proxy/certs/`
- 可选 basic auth（密码只存 apr1 哈希）、可选 WebSocket、可选「允许公网访问」——只放行该监听端口

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
	option enabled '1'
```

## CLI

```
nginx-proxy apply    # 渲染 + 测试 + reload（失败回滚）
nginx-proxy test     # 只跑 nginx -t
nginx-proxy render /tmp/x   # 只渲染到目录，不落盘
```

## Basic Auth 怎么配

每条规则独立开关，**不填用户名就是不开认证**：

1. 「服务 → Nginx 反向代理」新增/编辑规则；
2. 填「认证用户」和「认证密码」（密码只用于生成哈希，不会存明文）；
3. 保存并应用 → 控制器执行
   `openssl passwd -apr1` 生成 `user:$apr1$...`，写到
   `/etc/nginx-proxy/htpasswd/<section>`（0600），规则渲染成：

   ```
   auth_basic "luci";
   auth_basic_user_file /etc/nginx-proxy/htpasswd/proxy_luci;
   ```

4. 验证：

   ```sh
   curl -i http://192.168.11.1:8088/            # 401 + WWW-Authenticate
   curl -i -u admin:你的密码 http://192.168.11.1:8088/   # 200
   ```

注意：

- 认证是 **per-rule** 的，同一端口不能既开又不开；想让 LuCI 主站也带认证，等于把 80 也代理一层，不推荐（会把管理面绕一圈）。
- 建议：凡是勾了「允许公网访问」的规则都填用户名密码——这个勾选只做端口放行，不做任何访问控制。
- 改密码就是改这条规则再保存；清空用户名即关闭认证（哈希文件同时删除）。
- 忘记密码无法找回（只有 apr1 哈希），直接改规则重设即可。

## TLS

- 下拉框会列出 `/etc/ssl/acme/*.crt`（acme 续期后自动生效，无需重新保存规则）和上传的
  `/etc/nginx-proxy/certs/*.crt`；
- 也可以直接粘贴 PEM 证书 + 私钥上传，文件名即下拉框里的 `uploaded: <名字>`；
- 监听端口写 443 或任意端口都行，选了证书就渲染 `listen <port> ssl`。

## 公网访问

勾「允许公网访问」后，应用时会为该端口建 `firewall.npxy_<port>`（仅 tcp 放行），
删除规则或取消勾选会自动清掉对应 firewall 段。CGNAT 环境下仍需 IPv6 或内网穿透才能从公网到达。


## 页面行为

- 保存即应用：`uci commit` → 渲染 → `nginx -t` → reload，失败自动回滚；
- 列表里的「启用」是勾选框，勾/取消即时生效（不需要再点保存）；
- 每行「查看配置」直接显示这条规则渲染出来的 nginx 片段。
