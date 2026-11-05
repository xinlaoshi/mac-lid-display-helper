# Developer ID 签名与 Apple 公证

源码构建与公开分发使用不同的签名流程。`scripts/build.sh` 生成带 Hardened Runtime 的本地签名 App；它本身不代表已经取得 Developer ID 签名或完成 Apple 公证。

## 准备

需要有效的 Apple Developer Program 会员，以及相应的 Developer ID 分发权限。在 Xcode「Settings → Apple Accounts」登录，并核对当前会员的 Team ID；不要只按同名旧证书推断团队编号。私钥、密码、API密钥和公证凭据均不进入仓库。

```bash
bash scripts/build.sh
python3 scripts/prepare-notarization-archive.py --team-id YOURTEAMID
```

脚本只在 `output/notarization/` 中准备本地归档容器与 ExportOptions，不连接 Apple，也不创建开发者证书。它保留已有归档，不覆盖其中的公证提交记录。

## 提交与导出

把下列路径换成脚本打印的路径。Xcode 使用已登录账号完成 Developer ID 签名、安全时间戳及上传；视团队配置而定，可能使用 Apple 托管的签名证书。这里的 export 操作不重新编译源码。

```bash
xcodebuild -exportArchive \
  -archivePath /path/to/App.xcarchive \
  -exportOptionsPlist /path/to/ExportOptions.plist \
  -exportPath /path/to/exported \
  -allowProvisioningUpdates

xcodebuild -exportNotarizedApp \
  -archivePath /path/to/App.xcarchive \
  -exportPath /path/to/notarized
```

上传成功不等于公证通过。如果返回 processing，等待 Apple 处理后再执行 `-exportNotarizedApp`；其他错误应先查明原因。不要更换归档或反复重新提交同一份 App。

## 分发核验

对最终导出的 App 检查以下结果，全部通过后再打包：

```bash
codesign --verify --strict "/path/to/notarized/App.app"
codesign -dv --verbose=2 "/path/to/notarized/App.app"
xcrun stapler validate "/path/to/notarized/App.app"
spctl --assess --type execute --verbose=2 "/path/to/notarized/App.app"
```

签名应显示正确的 Developer ID Application 团队、Hardened Runtime 和安全时间戳；票据应验证通过；Gatekeeper 应返回 accepted / Notarized Developer ID。ZIP必须保留App的公证票据文件与扩展属性；DMG中应放入经过验证的完整App。重新下载公开安装包后，还应再次核对哈希、签名和票据。

公证不是 Mac App Store 审核，也不保证所有显示器组合兼容。首次打开时仍可能出现正常的“从互联网下载”确认提示。

参考：[Apple 公证说明](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)、[Developer ID 证书](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)。
