# xraydeploy






一个面向 Linux（含 Alpine/OpenRC）的 Xray Core 部署与管理脚本。

## 功能

- 根据系统架构下载/更新 Xray Core
- 兼容 `systemd` 与 `OpenRC` 服务管理
- 目录约定：
	- 主目录：`/etc/xray`
	- 主配置：`/etc/xray/config.json`
	- 子配置：`/etc/xray/conf/*.json`
- 支持配置操作：
	1. 增加配置（SS / VLESS Encryption / VLESS Reality Vision）
	2. 修改配置项（基于 `jq` 路径）
	3. 删除配置
	4. 修改 DNS
	5. 重启内核
	6. 关闭内核
	7. 启动内核
	8. 指定 GEOIP 更新地址
	9. 更新 GEOIP/GEOSITE

## 使用方式

```bash
chmod +x ./xray-deploy.sh
sudo ./xray-deploy.sh
```

默认进入交互菜单。

### 命令行模式

```bash
sudo ./xray-deploy.sh install-core
sudo ./xray-deploy.sh add ss 8936 w8yXMskMJH00VzmukjN0pFIivjny+RyPOEJqhwDcYXw= 2022-blake3-aes-256-gcm
sudo ./xray-deploy.sh add vlessenc 33026 auto
sudo ./xray-deploy.sh change 33026 sni www.google.com
sudo ./xray-deploy.sh change 33026 decryption auto
sudo ./xray-deploy.sh del 33026
sudo ./xray-deploy.sh add-config
sudo ./xray-deploy.sh edit-config
sudo ./xray-deploy.sh delete-config
sudo ./xray-deploy.sh set-dns
sudo ./xray-deploy.sh set-geo-source
sudo ./xray-deploy.sh update-geo
sudo ./xray-deploy.sh start|stop|restart|status
```

## 说明

- 脚本会自动安装依赖：`curl`、`unzip`、`jq`（通过系统包管理器）
- 每次关键配置修改后会尝试进行 `xray run -test` 校验
- VLESS Encryption 支持自动调用 `xray vlessenc` 生成，也支持手动填入
- `change` 支持按 文件名 / inbound tag / 端口 进行模糊匹配
- `change` 常用字段：`sni/serverName`、`port`、`tag`、`listen`、`password`、`method`、`decryption`、`uuid/id`、`email`、`flow`、`network`、`security`、`dest`、`shortId`、`privateKey`、`xver`
- `del` 支持按 文件名 / inbound tag / 端口 进行模糊匹配并删除（校验失败自动回滚）
- GEO 更新源配置文件：`/etc/xray/geo_source.conf`
