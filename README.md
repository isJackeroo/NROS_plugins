# C2000Max 插件脚本说明

本仓库的核心脚本是`plugin.sh` 指的是插件安装主脚本，这里默认就是介绍这个文件。

它是一个面向 NRadio / NROS / OpenWrt AppCenter 的插件安装与兼容修复脚本，主要目标不是单纯安装软件包，而是把插件正确接入 AppCenter，并处理 OEM 固件上常见的页面嵌入、路由注册、模板兼容和 LuCI 刷新问题。

## 脚本能做什么

当前脚本主要支持 3 类插件接入：

- `ttyd`
- `OpenClash`
- `KMS`（`vlmcsd` / `luci-app-vlmcsd`）

除了安装插件本体，它还会做这些事情：

- 自动检查并切换 `opkg` 软件源到清华镜像默认配置
- 下载所需 `ipk` 包
- 安装或重装插件
- 写入或修正 UCI 配置
- 在 `/etc/config/appcenter` 中注册插件信息
- 修改 AppCenter 前端模板，使插件可以在弹窗 iframe 中正常打开
- 清理 LuCI / rpcd / infocd / appcenter 缓存并刷新页面索引
- 对 OpenClash 做额外兼容修复

## 适用场景

这个脚本适合下面这类环境：

- 基于 OpenWrt 的 NRadio / NROS 固件
- 设备里已经有 AppCenter
- 存在 `/etc/config/appcenter`
- 存在 `/usr/lib/lua/luci/view/nradio_appcenter/appcenter.htm`
- 需要把第三方插件以“AppCenter 内嵌页面”的方式接进去

如果只是普通 OpenWrt 环境，没有 AppCenter，这个脚本就不是最佳选择。

## 依赖与前提

运行安装类命令前，脚本会要求：

- 必须使用 `root`
- 目标系统存在 `opkg`、`uci`、LuCI、init 脚本
- 系统可联网下载软件包

其中：

- `ttyd` 从当前 `opkg feeds` 下载
- `KMS` 从指定 GitHub / Raw 地址下载
- `OpenClash` 从脚本内置镜像下载

## 支持的运行方式

### 1. 一条命令行方式
> 需要确保你的C2000 Max可以正常访问GitHub，否则拉取不了代码
```sh
curl -L https://raw.githubusercontent.com/isJackeroo/NROS_plugins/refs/heads/main/plugins_0330.sh \
  -o plugins_0330.sh && chmod +x plugins_0330.sh && ./plugins_0330.sh
```

### 2. 交互菜单模式

直接执行：

```sh
sh plugins_0330.sh
```

会显示菜单：

```text
1. 安装 ttyd
2. 安装 OpenClash
3. 安装 KMS
4. 生成 appcenter_modified_v1.htm
```

### 3. 命令行模式

安装 `ttyd`：

```sh
sh plugins_0330.sh ttyd
```

安装 `OpenClash`：

```sh
sh plugins_0330.sh openclash
```

安装 `KMS`：

```sh
sh plugins_0330.sh kms
```

仅生成修改后的 AppCenter 模板，不改系统：

```sh
sh plugins_0330.sh build-appcenter
```

## 三个插件分别做了什么

### 1. ttyd

`ttyd` 部分不只是安装 `ttyd` 和 `luci-app-ttyd`，还额外做了两件关键事情：

- 自动补齐 `/etc/config/ttyd`
- 重写 LuCI 页面，生成适合 AppCenter 内嵌显示的终端页和配置概览页

安装完成后，脚本会把它注册到：

```text
admin/services/ttyd/ttyd
```

这样 AppCenter 弹窗里打开的是专门适配过的终端页面。

### 2. OpenClash

OpenClash 是这个脚本里处理最复杂的部分，主要包含：

- 自动获取最新版安装包
- 自动安装所需依赖
- 重新打包 `ipk`，去掉对 `luci-compat` 的依赖
- 修正 LuCI 兼容问题
- 增加 AppCenter 嵌入页面适配
- 写入别名控制器和切换页
- 可选下载安装 smart core
- 备份关键修复文件

安装后注册路由：

```text
admin/services/openclash
```

它在 AppCenter 中还带有内部标签页切换能力，比如运行状态、插件设置、配置订阅、日志等。

### 3. KMS

KMS 部分安装的是：

- `vlmcsd`
- `luci-app-vlmcsd`

安装完成后会启用并启动服务，并注册到：

```text
admin/services/vlmcsd
```

这部分逻辑相对直接，重点是让 KMS 页面能正常出现在 AppCenter 中。

## AppCenter 相关改动

这个脚本的核心价值之一，是对 AppCenter 模板做兼容增强。

它会修改目标模板：

`/usr/lib/lua/luci/view/nradio_appcenter/appcenter.htm`

主要增强包括：

- 扩大弹窗宽度和 iframe 显示区域
- 给 OpenClash、TTYD、KMS 绑定不同的页面装载逻辑
- 为 OpenClash 增加页签导航
- 为嵌入 iframe 注入样式，隐藏 OEM 页面多余头尾
- 修复某些 OEM 模板中弹窗 `margin` 不合理的问题

如果只想在工作区生成一个修改后的模板供对比，可以使用：

```sh
sh plugins_0330.sh build-appcenter
```

它会输出：

- [`appcenter_modified_v1.htm`](/Users/jackeroo/Desktop/C2000Max_scripts/appcenter_modified_v1.htm)

## 备份与安全措施

脚本在修改关键文件前，会把备份放到：

- [`/Users/jackeroo/Desktop/C2000Max_scripts/.backup`](/Users/jackeroo/Desktop/C2000Max_scripts/.backup)
- OpenClash 专项备份目录：`/root/openclash-appcenter-fix`

通常会备份：

- `/etc/config/appcenter`
- AppCenter 模板文件
- ttyd 相关 LuCI 页面
- OpenClash 的部分修复文件

## 可配置环境变量

脚本里预留了一些可调参数，适合在执行前覆盖：

- `OPENCLASH_BRANCH`
- `OPENCLASH_MIRRORS`
- `OPENCLASH_CORE_VERSION_MIRRORS`
- `OPENCLASH_CORE_SMART_MIRRORS`
- `KMS_CORE_VERSION`
- `KMS_CORE_IPK_BASE_URL`
- `KMS_LUCI_IPK_URL`
- `INSTALL_OPENCLASH_SMART_CORE`

例如：

```sh
OPENCLASH_BRANCH=dev INSTALL_OPENCLASH_SMART_CORE=0 sh plugins_0330.sh openclash
```

## 执行流程概览

以安装插件为例，整体流程大致如下：

1. 检查是否为 `root`
2. 校验 AppCenter 相关文件是否存在
3. 准备工作目录和镜像源
4. 下载插件包
5. 等待用户确认
6. 安装插件与依赖
7. 写入或修正 LuCI / UCI 配置
8. 注册到 AppCenter
9. 打补丁并刷新 LuCI / appcenter 缓存
10. 输出安装结果和后续提示

## 使用建议

- 首次使用前，先执行 `build-appcenter` 看一下模板改动结果
- 正式安装前确认系统里已经有 AppCenter
- 安装完成后按脚本提示关闭弹窗，并在浏览器里 `Ctrl+F5` 强刷
- 如果是 OpenClash，建议保留脚本生成的备份目录，方便回退

## 已知风险

- 这是一个偏 OEM 定制化的脚本，不保证适配所有 OpenWrt 固件
- 它会直接修改系统模板和配置，不属于“纯安装、不改系统界面”的方案
- 如果你的 AppCenter 模板结构与脚本预期差异很大，补丁可能失败
- OpenClash 的上游页面结构如果变化较大，后续可能需要重新适配

## 仓库内相关文件

- [`plugins_0330.sh`](/Users/jackeroo/Desktop/C2000Max_scripts/plugins_0330.sh)：主脚本
- [`appcenter.htm`](/Users/jackeroo/Desktop/C2000Max_scripts/appcenter.htm)：原始模板样本
- [`appcenter_modified_v1.htm`](/Users/jackeroo/Desktop/C2000Max_scripts/appcenter_modified_v1.htm)：脚本生成的修改版模板
- [`TEMP`](/Users/jackeroo/Desktop/C2000Max_scripts/TEMP)：临时解包与调试材料
- [`TTYD.jpg`](/Users/jackeroo/Desktop/C2000Max_scripts/TTYD.jpg)：界面示意图
- [`AppCenter.jpg`](/Users/jackeroo/Desktop/C2000Max_scripts/AppCenter.jpg)：界面示意图

## 一句话总结

`plugins_0330.sh` 本质上是一个“插件安装 + AppCenter 接入 + 页面兼容修复”的整合脚本，重点不只是装包，而是让 `ttyd`、`OpenClash`、`KMS` 在 NRadio/NROS 的 AppCenter 里能稳定打开、正常显示、便于维护。
