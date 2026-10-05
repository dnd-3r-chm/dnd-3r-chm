# 龙与地下城3R扩展规则大全
总而言之，现在3版也开始用github来为扩展大不全做版本控制了。

我们推荐阅读5版不全书的[readme.md](https://github.com/DND5eChm/DND5e_chm/blob/main/README.md)

或果园5版讨论区的帖子["如何给5e不全书做贡献"](https://www.goddessfantasy.net/bbs/index.php?topic=151088.0)来研究相关技巧。

（因为狮鹫自己还没想好如何用简明的语言来描述这部分内容。）

## 页面与 CHM 工程

本仓库使用根目录 `Contents.hhp` 工程、`Contents.hhc` 目录及 `Index.hhk` 索引；可用 HTML Help Workshop 打开工程并编译。新增页面和资源应登记在 `[FILES]`，并同步目录及索引。生成的 CHM 不纳入版本控制。

HTML/HTM 及这三个工程文件保持 GBK 编码。GBK 无法表示的正文字符使用 HTML 数值实体，避免丢字；页面声明须与实际编码一致，站内链接使用相对路径。新增页面保留本页勘误入口，相关维护和检查函数见 `scripts/feedback-entry.ps1`。

万法大全入口位于 `2 万物万法万律/SpC万法大全/封面.htm`，其目录提供职业、领域及按英文名 A–Z 分页的正文。法术中英文名可从 CHM 索引检索；在线详情需要网络连接。
