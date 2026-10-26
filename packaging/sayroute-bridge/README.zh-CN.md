# SayRoute Bridge 安装说明

[English](README.md) · UU 快速模式远端组件。安装在**被控 Mac**，主 App 运行在控制端。当前候选版 **1.4.0 (20)**，对应控制端 **1.4.0 (21)**。

1. 将完整解压目录复制到被控端，保留二进制、校验文件、全部脚本、共享脚本和 BUILD-INFO.txt。
2. 双击 `install.command`：核验、备份、停止旧服务、停用旧 LaunchAgent，安装新版并校验新进程健康状态；失败自动回退。
3. 在系统设置 → 隐私与安全性 → 辅助功能，为下方新可执行文件授权。旧路径权限不会自动继承。
4. 运行 `verify.command`；退出码 2 表示服务已安装但辅助功能未授权。
5. UU 映射：控制端 `127.0.0.1:17771` → 被控端 `127.0.0.1:17771`。主 App 选快速模式，在空白编辑器进行真实输入测试。

```text
程序：       ~/Library/Application Support/SayRoute/sayroute-bridge
LaunchAgent：~/Library/LaunchAgents/com.devonkong.sayroute.bridge.plist
日志：       ~/Library/Logs/SayRoute/
订单事件库： ~/Library/Application Support/SayRoute/paste-orders-helper.sqlite3
备份：       ~/Library/Application Support/SayRoute/backups/
```

安装器会打印准确备份目录及回退命令。在终端运行 `rollback.command '安装器打印的备份路径'`，恢复先前文件和原先运行的服务。若之后安装文件有变化，回退会拒绝覆盖。旧 helper 二进制和日志仍留在 Doubao Murmur 目录，不可同时启动新旧服务。

本包使用 ad-hoc 签名，未 Apple 公证。安装器不自动移除隔离属性；如被系统阻止，先核验校验和与来源，再通过系统明确授权流程处理。当前用户的 LaunchAgent 不需要管理员权限。

`diagnose.command` 限时、只监听修饰键及指定测试键类别，不读取 Unicode 原文或剪贴板。请在被控端检查 Delete、空格、A 和左右 Command。投递 ACK 不代表编辑器插入成功。

协议仍为 version 2，只监听 loopback；没有身份认证及远端目标绑定，不得开放到局域网或公网。连接与端口映射必须可信。健康检查失败时先查日志，不要再启动第二份占用同一端口的 helper。

发布前按仓库迁移与验收文档完成真实双机输入验证，自动检查不能替代它。
