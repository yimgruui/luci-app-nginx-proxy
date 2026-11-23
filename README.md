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
