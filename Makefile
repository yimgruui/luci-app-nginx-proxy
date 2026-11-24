include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-nginx-proxy
PKG_VERSION:=1.4.2
PKG_RELEASE:=1
PKG_LICENSE:=MIT
PKG_MAINTAINER:=yimgruui

LUCI_TITLE:=LuCI app: simple nginx reverse proxy rules
LUCI_DESCRIPTION:=Add "domain -> LAN host:port" reverse proxy rules on top of the existing nginx. \
Only /etc/nginx/conf.d/proxy.d/ is generated; the LuCI server configuration is never touched.
LUCI_DEPENDS:=+luci-compat +nginx-ssl +openssl-util
LUCI_PKGARCH:=all

define Package/luci-app-nginx-proxy/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	mkdir -p /etc/nginx-proxy/certs /etc/nginx-proxy/htpasswd /etc/nginx/conf.d/proxy.d
	chmod 700 /etc/nginx-proxy /etc/nginx-proxy/certs /etc/nginx-proxy/htpasswd
	rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null
}
exit 0
endef

define Package/luci-app-nginx-proxy/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/* 2>/dev/null
}
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
