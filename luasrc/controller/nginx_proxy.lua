module("luci.controller.nginx_proxy", package.seeall)

local http  = require "luci.http"
local disp  = require "luci.dispatcher"
local sys   = require "luci.sys"
local tmpl  = require "luci.template"
local fs    = require "nixio.fs"
local nixio = require "nixio"
local uci   = require "luci.model.uci".cursor()
local translate = require "luci.i18n".translate

local DATA_DIR = "/etc/nginx-proxy"

function index()
	entry({"admin", "services", "nginx_proxy"}, call("action_page"), translate("Nginx Reverse Proxy"), 62).leaf = true
end

local function slug(s)
	s = (s or ""):lower():gsub("[^a-z0-9_%-]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
	if s == "" then s = "site" end
	return s
end

local function apply_config()
	return sys.exec("/usr/sbin/nginx-proxy apply 2>&1") or ""
end

local function cert_options()
	local list = {}
	for f in fs.glob("/etc/ssl/acme/*.crt") do
		local key = f:gsub("%.crt$", ".key")
		if fs.access(key) then
			list[#list + 1] = { path = f, key = key, label = fs.basename(f):gsub("%.crt$", "") }
		end
	end
	for f in fs.glob(DATA_DIR .. "/certs/*.crt") do
		local key = f:gsub("%.crt$", ".key")
		if fs.access(key) then
			list[#list + 1] = { path = f, key = key, label = "uploaded: " .. fs.basename(f):gsub("%.crt$", "") }
		end
	end
	return list
end

local function cert_allowed(path)
	if path == "" then return true end
	for _, c in ipairs(cert_options()) do
		if c.path == path then return true end
	end
	return false
end

local function set_htpasswd(id, user, pw)
	local path = DATA_DIR .. "/htpasswd/" .. id
	if not user or user == "" or not pw or pw == "" then
		fs.remove(path)
		return true
	end
	if not user:match("^[A-Za-z0-9_.%-]+$") then
		return false, translate("Invalid user name")
	end
	local tmp = "/tmp/.nginx-proxy-pw"
	local f = nixio.open(tmp, "w", "600")
	if not f then return false, translate("Cannot write temp file") end
	f:write(pw .. "\n")
	f:close()
	local hash = sys.exec("openssl passwd -apr1 -in " .. tmp)
	fs.remove(tmp)
	hash = (hash or ""):gsub("%s+$", "")
	if hash == "" then return false, translate("openssl passwd failed") end
	local g = nixio.open(path, "w", "600")
	if not g then return false, translate("Cannot write password file") end
	g:write(user .. ":" .. hash .. "\n")
	g:close()
	return true
end

local function load_rules()
	local rules = {}
	uci:foreach("nginx_proxy", "proxy", function(s)
		rules[#rules + 1] = {
			id      = s[".name"],
			name    = s.name or s[".name"],
			domain  = s.domain or "",
			listen  = s.listen or "443",
			target  = s.target or "",
			ws      = s.websocket == "1",
			enabled = s.enabled ~= "0",
			auth    = (s.auth_user or "") ~= "" and fs.access(DATA_DIR .. "/htpasswd/" .. sid) ~= nil,
			auth_lost = (s.auth_user or "") ~= "" and fs.access(DATA_DIR .. "/htpasswd/" .. sid) == nil,
			cert    = s.cert or "",
			family  = s.ip_family or "both",
			extra   = (s.extra or "") ~= "",
			allow   = s.allow_wan == "1",
			redirect = s.redirect == "1",
		}
	end)
	table.sort(rules, function(a, b) return a.name < b.name end)
	return rules
end

-- 先提交 uci 再 apply：反过来的话 apply 渲染的还是旧配置（会慢一拍）
local function apply_and_return()
	uci:commit("nginx_proxy")
	return { out = apply_config(), err = "" }
end

local function handle_post()
	local action = http.formvalue("action")
	if not action then return nil end
	if http.formvalue("token") ~= disp.context.authtoken then
		return { out = "", err = translate("Invalid token, please reload the page.") }
	end

	if action == "delete" then
		local id = http.formvalue("id")
		if id then uci:delete("nginx_proxy", id); fs.remove(DATA_DIR .. "/htpasswd/" .. id) end
		return apply_and_return()
	end

	if action == "toggle" then
		local id = http.formvalue("id")
		if id and uci:get("nginx_proxy", id) then
			uci:set("nginx_proxy", id, "enabled", http.formvalue("value") == "1" and "1" or "0")
		end
		return apply_and_return()
	end

	if action == "upload" then
		local cname = (http.formvalue("cert_name") or ""):gsub("[^A-Za-z0-9_.%-]", "")
		local crt = http.formvalue("cert_pem") or ""
		local key = http.formvalue("key_pem") or ""
		if cname == "" or crt == "" or key == "" then
			return { out = "", err = translate("Name, certificate and private key are all required.") }
		end
		if not crt:match("BEGIN CERTIFICATE") or not key:match("PRIVATE KEY") then
			return { out = "", err = translate("That does not look like PEM certificate/key.") }
		end
		fs.mkdirr(DATA_DIR .. "/certs")
		local cf = DATA_DIR .. "/certs/" .. cname .. ".crt"
		local kf = DATA_DIR .. "/certs/" .. cname .. ".key"
		local a = nixio.open(cf, "w", "600"); a:write(crt); a:close()
		local b = nixio.open(kf, "w", "600"); b:write(key); b:close()
		local chk = sys.exec("openssl x509 -in " .. cf .. " -noout -subject 2>&1")
		if not chk:match("subject") then
			fs.remove(cf); fs.remove(kf)
			return { out = "", err = translate("Certificate did not parse: ") .. chk }
		end
		return { out = translate("Certificate uploaded: ") .. cname, err = "" }
	end

	if action == "save" then
		local id = http.formvalue("id")
		local name = (http.formvalue("name") or ""):gsub("^%s+", ""):gsub("%s+$", "")
		local target = (http.formvalue("target") or ""):gsub("%s", "")
		local listen = (http.formvalue("listen") or "443"):gsub("%s", "")
		local domain = (http.formvalue("domain") or ""):gsub("%s", "")
		local tgt = target:gsub("^https://", ""):gsub("^http://", "")
		if name == "" or tgt == "" or not tgt:match("^[%w%._%[%]:%-]+:%d+$") then
			return { out = "", err = translate("Name and target (host:port, http(s):// optional) are required.") }
		end
		if not listen:match("^%d+$") or tonumber(listen) < 1 or tonumber(listen) > 65535 then
			return { out = "", err = translate("Listen port must be a number.") }
		end
		if domain ~= "" and not domain:match("^[%w%.%*_%-]+$") then
			return { out = "", err = translate("Invalid domain name.") }
		end
		local family = http.formvalue("ip_family") or "both"
		if family ~= "both" and family ~= "ipv4" and family ~= "ipv6" then
			return { out = "", err = translate("Invalid IP family.") }
		end
		local extra = (http.formvalue("extra") or ""):gsub("\r\n", "\n")
		for line in extra:gmatch("[^\n]+") do
			line = line:gsub("^%s+", ""):gsub("%s+$", "")
			if line ~= "" then
				if line:find("[{}]") or not line:match(";$") then
					return { out = "", err = translate("Extra directives must be one per line and end with ';' (no braces).") }
				end
			end
		end
		local cert = http.formvalue("cert") or ""
		if not cert_allowed(cert) then
			return { out = "", err = translate("Unknown certificate.") }
		end
		local sec = (id ~= "") and id or ("proxy_" .. slug(name))
		uci:section("nginx_proxy", "proxy", sec)
		uci:set("nginx_proxy", sec, "name", name)
		uci:set("nginx_proxy", sec, "target", target)
		uci:set("nginx_proxy", sec, "listen", listen)
		uci:set("nginx_proxy", sec, "domain", domain)
		uci:delete("nginx_proxy", sec, "path")
		uci:set("nginx_proxy", sec, "enabled", http.formvalue("enabled") == "1" and "1" or "0")
		uci:set("nginx_proxy", sec, "websocket", http.formvalue("websocket") == "1" and "1" or "0")
		uci:set("nginx_proxy", sec, "allow_wan", http.formvalue("allow_wan") == "1" and "1" or "0")
		uci:set("nginx_proxy", sec, "ip_family", family)
		uci:set("nginx_proxy", sec, "redirect", http.formvalue("redirect") == "1" and "1" or "0")
		if extra ~= "" then
			uci:set("nginx_proxy", sec, "extra", extra)
		else
			uci:delete("nginx_proxy", sec, "extra")
		end

		if cert ~= "" then
			uci:set("nginx_proxy", sec, "cert", cert)
			uci:set("nginx_proxy", sec, "key", cert:gsub("%.crt$", ".key"))
		else
			uci:delete("nginx_proxy", sec, "cert")
			uci:delete("nginx_proxy", sec, "key")
		end

		local user = (http.formvalue("auth_user") or ""):gsub("%s", "")
		local pw = http.formvalue("auth_pass") or ""
		local ok, err = set_htpasswd(sec, user, pw)
		if not ok then return { out = "", err = err } end
		uci:set("nginx_proxy", sec, "auth_user", user)

		return apply_and_return()
	end
end

function action_page()
	local result = nil
	if http.getenv("REQUEST_METHOD") == "POST" then
		result = handle_post()
	end
	local edit = nil
	local eid = http.formvalue("edit")
	if eid then
		local all = uci:get_all("nginx_proxy", eid)
		if all then
			edit = {
				id = eid, name = all.name or eid, domain = all.domain or "",
				listen = all.listen or "443", target = all.target or "",
				ws = all.websocket == "1", enabled = all.enabled ~= "0",
				auth = all.auth_user or "", cert = all.cert or "",
				family = all.ip_family or "both", extra = all.extra or "",
				allow = all.allow_wan == "1",
				redirect = all.redirect == "1",
			}
		end
	end
	local conftext = nil
	local cid = http.formvalue("conf")
	if cid and cid:match("^[%w_%-]+$") and uci:get("nginx_proxy", cid) then
		conftext = sys.exec("/usr/sbin/nginx-proxy show " .. cid .. " 2>&1")
	end
	tmpl.render("nginx_proxy/main", {
		rules = load_rules(),
		certs = cert_options(),
		token = disp.context.authtoken,
		result = result,
		edit = edit,
		conftext = conftext,
		confid = cid,
	})
end
