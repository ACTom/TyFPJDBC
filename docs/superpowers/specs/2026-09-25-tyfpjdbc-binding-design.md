# TyFPJDBC 字段绑定矩阵规格（binding matrix）

版本：0.1（brainstorming 路线 A 三节已确认，待评审后转 implementation plan）
日期：2026-09-25
基线：master（version 0.9.0，无 v2 后缀命名）
目标：字段绑定双向链路全方位可测可定：写方向 10 种绑定类型经真库往返，
读方向 canonical form 与 NULL 语义逐库一致，非法值行为分类明确。

## 0. 约束（已确认）

- 四库全覆盖：H2 / SQLite / PG / MySQL 真连（本机 PG 5432、MySQL 3306 已就绪）。
- 空串与 NULL 修链路彻底区分，不保持旧约定。
- 全边界加异常都测：正常值、极值、非法值全部断言行为。
- 无容器/无真库时记 `SKIP` 环境缺失，不伪造成功。

## 1. 类型契约与 NULL/BLOB 语义（已确认）

- 10 种绑定类型逐一钉 canonical form：`bvInt/bvInt64` 十进制整数串；
  `bvDouble` 经 `Double.toString` 往返；`bvBigDec` 经 `toPlainString` 往返；
  `bvStr` UTF-8 原样；`bvDate/bvTime/bvStamp` 为 `yyyy-mm-dd[ hh:nn:ss]`；
  `bvBytes` 字节一致；`bvNull` 按列类型带 `SqlType`。
- NULL 用独立标记，不再复用空串：空串入库读回仍是空串，NULL 读回仍是 NULL。
- BLOB 窗口只带长度占位，内容走独立 `fetchBlob` 取回，两次一致。
- 布尔四库分别标定：`1/0` 与 `true/false` 的写读归一。
- 非法值统一 `HY092/43` 并带原文（如坏日期、坏 BigDecimal）。
- `CollectRow` 的 NULL 按列类型带 `SqlType`，不再写死 `SQL_VARCHAR`。

## 2. 链路修改（已确认）

- `fetchWindow` 加 NULL 位数组，与字符串数组并行返回；
  `FillWindow` 按位 `Clear`，不再看空串。
- `FillField` 删 BLOB 占位分支（`<blob:...>` 清空），改走 `fetchBlob` 内容路径。
- `BindRow` 按列 `SqlType` 透传 NULL 类型。
- `CollectRow`：`ftBoolean` 走 `BInt` 且读回 `1/0` 归一；
  数字小数点按不变格式（不随 locale 变逗点）；
  日期非法原文透出；CJK 走 `AsUTF8String` 原样。
- `MapType` 与 `Types` 码表合并为单一真值表；
  `OTHER/ARRAY/STRUCT` 走 memo，未知类型按 fallback 抛 `HY000/45`。

## 3. 测试矩阵与错误语义（已确认）

- 新 `TestBinding`：四库跑全 10 类型正常值，加 `Int64` 极值、
  `Double` 特殊值、`BigDecimal` 高精度、CJK/宽字节、0 字节 blob、非法日期。
- 空串与 NULL 分开断言；BLOB 窗口占位加独立内容两次一致；
  批量 1000 分片；`Int64`/`Double`/`BigDecimal` 文本往返一致。
- 错误语义：非法值 `HY092/43`、未知类型 `HY000/45`、约束走 `ecFatal`、
  超时取消走 `ecRetryable`。
- 矩阵无容器时 PG/MySQL 记 `SKIP`，不伪造成功。

## 4. 非目标

- 不改 `Bridge` JNI 扁平签名形状之外的池/事务/连接语义。
- 不做 benchmark 竞赛式优化；只锁行为一致与分类正确。
- 不碰 `0.9.0` 版本握手。

## 5. 验收

- `TestBinding` 四库全绿（含边界与异常断言），空串/NULL 分开通过。
- `guard.ps1` 全绿；完整矩阵 `MATRIX-OK`。
- 证据：tests / launch / guard / matrix 四份日志归档。
