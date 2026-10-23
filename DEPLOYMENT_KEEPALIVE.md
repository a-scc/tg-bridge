# tg-bridge 部署保活 profile（推荐默认）

- 系统服务：Restart=on-failure，RestartSec=10，RestartPreventExitStatus=2。unit 权威副本放家目录，不要只放 /etc，整机替换会 wipe /etc，丢了要按家目录副本重装。
- 状态持久：inbox / state（offset、心跳、done/）同样放家目录的持久盘，随 unit 副本一并恢复；offset 丢了会重复投递一批旧消息。
- 消息投递：值班 30 秒以内一轮，最好 5-10 秒或事件触发（如 hook 唤醒 worker）；实在只能用 cron 的环境放宽到 1 分钟，不要放宽到 5 分钟；正常 1 分钟内回。
- 心跳探活：listener 每轮轮询写一次心跳。看门狗 5 分钟一轮，探活看心跳新鲜度：stale 阈值 = 2 倍以上 ×（长轮询服务器超时 + 20 秒客户端余量）；默认 50 秒长轮询下约 150 秒（2×70）。改 `TG_LONGPOLL_TIMEOUT` 时阈值跟着重算；超过阈值算不健康，不只看进程在不在。
- 挂起修复：进程活着但探活失败 / 心跳 stale 时要 restart，start 是空操作，Restart 也拉不动没退出的进程。
- 空转停机：401 / 409 时 listener 以 exit 2 退出，unit 用 RestartPreventExitStatus=2 让它停下来不空转；journal 里 401 / 409 反复出现时告警并停机等人工处理，先查是否双跑、再动 token。
- 单例限制：同 bot 只能一个轮询器，双跑会 409；unit 丢了重装时不要起第二个实例。
- 模式切换：先停云端轮询、云端 log_out，再起本地；切回云端等 10 分钟（保守经验值，非官方明文，宁多勿少）。
- 文件分流：50MB 内自动拉（脱钩后台），超了 VPS 落盘 + 通知 + 按需拉，删前用户确认。
