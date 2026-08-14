# monitorerp-deploy 命令速查

Server: monitor-server3 (101.132.20.133), repo at `~/src/monitorerp-deploy`.

## 连接到服务器

```bash
ssh root@101.132.20.133
```

## 推送镜像到服务器（Windows 本地执行）

```bash
# PowerShell
.\ship-images.ps1 -Server root@101.132.20.133 -RemoteDir /root/images                        # 仅基础设施镜像
.\ship-kb-images.ps1 -Server root@101.132.20.133 -RemoteDir /root/images -Tag v1.2.3         # KB 应用镜像 + 部署 KB 栈
.\ship-keycloak-images.ps1 -Server root@101.132.20.133 -RemoteDir /root/images               # Keycloak 镜像 + 部署 Keycloak 栈
```

## 启动 / 停止 / 查看全部服务（服务器上执行）

```bash
cd ~/src/monitorerp-deploy
./manage.sh up      # 启动 Postgres + RAGFlow + KB + nginx（默认）
./manage.sh down    # 全部停止
./manage.sh status  # 查看各栈状态
./manage.sh logs    # 跟随查看所有日志
```

## Postgres 首次初始化（服务器上执行）

```bash
cd ~/src/monitorerp-deploy && ./postgres/bootstrap.sh
```

生成随机密码写入 `postgres/.env`（gitignored），随后启动容器；`.env` 已存在时跳过。

## Keycloak 首次初始化（服务器上执行）

```bash
cd ~/src/monitorerp-deploy && ./keycloak/bootstrap.sh
```

生成随机 admin 密码写入 `keycloak/.env`（gitignored），随后启动容器；`.env` 已存在时跳过。
控制台：http://127.0.0.1:8081（admin / 密码见 `keycloak/.env`）。注意 `KC_BOOTSTRAP_ADMIN_*` 仅在首次启动时生效，之后改 `.env` 不会改 admin 密码。

## KB 首次初始化（服务器上执行，交互式）

```bash
cd ~/src/monitorerp-deploy && ./kb/bootstrap.sh
```

## nginx 配置更新后强制重建（服务器上执行）

```bash
cd ~/src/monitorerp-deploy/server-nginx && docker compose up -d --force-recreate
```

## KB 域名证书签发（一次性，服务器上执行）

两步走是有意的：443 块引用的证书文件不存在时 nginx 拒绝启动，所以先把 80 块部署上去完成签发，再补 443 块。

1. 在腾讯云 DNS 添加 A 记录 `kb.ai.monitorsystem.cn` → 服务器 IP（等生效）。
2. 确认 `server-nginx/global.conf` 已包含 `kb.ai.monitorsystem.cn` 的 80 端口块（ACME challenge 路径），`git pull` 后强制重建 nginx（上面的命令）。
3. 签发证书：

```bash
certbot certonly --webroot -w /var/www/letsencrypt -d kb.ai.monitorsystem.cn
```

4. 让 Claude 把 443 反向代理块（`https://kb.ai.monitorsystem.cn` → `http://127.0.0.1:4800`）加进 `global.conf`，提交后服务器 `git pull` + 强制重建。

## 证书续期钩子（服务器上执行）

```bash
sudo cp server-nginx/nginx-reload-hook.sh /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh
```

certbot 续期成功后自动执行钩子，reload nginx 使新证书生效。服务器重建后需重新安装。
