# monitorerp-deploy 命令速查

Server: monitor-server3 (101.132.20.133), repo at `~/src/monitorerp-deploy`.

## 连接到服务器

```bash
ssh root@101.132.20.133
```

## 推送镜像到服务器（Windows 本地执行）

```powershell
.\ship-images.ps1 -Server root@101.132.20.133 -RemoteDir /root/images
```

## 启动 / 停止 / 查看全部服务（服务器上执行）

```bash
cd ~/src/monitorerp-deploy
./manage.sh up      # 启动 Postgres + RAGFlow + nginx（默认）
./manage.sh down    # 全部停止
./manage.sh status  # 查看各栈状态
./manage.sh logs    # 跟随查看所有日志
```

## nginx 配置更新后强制重建（服务器上执行）

```bash
cd ~/src/monitorerp-deploy/server-nginx && docker compose up -d --force-recreate
```

## 证书续期钩子（服务器上执行）

```bash
sudo cp server-nginx/nginx-reload-hook.sh /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/nginx-reload.sh
```

certbot 续期成功后自动执行钩子，reload nginx 使新证书生效。服务器重建后需重新安装。
