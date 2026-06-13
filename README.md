# apps_nacos-skillhub

Nacos standalone Derby 离线 `.run` 一键安装包项目。

这个仓库的交付目标是：

- 本地执行 `bash build.sh --arch amd64|arm64|all` 生成离线 `.run` 安装包。
- 构建阶段按 `images/image.json` 拉取 `nacos/nacos-server:latest` 的指定平台镜像，保存进 payload。
- 离线现场执行 `.run install -y` 后，自动 `docker load/tag/push` 到内网镜像仓库，再通过 `kubectl apply` 安装 Nacos。
- `git push tag v*` 时，GitHub Actions 自动构建 `amd64` / `arm64` 两个离线包并发布到 GitHub Release。

> 当前安装形态对齐你给的 Docker 命令：`MODE=standalone`，并注入 `NACOS_AUTH_TOKEN`、`NACOS_AUTH_IDENTITY_KEY`、`NACOS_AUTH_IDENTITY_VALUE`，暴露 8080 / 8848 / 9848。

## 目录结构

```text
.
├── VERSION
├── build.sh
├── install.sh
├── images/
│   └── image.json
├── manifests/
│   └── nacos-standalone.yaml.tmpl
└── .github/workflows/
    └── offline-run-packages.yml
```

## 本地构建

构建机要求：Linux shell、Docker、Python 3、tar、sha256sum。

```bash
bash -n build.sh install.sh
python3 -m json.tool images/image.json >/dev/null

bash build.sh --arch amd64
bash build.sh --arch arm64
# 或者：
bash build.sh --arch all

ls -lh dist/
sha256sum -c dist/*.sha256
```

产物示例：

```text
dist/nacos-skillhub-installer-amd64.run
dist/nacos-skillhub-installer-amd64.run.sha256
dist/nacos-skillhub-installer-arm64.run
dist/nacos-skillhub-installer-arm64.run.sha256
```

## 离线现场安装

```bash
chmod +x nacos-skillhub-installer-amd64.run
sha256sum -c nacos-skillhub-installer-amd64.run.sha256

./nacos-skillhub-installer-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  --registry-user admin \
  --registry-pass '<registry-password>' \
  -n nacos-system \
  --auth-token '<at-least-32-chars-secret-token>' \
  --identity-key serverIdentity \
  --identity-value security \
  -y
```

如果目标内网仓库已经提前准备好了镜像，只跳过导入推送，但仍然渲染目标镜像地址：

```bash
./nacos-skillhub-installer-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  --skip-image-prepare \
  -n nacos-system \
  --auth-token '<at-least-32-chars-secret-token>' \
  -y
```

## NodePort 暴露

默认 Service 是 `ClusterIP`。需要现场节点端口时：

```bash
./nacos-skillhub-installer-amd64.run install \
  --registry sealos.hub:5000/kube4 \
  --service-type NodePort \
  --nodeport-console 30080 \
  --nodeport-client 30848 \
  --nodeport-grpc 30849 \
  --auth-token '<at-least-32-chars-secret-token>' \
  -n nacos-system \
  -y
```

## 状态和卸载

```bash
./nacos-skillhub-installer-amd64.run status -n nacos-system

./nacos-skillhub-installer-amd64.run uninstall -n nacos-system -y

# 危险：同时删除 PVC
./nacos-skillhub-installer-amd64.run uninstall -n nacos-system --delete-pvc -y
```

## GitHub Actions 发布

普通 push 到 `main` 会构建双架构 artifact。推送 tag 会额外创建 GitHub Release：

```bash
git tag v0.1.0
git push origin v0.1.0
```

Release 附件会包含：

- `nacos-skillhub-installer-amd64.run`
- `nacos-skillhub-installer-amd64.run.sha256`
- `nacos-skillhub-installer-arm64.run`
- `nacos-skillhub-installer-arm64.run.sha256`

## 镜像版本固定

默认按你的示例使用 `nacos/nacos-server:latest`。生产建议把 `images/image.json` 改成固定版本，例如：

```json
"pull": "nacos/nacos-server:<fixed-version>",
"tag": "sealos.hub:5000/kube4/nacos-server:<fixed-version>"
```

这样 Release 产物可追溯、可复现。
