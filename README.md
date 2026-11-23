# OSS Monitor

macOS 菜单栏小工具：查看 rclone 挂载目录往对象存储（如阿里云 OSS）上传文件的进度。

把文件拷进 rclone 挂载的目录后，rclone 会先写进本地缓存、过几秒再在后台上传。OSS Monitor 读 rclone 的日志，告诉你现在在传什么、还有多少在排队、传得多快、有没有出错。

## 功能

- **菜单栏状态**：上传中显示实时速度（如 `↑ 1.2 MB/s`），排队中、全部完成、rclone 异常各有不同图标
- **正在上传**：文件名、大小、已用时；只有一个文件在传时估算进度和剩余时间
- **排队中**：等待上传的文件，以及多少秒后开始
- **最近完成**：最近 10 个已完成 / 失败 / 取消的文件
- **缓存概况**：rclone 缓存大小、待传数、上传中数
- **错误**：最近 10 条错误，可一键打开日志文件
- **设置**：Bucket 名称（只用于显示）、挂载目录、rclone 日志文件、rclone 进程匹配规则

## 工作原理

- 上传状态来自 rclone 的日志（`vfs cache: queuing for upload`、`upload succeeded` 等），所以 rclone 需要用 `--log-file` 写日志，日志级别至少为 INFO（`-v` 或 `--log-level INFO`）
- 上传速度：用 `pgrep -f` 找到 rclone 进程，再用系统自带的 `nettop` 统计它的出站流量
- 挂载状态：检查设置里的挂载目录是否是一个挂载点

## 系统要求

- macOS 13 及以上
- Apple Silicon
- 已用 rclone 挂载好对象存储，并开启了日志

## 安装

需要 Xcode 或 Xcode 命令行工具（`xcode-select --install`）。

```bash
./build.sh
```

脚本会在临时目录编译，装到 `/Applications/OSSMonitor.app` 并启动。app 只在菜单栏显示图标，不出现在 Dock。

## 设置

点菜单栏图标，再点右下角「设置」：

| 设置项 | 默认值 |
|---|---|
| Bucket 名称 | 空（不显示） |
| 挂载目录 | `~/oss` |
| rclone 日志文件 | `~/Library/Logs/rclone/oss-mount.log` |
| rclone 进程匹配（`pgrep -f`） | `rclone nfsmount` |

路径可以用 `~` 表示主目录，留空则用默认值。保存后立即按新设置重新读取。

## 许可证

[MIT](LICENSE)
