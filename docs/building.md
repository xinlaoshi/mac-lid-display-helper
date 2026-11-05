# 从源码构建

需要 Apple 芯片 Mac、Xcode 或包含 macOS SDK 的兼容开发工具，以及 Python 3。构建使用 Swift 5 语言模式和 macOS14最低部署目标；在最新开发工具环境中验证。较旧工具链尚未逐版本验收。

```bash
git clone https://github.com/xinlaoshi/mac-lid-display-helper.git
cd mac-lid-display-helper
bash scripts/test.sh
bash scripts/build.sh
```

构建产物位于 `output/Mac合盖和显示器联动助手.app`。构建脚本创建本地签名，不能替代公开分发所需的Developer ID签名和Apple公证。

测试使用模型和模拟显示后端，不改变真实屏幕，也不需要外接显示器。

## 开发安装

```bash
bash scripts/install.sh
```

脚本安装至 `/Applications`，停止同一路径旧实例、写入当前用户登录启动项并启动新版。运行App后会按已保存规则控制显示输出；请先保存旧实例里需要的未保存设置。本脚本依赖Python 3，面向开发者。普通用户直接下载Release中的DMG。

Swift模块缓存保存在用户Library/Caches目录，不进入仓库。源码不依赖BetterDisplay、displayplacer可执行文件或第三方Swift软件包。
