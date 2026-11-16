# JGUS 串口屏 + Lua 模组开发指南

> **适用对象**：基于 JGUSII 系列串口屏 + 带 Lua 运行时的主控模组进行二次开发
> **读者**：嵌入式 C 工程师（本指南附 Lua 速成章节，懂 Lua 可直接跳到第三部分）
> **资料来源**：《JGUSII 系统用户手册 V1.3》（深圳晶兴科技，164 页，下称"官方手册"）+ 等离子治疗仪项目源码
> **AI 助手请读**：同目录 `AI开发手册.txt`（本文件的纯文本镜像，由 `make_ai_txt.ps1` 生成；改本文件后跑一次脚本同步）
> **标注约定**：`【代码确证】` = 有实际调用代码验证；`【推断】` = 根据官方手册或代码注释推断，以厂商 SDK 文档为准

---

## 目录

- [0. 资料体系与阅读指引](#0-资料体系与阅读指引)
- [第一部分 快速上手](#第一部分-快速上手)
- [第二部分 Lua 速成（给 C 工程师）](#第二部分-lua-速成给-c-工程师)
- [第三部分 jgus API 参考](#第三部分-jgus-api-参考)
- [第四部分 uart、平台全局函数与 sys 任务框架](#第四部分-uart平台全局函数与-sys-任务框架)
- [第五部分 三大数据通路](#第五部分-三大数据通路)
- [第六部分 实战配方（可直接复制）](#第六部分-实战配方可直接复制)
- [第七部分 调试排错与新项目 Checklist](#第七部分-调试排错与新项目-checklist)
- [第八部分 项目实战经验（倒计时/联动复盘）](#第八部分-项目实战经验倒计时联动复盘)
- [第九部分 AI 协作开发指南（写给 AI 看的项目导读）](#第九部分-ai-协作开发指南写给-ai-看的项目导读)
- [附录](#附录)

---

# 0. 资料体系与阅读指引

## 0.1 三份资料各管什么

| 资料 | 管什么 | 什么时候查 |
|---|---|---|
| **官方手册 PDF**（164 页） | 屏幕侧：串口协议帧格式、系统接口变量地址、控件配置、屏幕工程上位机操作、SD 卡下载 | 设计画面、配控件、查协议字节、查 VP 系统地址 |
| **本指南** | 主控侧：Lua 怎么调 `jgus` 库、任务框架、收发数据、写业务逻辑 | 写 Lua 应用代码时 |
| **项目源码**（本目录 5 个 .lua） | 完整可运行的参考实现 | 抄代码、看真实用法 |

**两者的关系**：你在屏幕上画好控件、分配好 VP 地址（官方手册的事），然后在 Lua 里用 `jgus.vp_read/vp_write` 读写这些地址（本指南的事）。

```
┌────────────────────────────────────────────────────────┐
│  屏幕工程（JGUS 上位机）                                │
│  画控件 → 分配 VP 地址 → 生成 13.BIN/14.BIN → SD 卡下载 │
└───────────────────────┬────────────────────────────────┘
                        │ 5A A5 串口协议（官方手册 第三章）
                        │ 0x82 写变量 / 0x83 读变量
┌───────────────────────▼────────────────────────────────┐
│  主控模组（Lua 运行时）                                  │
│  jgus.vp_write / vp_read / screen_set_page ... ←本指南  │
│  sys 任务框架 + uart + 业务逻辑                          │
└───────────────────────┬────────────────────────────────┘
                        │ Modbus RTU / 其他串口协议
┌───────────────────────▼────────────────────────────────┐
│  现场设备（IO 模块、传感器、继电器…）                     │
└────────────────────────────────────────────────────────┘
```

## 0.2 官方手册最常用章节速查

| 内容 | 官方手册位置 |
|---|---|
| 串口参数、帧结构（5A A5） | 第三章 3.1 / 3.2（P23） |
| 0x82 写变量、0x83 读变量指令 | 3.3.1（P25） |
| **系统接口变量地址表**（复位/RTC/切页/背光/蜂鸣器） | 第四章（P30-38） |
| 触控/键控控件（含**按键值返回 0xFE05**） | 第六章（P49 起，按键值返回 P63） |
| 显示控件（数据变量 0x10、文本 0x11、时钟、进度条…） | 第七章（P75 起） |
| Config.txt（波特率/帧头/CRC 开关/应答开关） | 5.5（P42-48） |
| CRC-16 参考代码（C 语言） | 3.5（P29） |

## 0.3 核心概念（30 秒）

- **VP（变量空间）**：屏幕 RAM 里的一块 16 位寄存器阵列，0x0000~0xFFFF，每个地址 = 1 个 Word = 2 Byte（官方 P22）
- **变量驱动**：屏幕一切状态（显示什么、在哪页）都由 VP 里的数据决定；**谁改 VP，谁就控制了屏幕**
- **系统接口区 0x0000~0x0FFF**：官方保留（复位、RTC、切页等），**用户变量从 0x1000 开始分配**
- **模组 = 主控**：Lua 跑在主控模组上，通过串口按 `5A A5` 协议读写屏幕 VP

---

# 第一部分 快速上手

## 1.1 工程文件结构

一个 Lua 应用 = 若干 `.lua` 文件，固件按入口文件加载。推荐结构（本项目即此结构）：

```
LUA/
├── main.lua      # 入口：初始化 + 启动任务 + 启动调度器（你主要写这个）
├── sys.lua       # 任务调度框架（协程实现，直接复用，不用改）
├── modbus.lua    # Modbus RTU 收发（按需复用/替换成你的协议）
├── crc16.lua     # CRC16 校验（Modbus 必备）
├── json.lua      # JSON 序列化（第三方库，按需）
└── （固件内置，无需文件）
    jgus  ← require("jgus")  屏幕操作库（本指南主角）
    uart  ← require("uart")  串口库
    msleep / print           平台全局函数
```

模块加载约定（详见 2.3 节）：

```lua
sys    = require("sys")
jgus   = require("jgus")
uart   = require("uart")
crc16  = require("crc16")
modbus = require("modbus")
require("json")            -- json.lua 直接挂到全局 JSON 表上
```

## 1.2 程序生命周期

```
上电
 │
 ├─ main.lua 从第一行顺序执行
 │    ├─ require 各模块
 │    ├─ init()        自定义初始化（读保存数据、下发配置）
 │    ├─ sys.taskInit()×N   注册若干"任务"（此时还不运行）
 │    └─ sys.scheduler()    ★进入调度器，永不返回
 │
 └─ 调度器循环：轮流唤醒各任务 → 任务里 sys.wait() 让出 → 再唤醒…
```

**铁律**：`sys.scheduler()` 必须放在文件最后；任务体必须周期性 `sys.wait()`。

## 1.3 最小可跑工程（骨架）

```lua
-- main.lua 最小骨架
sys  = require("sys")
jgus = require("jgus")

-- 初始化
local function init()
    -- 你的初始化：读保存参数、配置从站等
    jgus.screen_set_page(0)          -- 开机进主页面
end
init()

-- 任务1：按键扫描（30ms 周期）
sys.taskInit(function()
    while true do
        local key = jgus.vp_read(0x1000)   -- 读按键值
        if key ~= 0 then
            -- 分发按键…
            jgus.vp_write(0x1000, 0)       -- 处理完清零
        end
        sys.wait(30)
    end
end)

-- 任务2：状态刷新（500ms 周期）
sys.taskInit(function()
    while true do
        -- 读传感器 / 更新显示 …
        sys.wait(500)
    end
end)

sys.scheduler()   -- 启动调度，程序到此"永远循环"
```

## 1.4 三步验证（新工程先跑通这三步再堆功能）

| 步骤 | 做什么 | 成功标志 |
|---|---|---|
| **① 屏幕亮** | SD 卡下载屏幕工程，上电 | 屏幕显示你的开机画面 |
| **② 交互通** | 屏幕配一个"按键值返回"控件 → VP 0x1000；Lua 读到非零值并 `vp_write` 回显 | 按屏幕按钮，数值变化 |
| **③ 外设动** | 发一条控制命令给从站（Modbus 写线圈/或你的协议） | 继电器"咔哒"动作 |

三步都绿，说明**屏幕通路、Lua 框架、外设通路**全部打通，再开始写业务逻辑。

---

# 第二部分 Lua 速成（给 C 工程师）

> 懂 Lua 的读者跳到[第三部分](#第三部分-jgus-api-参考)。

## 2.1 语法对照表

| 你在 C 里写 | Lua 写法 | 备注 |
|---|---|---|
| `int x = 10;` | `local x = 10` | **不加 `local` 就是全局变量**（大坑，见 2.6） |
| `int a[3] = {1,2,3};` | `local a = {1, 2, 3}` | 下标**从 1 开始**：`a[1]` |
| `a[0]` | `a[1]` | 1-based，贴过来必错 |
| `!=` | `~=` | |
| `&&` `\|\|` `!` | `and` `or` `not` | |
| `strcat(a, b)` | `a .. b` | `..` 是拼接，**产生新串** |
| `strlen(s)` | `#s` | |
| `{ ... }` 块 | `then`/`do` 进门，`end` 关门 | `if x then end` |
| `switch` | `if / elseif / else` | Lua 无 switch |
| `x ? y : z` | `(cond and y) or z` | 或用 if 写清楚 |
| `printf("%d", n)` | `string.format("%d", n)` | |
| `for (i=1;i<=10;i++)` | `for i = 1, 10 do end` | **闭区间，含 10** |
| 遍历数组 | `for i, v in ipairs(t) do end` | |
| 遍历哈希 | `for k, v in pairs(t) do end` | |
| `NULL` | `nil` | 访问不存在的 key 返回 nil |
| `p = &x; *p = 1` | **没有指针** | table 是引用语义，其余按值 |
| `malloc/free` | 不需要 | 自动 GC |
| 结构体字段 | `obj.field`（等价 `obj["field"]`） | |

数字运算：Lua 只有一种数 `double`（Lua 5.3 起有整数子类型，`//` 整除）。位运算 5.3+ 原生支持：`& | ~ << >>`（注意 `~` 是按位异或，`~=` 才是不等于）。

## 2.2 table —— 万能数据结构

table 同时是**数组、哈希、结构体、对象**：

```lua
-- 数组（下标1起）
local list = {"a", "b", "c"}
print(#list)            -- 3
print(list[1])          -- "a"

-- 哈希 / 结构体
local dev = {name = "pump", addr = 3, state = 0}
print(dev.name)         -- "pump"   （dev.name ≡ dev["name"]）
dev.state = 1           -- 改字段

-- 函数也是值（后面模块、回调全靠它）
local t = {}
function t.hello() print("hi") end   -- 等价 t.hello = function() ... end
t.hello()

-- 模块 = 返回一个 table（见 2.3）
```

## 2.3 require 模块机制 ≈ include + link

**你的模块文件**（如 `mytool.lua`）：

```lua
local m = {}            -- 相当于建一个 struct 实例
function m.foo(a, b)    -- 相当于 struct 的成员函数
    return a + b
end
return m                -- ★ 把 table 返回给使用者
```

**使用者**：

```lua
mytool = require("mytool")   -- 第一次 require 加载并缓存（package.loaded）
mytool.foo(1, 2)             -- ≈ mytool->foo(1,2)
```

要点：
- `require` 有缓存，同一模块只会加载一次
- `return` 的是 table，所有函数挂在 table 上 = C 里"命名空间"
- **固件内置模块**（`jgus`、`uart`）由 C 实现，同样是 `require` 拿到一个 table

## 2.4 协程 = 你的"RTOS 任务"

Lua 没有线程，用**协程（coroutine）**做协作式多任务。本项目 `sys.lua` 就是一个微型 RTOS 调度器：

| RTOS 概念 | sys 框架 | 说明 |
|---|---|---|
| 创建任务 | `sys.taskInit(function() ... end)` | ≈ `xTaskCreate` |
| 延时/让出 | `sys.wait(ms)` | ≈ `vTaskDelay`，内部是 `coroutine.yield()` |
| 调度循环 | `sys.scheduler()` | 每轮依次 `coroutine.resume` 各任务 |

任务长这样：

```lua
sys.taskInit(function()
    while true do
        do_work()      -- 干活
        sys.wait(30)   -- ★必须让出，否则独占CPU（见 4.4 铁律）
    end
end)
```

**关键理解**：`sys.wait(30)` 不是"阻塞 30ms"，而是"把控制权还给调度器，30ms 后再唤醒我"——期间其他任务照常跑。所以**任何任务里都不能忙等**（`while ... end` 死循环不带 wait = 系统跑飞）。

## 2.5 字节串操作 —— C 里操作 `uint8_t[]` 的替代

Lua 字符串**不可变**，天生适合当"只读字节缓冲"，配套函数：

| C 操作 | Lua |
|---|---|
| `x = buf[i]` | `x = string.byte(s, i)` ⚠️ 下标从 1 起 |
| `buf[i] = v` | 不能改！只能拼新串 `s = s .. string.char(v)` |
| `memcpy(dst, src, n)` | `string.sub(s, i, j)`（含 i 含 j） |
| `char buf[69] = {0}` | `string.rep("\0", 69)` |
| `strcat(a, b)` | `a .. b` |
| `s[n] = '\0'` 截断 | 无（用 `string.sub`） |
| `strlen` | `#s` |
| `sprintf` | `string.format` |

**组帧典型写法**（拼二进制协议）：

```lua
local frame = string.char(0x5A, 0xA5)              -- 帧头
frame = frame .. string.char(#pdu + 1)             -- 长度
frame = frame .. pdu                               -- 拼数据
frame = frame .. crc16.check_crc16(frame)          -- 拼CRC
```

**读缓冲典型写法**：

```lua
local b1 = string.byte(frame, 1)                   -- 第1字节
local hi = string.byte(frame, 3)                   -- 高字节
local lo = string.byte(frame, 4)                   -- 低字节
local value = hi * 256 + lo                        -- 合成16位（大端）
```

## 2.6 给 C 工程师的五个高危坑

1. **忘写 `local`** → 创建全局变量。同名互相覆盖，且跨文件可见（既是特性也是坑：项目靠全局变量做跨模块通信，如 `RuningState`、`crc16`）。经验：**模块内变量一律 `local`，需要共享的显式用全局并起带前缀的名字**。
2. **下标 0-based 思维** → 所有数组/字符串下标从 1 起。
3. **字符串不可变** → 循环里反复 `s = s .. x` 是 O(n²)，大数据量先攒 table 再 `table.concat`。
4. **`/` 是浮点除** → 取整要 `math.floor(a/b)`。
5. **没有 `switch`/指针/结构体内存布局** → 别试图用"偏移量"操作数据，用字段名。

---

# 第三部分 jgus API 参考

`jgus = require("jgus")` 后可用。**总览**：

| 函数 | 作用 | 底层（官方手册） |
|---|---|---|
| `vp_read(addr)` | 读 1 个变量（16 位） | 0x83 读变量空间 |
| `vp_read_high_byte(addr)` | 读该变量的高字节 | 0x83 + 取高 8 位 |
| `vp_read_low_byte(addr)` | 读该变量的低字节 | 0x83 + 取低 8 位 |
| `vp_write(addr, value)` | 写 1 个变量（16 位） | 0x82 写变量空间 |
| `vp_write_string(str, addr)` | 把字符串写入变量空间 | 0x82 连续写 |
| `eprom_read(buf, addr, len)` | 读模组掉电保存区 | 模组本地存储 |
| `eprom_write(str, addr, len)` | 写模组掉电保存区 | 模组本地存储 |
| `screen_set_page(page)` | 切换屏幕页面 | 写系统接口 0x0084 |
| `disable_serial_receive()` | 关闭固件侧 JGUS 协议自动接收 | 固件配置 |
| `tick_get()` | 取当前毫秒 tick | 系统定时器 |
| `tick_elapse(start)` | 距 `start` 过去了多少毫秒 | 系统定时器 |

## 3.1 vp_read —— 读变量

```lua
local value = jgus.vp_read(addr)     -- 【代码确证】main.lua:235
```

| 参数 | 类型 | 说明 |
|---|---|---|
| `addr` | number | 变量地址 0x0000~0xFFFF |
| **返回** | number | 该地址的 **16 位值**（0~65535） |

**要点**：
- 读的是一个 **Word**（2 字节）。要单字节用 3.2/3.3 的专用函数
- 对应官方协议：`5A A5 04 83 addr_H addr_L 01`（读 1 个字，见官方 P25）
- 系统接口地址只读项也可读（如 0x0014 当前页面号、0x000F 版本号）

```lua
-- 实例：扫描按键（按键值返回控件的 VP 设在 0x1000）
local key = jgus.vp_read(0x1000)
if key ~= 0 then
    handle_key(key)
    jgus.vp_write(0x1000, 0)      -- 用完清零，等下次按键
end
```

## 3.2 vp_read_high_byte / vp_read_low_byte —— 读单字节

```lua
local hi = jgus.vp_read_high_byte(addr)   -- 高字节 0~255 【代码确证】main.lua:46
local lo = jgus.vp_read_low_byte(addr)    -- 低字节 0~255 【代码确证】main.lua:47
```

**一个 Word 塞两个字段**时用它。典型场景：RTC 时间（官方 P30，地址 0x0010 起 4 个 Word 装 年/月/日/星期/时/分/秒，每 2 字节装 2 个字段）：

```lua
-- 官方手册 P30：0x0010 D7=年 D6=月；0x0011 D7=日 D4=星期；0x0012 D7=时 D6=分；0x0013 D7=秒
local year   = jgus.vp_read_high_byte(0x0010)   -- 年（20xx 的 xx）
local month  = jgus.vp_read_low_byte (0x0010)   -- 月
local day    = jgus.vp_read_high_byte(0x0011)   -- 日
local hour   = jgus.vp_read_high_byte(0x0012)   -- 时
local minute = jgus.vp_read_low_byte (0x0012)   -- 分
local second = jgus.vp_read_high_byte(0x0013)   -- 秒
```

不想用两个函数也可手动拆：`local hi = (jgus.vp_read(addr) >> 8) & 0xFF`。

## 3.3 vp_write —— 写变量

```lua
jgus.vp_write(addr, value)     -- 【代码确证】main.lua:259 等 30+ 处
```

| 参数 | 类型 | 说明 |
|---|---|---|
| `addr` | number | 变量地址 |
| `value` | number | 写入的 16 位值（0~65535） |

**要点**：
- 对应官方协议：`5A A5 07 82 addr_H addr_L value_H value_L`（写 1 个字）
- 屏幕上绑定该 VP 的控件**立即刷新**（变量驱动）
- 可写系统接口可写项（见 5.1 地址表）

```lua
-- 倒计时显示：小时/分/秒 分别绑在 0x1101/0x1102/0x1103 的"数据变量显示"控件上
jgus.vp_write(0x1101, hours)
jgus.vp_write(0x1102, minute)
jgus.vp_write(0x1103, second)

-- 给"进度条/图标显隐"控件写 0/1
jgus.vp_write(0x3001, 1)     -- 显示
```

## 3.4 vp_write_string —— 写字符串

```lua
jgus.vp_write_string(str, addr)    -- 【代码确证】main.lua:223
```

| 参数 | 类型 | 说明 |
|---|---|---|
| `str` | string | 要显示的文本 |
| `addr` | number | 目标变量地址（文本控件的文本指针 VP） |

**要点**：
- 把字符串编码（按屏幕工程里文本控件的编码方式：ASCII/GB2312/GBK，官方 P101 的 Encode 字段）写入 `addr` 起的变量空间
- 需要屏幕工程里有**文本显示控件（0x11）**，其"文本指针 VP"绑到同一地址
- 文本控件遇到 `0x0000`/`0xFFFF` 或到文本框尾停止显示（官方 P101），所以写新文本前不需要手动清残留——但**短文本覆盖长文本时**建议先 `vp_write(addr, 0)` 清首字

```lua
-- 在 0x2010 起的文本框显示开始时间
jgus.vp_write_string(usage_record.start_time, 0x2010)

-- 清空该文本框
jgus.vp_write(0x2010, 0x0000)
```

## 3.5 eprom_read / eprom_write —— 掉电保存区

```lua
jgus.eprom_write(str, addr, len)              -- 【代码确证】main.lua:70
jgus.eprom_read(buf, addr, len)               -- 【代码确证】main.lua:401
```

| 参数 | 说明 |
|---|---|
| `str` / `buf` | 数据（写）/ **预分配的目标缓冲区**（读） |
| `addr` | 存储偏移地址 |
| `len` | 字节数 |

**读的固定套路**（三行，务必背下来）：

```lua
local buf = string.rep("\0", N)   -- ① 开 N 字节缓冲（≈ char buf[N]={0}）
jgus.eprom_read(buf, addr, N)     -- ② 读进去（C 函数原地改写 buf 的内存）
local value = string.byte(buf)    -- ③ 取出数值
```

**要点**：
- 这是**模组本地**的掉电保存区（EEPROM/Flash 模拟），不是屏幕的存储——不要和屏幕 VP 混淆
- **缓冲区长度必须 ≥ 读取长度**，否则内存越界（SDK 层风险）
- 字符串是 Lua 层面"不可变"的，这里靠 C 层直接改内存实现"读入"，属 SDK 特殊设计——**只信任官方传参约定，别对其做字符串复用**

```lua
-- 实例：读回保存的记录条数（1 字节）
local b = string.rep("\0", 1)
jgus.eprom_read(b, 0, 1)
local count = string.byte(b)

-- 实例：写入一条 JSON 记录
local s = JSON.toString(rec)
jgus.eprom_write(string.char(#s), slot*80 + 2, 1)   -- 先写长度
jgus.eprom_write(s, slot*80 + 3, #s)                -- 再写数据
```

【推断】存储总容量、擦写寿命、是否分区，官方 Lua SDK 未见公开说明，按厂商资料确认；建议地址从 0 起连续规划并留冗余。

## 3.6 screen_set_page —— 切换页面

```lua
jgus.screen_set_page(page)      -- 【代码确证】main.lua:332
```

| 参数 | 说明 |
|---|---|
| `page` | 页面索引号（与屏幕工程里的页面 ID 一致） |

**底层**：对应官方系统接口 **0x0084 Picture Set**（P34），效果 ≈ 写 `0x5A01`（触发+切换模式）| 页号【推断】。可以直接用 `vp_write` 平替：

```lua
jgus.vp_write(0x0084, 0x5A01)   -- 切到 1 号页（等价 screen_set_page(1) 的底层动作）【推断】
```

**要点**：
- 页号必须是屏幕工程中存在的页面，**不存在则指令不生效**（官方 P34 明确说明）
- 配套读当前页：`jgus.vp_read(0x0014)`（PictureNow，官方 P30）
- 开机进哪页也可在屏幕工程侧配置（上电页面），不一定要 Lua 发

## 3.7 disable_serial_receive —— 关闭固件侧 JGUS 协议接收

```lua
jgus.disable_serial_receive()   -- 【代码确证】main.lua:14（注释：关闭JGUS协议通讯）
```

**作用**：关闭固件内置的 JGUS 协议数据自动接收处理。【推断】当主串口上跑的不是屏幕协议（比如本项目同一串口接 Modbus 设备）时，必须关掉，否则固件会把 Modbus 字节流当成屏幕协议帧吃掉/干扰 Lua 侧解析。

**使用建议**：
- 串口只连屏幕、不接其他协议设备 → 通常不需要调用
- **串口复用（屏幕与 Modbus/其他设备共享）或屏幕上不跑 JGUS 协议** → 开头调用一次
- 调用后 `vp_read/vp_write` 等**发命令仍可用**（发送是主动动作），被关的是"自动接收分发"

> 若你的 SDK 文档对该函数语义另有说明，以 SDK 文档为准。

## 3.8 tick_get / tick_elapse —— 毫秒时基

```lua
local t = jgus.tick_get()              -- 当前毫秒计数 【代码确证】main.lua:99
local ms = jgus.tick_elapse(t)         -- 从 t 起过去了多少毫秒 【代码确证】main.lua:103
```

**这就是裸机的 `HAL_GetTick()`**。两个典型用法：

```lua
-- ① 单次延时判断（风扇启动 3 秒后才允许点火）
if not fan_start then fan_start = jgus.tick_get() end
if jgus.tick_elapse(fan_start) >= 3000 then fire_on() end

-- ② 超时检测（发送后 500ms 没收到回复 = 超时）
local t = jgus.tick_get()
send()
while jgus.tick_elapse(t) < 500 do sys.wait(10) end   -- ★循环里必须 sys.wait
```

**与 `sys.wait` 的分工**：
- 不关心过程、纯等 N 毫秒 → `sys.wait(N)`
- 等待期间要干别的、或要判断"过了多久" → `tick_get` + `tick_elapse` + 周期 `sys.wait`

⚠️ tick 是 32 位毫秒计数，约 49.7 天回绕——`tick_elapse` 通常已处理回绕【推断】；跨超长周期（>24 天）的判断自己用差值算法。

---

# 第四部分 uart、平台全局函数与 sys 任务框架

## 4.1 uart 串口库

```lua
uart = require("uart")
uart_no = uart.get_default_index()          -- 【代码确证】main.lua:6
```

| 函数 | 说明 | 代码确证 |
|---|---|---|
| `uart.get_default_index()` | 返回默认串口号（本项目=8pin 通信口） | main.lua:6 |
| `uart.send(uart_no, data)` | 发送字符串（字节流） | modbus.lua:428 |
| `uart.receive(uart_no, max)` | 收数据，返回 `res, data`；`res>0` 时 `data` 为收到的串 | modbus.lua:270 |

**接收的标准写法**（半包处理三段式）：

```lua
local res, data = uart.receive(uart_no, 10)   -- ① 拿本次到达的字节
if res > 0 then
    buffer = buffer .. data                   -- ② 累积进缓冲区
    while #buffer >= 需要的长度 do             -- ③ 收够一帧才处理
        local frame = string.sub(buffer, 1, N)
        buffer = string.sub(buffer, N + 1)    -- 处理完扔掉
        handle(frame)
    end
end
```

串口是字节流，**一帧可能分多次到达**，务必累积缓冲（本项目 `modbus.lua` 的完整状态机实现可直接参考）。

## 4.2 平台全局函数

| 函数 | 说明 |
|---|---|
| `msleep(ms)` | 毫秒延时（阻塞）——**只在调度器空转循环里用**（sys.lua:82 用它防空转），任务里请用 `sys.wait` |
| `print(...)` | 打印到调试口，是本平台**唯一内置调试手段**（无断点调试器时靠它） |

## 4.3 sys 任务框架 API

`sys = require("sys")`（本目录 sys.lua，可直接复用到新项目）：

| 函数 | 说明 | 类比 |
|---|---|---|
| `sys.taskInit(fn)` | 创建任务（fn 协程体） | `xTaskCreate` |
| `sys.wait(ms)` | 非阻塞延时（让出 ms 毫秒） | `vTaskDelay` |
| `sys.add_timer(ms, cb)` | ms 毫秒后执行一次 cb | 软定时器 |
| `sys.subscribe(event, cb)` / `sys.publish(event, ...)` | 事件订阅/发布 | 消息队列 |
| `sys.scheduler()` | 主调度循环（**永不返回**，放 main 末尾） | idle loop |

**事件机制用法**（解耦模块的好手段）：

```lua
sys.subscribe("alarm", function(level)      -- 订阅方
    jgus.screen_set_page(11)
end)
sys.publish("alarm", 1)                     -- 任意处发布
```

## 4.4 ★ 调度原理与"系统跑飞"铁律

**调度器在做什么**（sys.lua:56-84）：

```
while true do
    for 每个任务 do
        if 任务挂起中 then coroutine.resume(唤醒它) end   -- 任务跑到 sys.wait 处返回
        if 任务结束了 then 从表里删除 end
    end
    检查定时器到期 → 执行回调
    msleep(2)      -- 空转让出，防 100% 占用
end
```

**三条铁律**（违反任何一条 → 卡死/跑飞）：

1. **任务里必须周期性 `sys.wait()`**
   ```lua
   -- ❌ 死循环不让出：其他任务全部饿死，喂不上看门狗，系统跑飞
   while true do scan(); end
   -- ✅
   while true do scan(); sys.wait(30); end
   ```
2. **不能在任务里忙等延时**（`while tick_elapse(t)<3000 do end` 同样不让出）——判断型等待必须包在带 `sys.wait` 的循环里
3. **`init()` 这类顶层代码要快**——它在调度器启动前同步执行，里面不能做长时间等待

**周期选择参考**：按键扫描 10~50ms；显示刷新 100~500ms；定时逻辑 1000ms；串口轮询 5~20ms。

---

# 第五部分 三大数据通路

## 5.1 屏幕通路（VP 变量空间）

### 5.1.1 底层协议（官方手册 P23-25）

串口参数：**115200bps（默认）、8N1、帧头 5A A5、多字节高字节在前**；CRC-16 可选（Config.txt R2.4 开关）。

```
帧 = [5A A5][长度1][指令1][数据 ≤249][CRC2 可选]
     长度 = 指令+数据(+CRC)
指令：0x82 = 写变量空间   0x83 = 读变量空间
```

示例（官方 P25）：

```
写：5A A5 05 82 10 00 00 02       → 向地址 0x1000 写入 2
读：5A A5 04 83 10 00 01          → 从 0x1000 读 1 个字
应：5A A5 06 83 10 00 01 00 02    → 返回值 2
```

**你不需要手写这些帧**——`jgus.vp_write/vp_read` 就是它们的封装。了解协议的价值：调试时用串口助手抓包能看懂、`vp_write` 失败时知道去查什么。

### 5.1.2 系统接口地址表（官方手册第四章 P30-38 摘要）

**用户变量从 0x1000 起分配；0x0000~0x0FFF 是系统接口区**。

| 地址 | 名称 | R/W | 说明 |
|---|---|---|---|
| 0x0004 | System_Reset | W | 写 0x55AA/5AA5 触发软复位 |
| 0x000F | Version | R | 系统版本号 |
| **0x0010~0x0013** | **RTC** | R | **当前时间**：年/月/日/星期/时/分/秒（每 Word 装 2 字段，高字节在前） |
| 0x0014 | PictureNow | R | 当前页面索引 |
| 0x0016 | TP_Status | R/W | 触摸状态与坐标（写≠0x5A 清标记） |
| 0x0031 | LED Lumen | R | 当前背光亮度 0x00~0x3F |
| 0x007A / 0x007B | LCD_HOR/VER | R | 水平/垂直分辨率 |
| 0x0080 | System Config | R/W | CRC 使能、伴音、显示方向等系统配置 |
| **0x0084** | **Picture Set** | R/W | **页面切换**：D3=0x5A 启动、D2=0x01 切换模式、D1:D0=页号（写 `0x5A01|页号`） |
| 0x009C | RTC Set | W | 写 0x5AA5 + 年月日时分秒 设置 RTC |
| 0x00A0 | Audio/Buzzer | R/W | 蜂鸣器/音乐播放（如 `5A A5 05 82 00A0 007D` = 鸣叫） |
| 0x00B0~0x00D3 | 触控指令访问 | W | 程序化开启/关闭/读取某条触控指令 |

### 5.1.3 按键输入怎么做（对接"按键值返回"控件）

屏幕侧（官方 6.8，P63）：在屏幕工程给控件配**键码 + 目标 VP 地址 + 数据类型**。按下时屏幕自动把键值写入该 VP（通过 0x83 触控返回上传，Lua 用 `vp_read` 即可读到）。

Lua 侧三步：

```lua
local key = jgus.vp_read(0x1000)      -- ① 读键值（0=没按）
if key ~= 0 then
    dispatch(key)                      -- ② 分发处理
    jgus.vp_write(0x1000, 0)           -- ③ ★清零，否则一直读到旧键值
end
```

**设计约定**（本项目实践）：
- 所有屏幕按键共用一个 VP（0x1000），靠**键值编号**区分功能（0x01=开始、0x02=暂停…）
- 键值用小整数（1~N），预留 0 表示"无输入"
- 处理完毕必须清零——这是最容易忘的一步

### 5.1.4 输出显示的两种控件

| 需求 | 屏幕控件 | Lua 写法 |
|---|---|---|
| 数字（计数、状态码、进度） | 数据变量显示（0x10） | `vp_write(addr, n)` |
| 文本（时间串、消息） | 文本显示（0x11） | `vp_write_string(s, addr)` |

绑定规则：**控件的 VP 地址 = 你代码里读写的地址**，两边必须一致（屏幕工程里查）。

## 5.2 EPROM 存储通路

- **用途**：断电要记住的东西（计数、配置、记录）。屏幕断电丢、VP 断电丢，只有它活着
- **用法**：见 3.5；本项目存"使用记录环形缓冲"（10 条 × 80 字节）是范例
- **设计要点**：
  1. 数据+元数据（条数、写指针、校验）一起存，上电恢复
  2. 写入带长度前缀或固定格式，读出先**格式校验**再用（本项目用 `string.find(s, "\"start_time\":")` 探测有效性）
  3. 关键状态不要存太频繁（擦写寿命），写变化沿而不是每个周期都写

## 5.3 Modbus（外设）通路

完整实现见 `modbus.lua`，使用就两个函数：

```lua
-- 发（5 个参数：从站、功能码、地址、数量或值、数据数组）
modbus.sendModbusCommand(1, 0x05, 0x0000, 0xFF00, {0})   -- 写线圈=ON
modbus.sendModbusCommand(1, 0x04, 0x0032, 0x0001, {0})   -- 读输入寄存器×1

-- 收（后台任务轮询，状态机组帧 + CRC 校验 + 解析）
modbus.start_modbus_task()
```

要点速记：
- 0x05 写线圈：第 4 参数 `0xFF00`=ON / `0x0000`=OFF
- 0x03/0x04 读：响应 `result.data[1..n]` 是 16 位寄存器数组
- 半包、粘包、CRC 失败重同步，`modbus.lua:269-381` 已处理好，直接复用
- 发送不等待响应、靠周期重发保证可靠；配置类命令建议等响应确认（见项目对话笔记）

---

# 第六部分 实战配方（可直接复制）

> 以下均假设已 `require` sys/jgus；任务代码放在 `sys.scheduler()` 之前注册。

### 配方 1：开机延迟 N 秒切换页面

```lua
sys.taskInit(function()
    sys.wait(3000)                 -- 让出 CPU 等 3 秒（不是忙等）
    jgus.screen_set_page(1)        -- 切到 1 号页（开机动画→主界面）
end)
```

### 配方 2：按键扫描任务（30ms 周期 + 清零）

```lua
sys.taskInit(function()
    while true do
        local key = jgus.vp_read(0x1000)
        if key ~= 0 then
            if key == 1 then      -- 开始
                start_run()
            elseif key == 2 then  -- 暂停
                pause_run()
            elseif key == 3 then  -- 停止
                stop_run()
            end
            jgus.vp_write(0x1000, 0)    -- ★处理完必须清零
        end
        sys.wait(30)
    end
end)
```

### 配方 3：数值显示刷新

```lua
local function show_number(addr, n)
    jgus.vp_write(addr, n)
end
-- 用法（0x1101/0x1102/0x1103 绑定 时/分/秒 数据变量显示控件）
show_number(0x1101, hours)
show_number(0x1102, minutes)
show_number(0x1103, seconds)
```

### 配方 4：文本显示（含清空）

```lua
jgus.vp_write_string("运行中", 0x2000)   -- 显示
jgus.vp_write(0x2000, 0x0000)            -- 清空（短覆盖长时先清）
```

### 配方 5：1 秒倒计时任务

```lua
sys.taskInit(function()
    while true do
        if run_state == 1 then
            if sec > 0 then
                sec = sec - 1
            elseif min > 0 then
                min = min - 1; sec = 59
            elseif hour > 0 then
                hour = hour - 1; min = 59; sec = 59
            else
                stop_run()          -- 时间到
            end
            jgus.vp_write(0x1102, min)
            jgus.vp_write(0x1103, sec)
        end
        sys.wait(1000)
    end
end)
```

### 配方 6：读取屏幕 RTC 生成时间戳

```lua
local function now_string()
    local y = 2000 + jgus.vp_read_high_byte(0x0010)
    local mo = jgus.vp_read_low_byte(0x0010)
    local d = jgus.vp_read_high_byte(0x0011)
    local h = jgus.vp_read_high_byte(0x0012)
    local mi = jgus.vp_read_low_byte(0x0012)
    local s = jgus.vp_read_high_byte(0x0013)
    return string.format("%04d-%02d-%02d %02d:%02d:%02d", y, mo, d, h, mi, s)
end
```

### 配方 7：非阻塞时序（先开 A，3 秒后开 B；停机后 B 先关、A 延时关）

```lua
local start_t = nil
sys.taskInit(function()
    while true do
        if run_state == 1 then
            if not start_t then start_t = jgus.tick_get() end
            if jgus.tick_elapse(start_t) >= 3000 then fire_on() end
        else
            fire_off()
            start_t = nil
        end
        sys.wait(30)
    end
end)
```

### 配方 8：断电保存 + 上电恢复（计数器）

```lua
-- 上电恢复
local b = string.rep("\0", 4)
jgus.eprom_read(b, 0, 4)
local count = 0
for i = 1, 4 do count = count * 256 + string.byte(b, i) end   -- 大端拼 32 位

-- 变化时保存
local function save_count(v)
    local s = string.char((v >> 24) & 0xFF, (v >> 16) & 0xFF,
                          (v >> 8) & 0xFF, v & 0xFF)
    jgus.eprom_write(s, 0, 4)
end
```

### 配方 9：故障检测 → 报警 + 跳故障页 + 强制停机

```lua
-- 每 130ms 轮询从站输入口（0x04 读输入寄存器）
local v = modbus_response_data[1]          -- 解析后的 16 位状态字
if (v & 0x07) > 0 then                     -- bit0/1/2 任一故障
    alarm_on()                             -- 打开报警输出
    if (v & 0x01) == 1 then                -- 急停
        jgus.screen_set_page(11)
    elseif (v & 0x02) == 2 and run_state ~= 0 then
        jgus.screen_set_page(10)            -- 风扇异常（仅运行中才报）
    end
    run_state = 0                          -- 无条件停机
else
    alarm_off()
end
```

### 配方 10：周期刷新显示（节流）

```lua
sys.taskInit(function()
    while true do
        jgus.vp_write(0x1200, read_sensor())   -- 500ms 刷一次，别每个周期都写
        sys.wait(500)
    end
end)
```

### 配方 11：蜂鸣器 / 背光（系统接口直写）

```lua
jgus.vp_write(0x00A0, 0x007D)   -- 蜂鸣器鸣叫（官方 P35 示例）【推断：经 vp_write 发 0x82】
jgus.vp_write(0x0031, 0x20)     -- 背光亮度（0x00~0x3F，R 为主，配置以手册为准）
```

### 配方 12：软复位屏幕

```lua
jgus.vp_write(0x0004, 0x55AA)   -- 系统软复位（官方 P30）
```

---

# 第七部分 调试排错与新项目 Checklist

## 7.1 调试手段

| 手段 | 怎么用 |
|---|---|
| `print(...)` | 唯一内置调试输出；在关键分支、任务入口打印 |
| 串口助手抓包 | 监听屏幕串口看 `5A A5` 帧是否正常发出/应答（协议见 5.1.1） |
| 屏幕侧回显 | 把内部变量 `vp_write` 到一个"调试文本框"，直接在屏上看 |
| 分阶段点亮 | 每加一个功能先单独验证（见 1.4 三步验证） |

## 7.2 常见故障速查

| 症状 | 可能原因 | 排查 |
|---|---|---|
| 上电没反应/卡死 | 任务里忙等没 `sys.wait`；`init()` 里有长等待 | 检查所有 `while` 循环 |
| 屏幕按键读不到 | 控件 VP 与代码地址不一致；没清零；键值类型（VType）不匹配 | 查屏幕工程 VP、读到值后是否 `vp_write(…,0)` |
| `vp_write` 不生效 | 页号/地址不存在；控件类型不匹配（数字写给了文本 VP） | 核对官方 P34"页面不存在则不生效"；查控件类型 |
| 文本显示乱码 | 编码方式（ASCII/GBK）与字库不符 | 查文本控件 Encode 字段（官方 P101） |
| 读 EPROM 得到脏数据 | 缓冲区没预分配/长度不够；写入格式变了 | `string.rep("\0", len)` 三行套路；写入加格式校验 |
| 串口收到的数据解析乱 | 半包没累积；缓冲区没及时清；两个协议共用串口未 `disable_serial_receive()` | 复用 modbus.lua 状态机；检查 3.7 |
| 跑一段时间随机死机 | 任务不让出（同上）；GC 压力（循环大量拼串） | 攒 table + `table.concat`；减少临时大串 |
| 断电后数据丢 | 忘了 eprom_write；写太频繁踩寿命 | 关键状态变化沿才写，写后读回校验 |

## 7.3 新项目开发 Checklist

**阶段 0：准备（0.5 天）**
- [ ] 拿到屏幕工程（或用官方上位机新建）、确认页面清单与 VP 地址表
- [ ] 确认串口参数：波特率、帧头、CRC 开关（Config.txt，官方 5.5）
- [ ] 确认外设协议（Modbus 站号/寄存器表 或 其他）

**阶段 1：框架落位（0.5 天）**
- [ ] 复制四件套：`sys.lua` `modbus.lua` `crc16.lua` `json.lua`（按需）
- [ ] 写 `main.lua` 骨架（1.3 节）：require → init → 任务注册 → `sys.scheduler()`
- [ ] 所有任务带 `sys.wait`，确认无忙等

**阶段 2：三步验证（1 天）** ← 最小可用里程碑
- [ ] ① 屏幕工程 SD 下载，显示正常
- [ ] ② 按键通路：屏幕按键 → `vp_read` → 回显/清零
- [ ] ③ 外设通路：发一条命令，执行器动作
- [ ] 抓包确认 `5A A5` 帧格式正确

**阶段 3：业务功能（按需）**
- [ ] 显示通路：数字/文本控件绑好 VP，刷新节流
- [ ] 状态机：运行/暂停/停止 + 时序保护（tick_get/elapse）
- [ ] 故障处理：轮询硬件状态 → 报警 → 跳页 → 停机（安全优先）
- [ ] 断电保存：EPROM 布局设计（含元数据与校验），上电恢复

**阶段 4：验证（1~2 周）**
- [ ] 异常注入：拔线、断电、乱码、按键狂按、长稳 48h
- [ ] 上电状态必安全（停止态、输出全关）
- [ ] 代码评审：全局变量清单、地址魔数抽配置表、注释交接文档

## 7.4 移植/扩展提示

- **换机型**：地址、键码、页面号抽成配置表（文件顶部集中定义），别散落在代码里
- **换协议**：只替换 `modbus.lua`，`sys/jgus` 层不动
- **加记录页**：环形缓冲 + 分页显示参考 `main.lua` 的 `print_log()`
- **多语言**：官方 0x004F Language_Set + 标签控件（P31），或后台切 ICO

---

# 第八部分 项目实战经验（倒计时/联动复盘）

> 本部分是等离子治疗仪项目（main.lua）迭代开发的真实经验总结，代码模式均可直接复制。

## 8.1 倒计时显示：十位 + 个位拆分显示

**场景**：屏幕上的倒计时显示控件是**逐位独立**的（每个"数位"一个控件、一个 VP），而不是一个控件显示整串数字。

**做法**：秒数拆成十位、个位分别写两个 VP：

```lua
-- 分钟一个控件、秒拆两位（0x3101=分 0x3102=秒十位 0x3103=秒个位）
jgus.vp_write(0x3101, minute)
jgus.vp_write(0x3102, math.floor(second / 10))   -- 十位：67 → 6
jgus.vp_write(0x3103, second % 10)               -- 个位：67 → 7
```

**要点**：
- 更多位同理：`math.floor(n / 100) % 10` 取百位，或循环 `digit = math.floor(n / 10^k) % 10`
- 拆分公式对 0~59 的秒天然有效；分钟若可能 ≥100，同样拆十位/个位
- **串口上报不要拆**：发给人看的用 `string.format("%02d:%02d\n", minute, second)` 一次发整串，方便上位机直接解析
- 反向需求（屏幕控件只认整数显示一个字段）就整数直写，别拆

## 8.2 多功能共用一套倒计时：配置表 + 单引擎

**场景**：A面膜/B面部手具/C负离子三个功能流程完全一样（开始→倒计时→结束），只差按键地址、时长地址、页面号。

**做法**：差异全部进配置表，逻辑只写一份：

```lua
local funcs = {
    { key = 0x1105, time = 0x1102, run_page = 4, base_page = 1, power = mask_power },
    { key = 0x1204, time = 0x1203, run_page = 5, base_page = 2, power = tool_power },
    { key = 0x1302, time = 0x1301, run_page = 6, base_page = 3, power = ion_power },
}
local run_func  = 0    -- 当前运行的功能下标（0=无）
local run_state = 0    -- 0=停止 1=运行
```

```lua
-- 按键任务：轮询三个按键 VP
for i = 1, 3 do
    local f = funcs[i]
    local key = jgus.vp_read(f.key)
    if key == 1 and run_state == 0 then   -- 开始：只在停止态允许
        ...
    elseif key == 2 and run_func == i then -- 结束：只认当前运行功能的键
        ...
    end
end
```

**要点**：
- **同时只有一个功能在跑**是这套引擎的前提，`run_state==0` 才允许开始（运行中按别的功能开始键直接忽略）
- **结束键必须校验 `run_func == i`**：运行中按其他功能的结束键不响应，防止误停
- 加第 4 个功能 = 表里加一行，逻辑零改动

## 8.3 启动清零冗余（状态对齐）

每次开始时**先把三个功能状态变量全归 0，再把当前功能置 1**——宁可多清一遍，也不信"上次结束时清干净了"：

```lua
if run_state == 0 then
    facial_mask_state = 0
    faicialTool_state = 0
    negative_ion_state = 0
    set_func_state(i, 1)
    minute = jgus.vp_read(f.time)   -- 时长每次从 VP 重读（屏幕可能刚改过）
    second = 0
    send_tick = 0                   -- 上报计数也清
    jgus.vp_write(0x3101, minute)   -- 显示立即对齐
    jgus.vp_write(0x3102, 0)
    jgus.vp_write(0x3103, 0)
    ...
end
```

**理由**：功能之间互斥运行时，残留状态是串扰的唯一来源；启动点做一次"全量对齐"成本极低、收益极大。

## 8.4 定时中切页即停（外部干预兜底）

**场景**：用户在运行页上通过其他控件跳走了（或屏幕异常），定时还继续跑 = 输出失控。

**做法**：倒计时每秒先查当前页，页号变了立即停（**不代切页**，用户已经在别处）：

```lua
if run_state == 1 then
    if run_func == 0 or jgus.vp_read(0x0014) ~= funcs[run_func].run_page then
        run_state = 0
        stop_current_func()          -- 只停不定，不动用户的页
    else
        -- 正常递减/显示/上报逻辑
    end
end
```

**要点**：
- `0x0014` = PictureNow 当前页（系统接口只读），每秒读一次开销可忽略
- `run_func == 0` 兜底：状态机被外部清过时 `funcs[0]` 会越界（返回 nil 再索引 = 报错）
- 刚 `screen_set_page` 后的 1 秒内页号可能未更新，首轮 tick 会误判——实际切页指令走串口立即生效，1 秒窗口足够，若遇到可把首轮检查跳过（`send_tick==0 时先不查`）

## 8.5 多个结束出口 → 统一收尾函数

三个结束路径（按键结束 / 时间到 / 切页停止）必须做同样的事，抽成一个函数：

```lua
local function stop_current_func()
    if run_func == 0 then return end        -- 兜底：重复停止不报错
    set_func_state(run_func, 0)
    funcs[run_func].power(false)            -- 本功能关闭（含串口上报）
    if mask_follow then                     -- A5 跟随的面膜一并关
        mask_power(false)
        mask_follow = false
    end
    run_func = 0
end
```

**★ 顺序坑**：需要回基础页时**先把页号取出来存局部变量，再调 stop**——stop 里会把 `run_func` 清 0，之后 `funcs[run_func]` 就取不到页了：

```lua
local base_page = funcs[run_func].base_page   -- ① 先取
run_state = 0
stop_current_func()                           -- ② run_func 在这里变 0
jgus.screen_set_page(base_page)               -- ③ 用存好的值
```

## 8.6 外部信号联动（A5 面膜跟随启动 + 自动关）

**场景**：0x4400==0xA5 时，B/C 功能开始定时，面膜**跟着一起启动**；A5 信号消失，跟随的面膜**自动关闭**；面膜单独定时不受 A5 影响。

**做法**：跟随标志 `mask_follow` + 三个挂载点：

```lua
-- ① 启动时（仅 i~=1 才可能跟随，单独启动 A 不置 follow）
f.power(true)
if i ~= 1 and jgus.vp_read(0x4400) == 0xA5 then
    mask_power(true)
    mask_follow = true
end

-- ② 结束收尾里（stop_current_func 内）
if mask_follow then mask_power(false); mask_follow = false end

-- ③ A5 消失自动关（挂在已有 0x4400 周期任务里，不另开任务）
if mask_follow and reg ~= 0xA5 then
    mask_power(false)
    mask_follow = false
end
```

**要点**：
- `mask_follow` 区分"跟随开的"与"自己开的"——A5 消失只关跟随的，不影响单独定时的面膜
- 检测信号消失用**周期任务里的边沿判断**（上一拍是 A5 这一拍不是），100ms 轮询足够及时
- 联动状态必须有标志位，否则"谁开的、该不该关"会在多处出口互相打架

## 8.7 占位函数 + 串口上报内聚

**场景**：硬件输出逻辑还没实现，但要先把调用骨架和上报协议定下来。

**做法**：上报写在占位函数**内部**，所有调用点自动带上报：

```lua
local function mask_power(on)
    uart.send(uart_no, on and "mask_power_on\n" or "mask_power_off\n")
    -- TODO: 未来真正的输出控制写这里
end
-- funcs 表挂 power 字段，按键/收尾统一调 f.power(true/false)
```

**要点**：
- 单独启动 A 也会发 `mask_power_on/off`——任何面膜开关动作都上报，上位机日志完整
- 未来接硬件 = 在函数体里加控制代码，**调用点一行不用改**
- 开关字符串命名成对（`mask_power_on` / `mask_power_off`），上位机用前缀匹配即可分拣

## 8.8 串口上报的三种内容（本项目协议范例）

| 内容 | 格式 | 时机 |
|---|---|---|
| 功能开关 | `mask_power_on\n` / `tool_power_off\n` … | 启动/结束各一次 |
| 倒计时剩余 | `%02d:%02d\n`（MM:SS） | 每 5 秒一次（`send_tick` 节流） |
| （预留）状态/故障 | 自定义行协议 | 按需 |

**节流技巧**：秒任务里累加 `send_tick`，到 5 才发并清零——避免每秒刷屏、也给上位机留解析间隔。

## 8.9 任务周期选型（本项目实测值）

| 任务 | 周期 | 理由 |
|---|---|---|
| 按键扫描 | 30ms | 及时响应 + VP 读是串口往返，太快会占带宽 |
| 倒计时 | 1000ms | 秒级精度；每轮含 1 次读页 + 3 次写显示 |
| 0x4400/0x2000 状态 | 100ms | 信号联动（A5 消失）要较快响应 |
| 开屏跳页 | 一次性 3000ms | 只跑一次，`sys.wait` 后不进 while |

## 8.10 参考工程思想与两派对比（来自 `参考\main-ASCII显示正常.lua`）

> 他人成熟版架构：**协议网关**——Lua 夹在屏幕与上位机之间，状态双向镜像；本项目架构：**单脑自治**——Lua 自管状态机，串口只发不收做遥测。以下思想按需吸收，对比只列利弊不选边。

### 值得吸收的 6 条思想

1. **全量状态镜像**：`TreatmentTable` 单一结构体集中存全部状态，每次变化整体发一帧上报；上位机也能反向 `write_config` 下发覆盖（切页/启停/参数）→ "状态变更即上报、协议双向"模式。本项目当前是只发不收，将来若要上位机接管，帧模型可直接参考附录 F-2。
2. **FunctionKey/FunctionValue 二级编码**：一条固定格式通用帧用"控件号+值"承载所有事件（1=启停、2=模式、4=强度…），帧结构不随功能膨胀——加新功能只扩键号表，不改帧格式。
3. **进页全量初始化**（`ZhuangT_init`）：每次进页把模式/强度/时长/状态显示全回默认。与本项目"启动时清零冗余"互补——**本项目当前行为=记住用户设置，参考版=每次进页重置，这是产品行为选择不是对错**。若要改成重置，在"检测到切页进入 run_page"的分支里补全量初始化即可（咽喉点仍单条）。
4. **裸键值屏 vs 智能控件屏**：参考屏只出裸键值（0x1010/0x101A…），加减限幅全在 Lua（8 个复制粘贴的 Key_Config）；本项目屏自带增量调节控件，Lua 只读终值 → **双方代码量差异的根因在屏幕工程分工，不在编码水平**。
5. **地址复用 vs 每页独立地址**（保留意见，只列利弊）：
   | | 地址复用（参考版） | 每页独立地址（本项目） |
   |---|---|---|
   | 优点 | 省 VP 号、按键任务少读一半地址、帧里靠页号上下文解码 | 页间天然隔离，无串扰风险，代码无需页号分支 |
   | 缺点 | 切页瞬间旧键值残留可能误触发，必须每键清零兜底 | 占 VP 号，三功能三套地址 |
6. **帧头反序规避冲突**：参考版帧头 `A5 5A`（JGUS 协议是 `5A A5`）+ `disable_serial_receive()` → 同一串口跑两种协议的隔离思路（本项目串口只连屏所以不需要）。

### 反面清单：照抄参考版前必改的 5 个坑

| # | 位置 | 问题 |
|---|---|---|
| 1 | 523/671 行 | `MpaValue` **未定义**（应为 `MpaValueA`）→ `string.char(unpack)` 收到 nil 会炸 |
| 2 | 75-76 行 | `Page2_KS` **定义两次**，第二次把第 3 页的帧覆盖进第 2 页变量（`Page3_KS` 缺失） |
| 3 | 514 行 | `buf[6] > 0 or buf[6] < 4` **恒真**，`or` 应为 `and` |
| 4 | 469 行 | `jgus.screen_get_page()` **API 不存在**，应用 `jgus.vp_read(0x0014)` |
| 5 | 455/459 行 | `Countdown()` 内 `local ticks` 每次进函数重置，`ticks`/`seconds` 是死代码 |

---

# 第九部分 AI 协作开发指南（写给 AI 看的项目导读）

> 本部分记录"AI 如何快速读懂本项目、如何与开发者高效协作"。人也可以看，但主要读者是接手本项目的 AI 助手。
> 当你（AI）第一次进入这个项目时，按本部分的顺序读，可以在几分钟内恢复全部上下文。

## 9.1 项目地图：先读什么、后读什么

```
D:\Project\dong\LUA\pratice_project\
├── main.lua                    ← ★唯一被反复修改的文件，业务逻辑全在这
├── JGUS开发手册.md              ← 本文件：API + 配方 + 经验 + 项目导读
├── uart 模块 API 文档.md         ← uart 库速查
├── sys.lua / json.lua           ← 框架，不改
├── practice2/
│   ├── project.json             ← ★屏幕工程源（单行 JSON）：页面/控件/VP 的唯一权威
│   └── DD_SET/main.lua          ← 部署拷贝（旧版！改完 main.lua 后需手动覆盖它再烧录）
```

**推荐阅读顺序**（新 AI 上下文恢复）：
1. 读本文件第八部分（实战经验）→ 知道已做了什么、为什么这么做
2. 读 `main.lua` 全文（200 行以内）→ 当前真实状态
3. 需要屏幕侧信息时才打开 `practice2/project.json` → 查 VP/页面
4. 遇到 API 语义疑问 → 第三/四部分；要抄成熟模式 → 第六部分

## 9.2 怎么通过读屏幕工程 JSON 理解用户意图

**背景**：用户的口头需求通常只说"业务语言"（如"面膜功能 30 秒倒计时"），屏幕工程 JSON 才是把业务映射到 VP 地址的字典。AI 的核心解码方法：

### step 1：JSON 是单行的——别用逐行 Read

`project.json` 是**一行 5 万+ 字符**的压缩 JSON，Read 工具读出来没有结构。用正则抽取关键字段：

```powershell
# 抽取所有控件的 name/type/variable_pointer 三元组（PowerShell + regex）
$j = Get-Content '.\practice2\project.json' -Raw
[regex]::Matches($j, '"name":"([^"]*)","type":"([^"]*)"[^}]*?"variable_pointer":"([0-9A-Fa-f]+)"') |
  ForEach-Object { "{0,-24} {1,-10} VP=0x{2}" -f `
      $_.Groups[1].Value, $_.Groups[2].Value, $_.Groups[3].Value }
```

### step 2：识别三类关键字段

| 字段 | 含义 | 用途 |
|---|---|---|
| `name` | 控件名（用户在上位机里起的中文名，如"键值返回""增量调节"） | **业务语义就在名字里**："键值返回"=按键 VP，"增量调节"=加减调节控件，"艺术字变换"=数字显示控件 |
| `type` | 控件类型：`touch`=触控/按键，`display`=显示 | touch 的 VP 是**读+清零**，display 的 VP 是**写** |
| `variable_pointer` | 控件绑定的 VP 地址（4 位 hex 字符串，**无 0x 前缀**） | 代码里 `vp_read/vp_write` 的地址 |

### step 3：用"同地址控件聚类"还原功能设计

同一个 VP 常被**多个控件共享**——这是理解用户设计的关键信号：

```text
"增量调节" touch   VP=1102   ┐ 同一地址：触控写入（用户加减设置）
"艺术字变换" display VP=1102  ┘ 显示回显（屏幕自动回显，无需 Lua 参与）
→ 推断：0x1102 是"设置值"，Lua 只需在开始定时那一刻 vp_read 它
```

```text
"键值返回" touch   VP=1105   → 用户按"开始"，屏幕写 1；按"结束"，写 2
"变量图标" display  VP=2000   → Lua 周期写 0/1/2 控制图标显隐
```

### step 4：页面名 = 功能页映射

页面在 JSON 里带中文名（如 `"1-A面膜功能基础界面"`、`"2-B面部手具功能基础界面"`），直接得到**页面号 → 功能**映射表。把每个页里的 VP 按 step 3 聚类，就能画出完整的"每功能一页、结构对称"的格局——用户说"三个功能都要能定时"时，对称的 VP 结构（1105/1204/1302、1102/1203/1301、页4/5/6）会自己浮出来。

### step 5：发现"缺件"并主动告知用户

对照 JSON 和需求，找出**屏幕侧还没做的东西**（如：页 5/页 6 没有 3101~3103 的显示控件）。结论写进计划：**"写入无害，用户后续加控件绑同地址即可"**——既不阻塞开发，也把窟窿标出来。

**口诀**：业务名 → 找"键值返回/增量调节"控件 → 定 VP → 聚类同址控件分清读/写 → 页面名定功能 → 对照需求找缺口。

## 9.3 AI 与用户的协作工作流（本项目验证有效的节奏）

```text
用户提需求（业务语言，可能有歧义）
  → AI 先读 main.lua 确认当前真实状态（用户会手改文件！以磁盘为准）
  → 有歧义先提问（见 9.4），别猜
  → 更新计划文件（写具体到行号的 diff 方案）
  → 简短呈现计划（要点+行为矩阵），等用户说"确认/执行"
  → 执行编辑 → 重读全文自检
  → 简报改了什么（带 main.lua:行号 引用）
```

**关键纪律**：
1. **每次编辑前重读 main.lua**——用户会在两轮之间手改文件（改轮询周期、注释掉 API 调用），以磁盘内容为准，不要凭上一轮记忆编辑
2. **计划先行**：改动涉及多处联动时，先写计划文件再动手；用户明确说"确认"才执行
3. **改完必须通读**：验证 nil 越界、顺序坑（如先清 run_func 再取页号）、每个结束出口是否都走了统一收尾
4. **状态改动给出行为矩阵**：新特性列出"场景 → 结果"表，用户扫一眼就知道对不对
5. **保留用户资产**：用户定义的变量（哪怕暂时没用）、用户注释掉的代码（如 `disable_serial_receive`）一律不动

## 9.4 需求歧义先问再做（实例）

用户原话："0x4400=a5 时面膜功能常开"——字面有三种理解（输出常开无倒计时 / 独立倒计时并行 / 信号期间允许伴随启动）。AI **没有猜**，用选择题问了三个问题（A5 含义 / A5 消失怎么办 / 空函数调用时机），用户一句话纠正了理解："别的模式开始定时他也一起跟着启动"。

**教训**：
- 关键词"常开""一起""跟随"这类词在硬件语境有歧义 → 用**带选项的提问**（不是开放问答）快速收敛
- 选项要给**推荐项**并排在第一位，用户"默认同意"成本最低
- 问 2~4 个、每个 ≤3 选项，别一次问倒用户

## 9.5 修改验证清单（AI 自检用）

编辑 `main.lua` 后按序过一遍：

- [ ] `run_func`/`run_state` 所有写点是否成对（每个 `power(true)` 是否有对应 `power(false)` 路径）
- [ ] 取 `funcs[run_func]` 前 `run_func` 是否保证非 0（先存局部变量再清 0）
- [ ] 任务里所有 `while true` 是否带 `sys.wait`
- [ ] 按键 VP 读到非零处理后是否清零
- [ ] 新增标志位（如 `mask_follow`）是否在**所有**停止路径上被复位
- [ ] 串口上报是否只发不收（本项目约定：不建接收任务）

## 9.6 文档本身的写作约定（让文档对 AI 友好）

- **代码标注三件套**：`【代码确证】main.lua:行号`（有代码验证）、`【推断】`（待厂商文档确认）——AI 引用时知道可信度
- **每个模式给可复制的完整代码块**，不给伪代码
- **行为用表格**（场景/结果），不用大段文字——AI 和人都能快速比对
- **文件行号引用用 `file_path:line_number` 格式**，方便直接跳转
- **约定写明理由**（"只发不收因为…"），AI 遇到新需求才知道哪些约束可以放松

---

# 附录

## 附录 A：本项目 VP 地址分配表（范例）

| 地址 | 用途 | 方向 | 说明 |
|---|---|---|---|
| 0x0010~0x0013 | 系统 RTC | 读 | 生成记录时间戳 |
| 0x1000 | 按键值 | 读+清零 | 所有按键共用，键值区分 |
| 0x1101 / 0x1102 / 0x1103 | 倒计时 时/分/秒 | 写 | 数据变量显示控件 |
| 0x1FFF+1~5 | 记录页行序号 | 写 | |
| 0x2010+(i-1)*0x40 | 第 i 行开始时间 | 写 | 文本显示控件 |
| 0x2030+(i-1)*0x40 | 第 i 行结束时间 | 写 | 文本显示控件 |

**按键键码表**（0x1000 的值）：

| 值 | 功能 | 值 | 功能 | 值 | 功能 |
|---|---|---|---|---|---|
| 0x01 | 开始 | 0x06 | 停止升降 | 0x0C | 60 分钟 |
| 0x02 | 暂停 | 0x07 | 5 分钟 | 0x0D | 使用记录 |
| 0x03 | 停止 | 0x08 | 10 分钟 | 0x0E | 上一页 |
| 0x04 | 下降 | 0x09 | 15 分钟 | 0x0F | 下一页 |
| 0x05 | 上升 | 0x0A | 20 分钟 | | |
| | | 0x0B | 30 分钟 | | |

## 附录 B：EPROM 布局范例（使用记录环形缓冲）

```
地址 0        : ur_num        记录条数 (0~10)
地址 1        : ur_write_num  写指针 (0~9)
每 80 字节一个槽（槽 i 基址 = i*80）：
  +0         : 未用/对齐
  +1         : 未用/对齐
  +2         : 该条 JSON 长度
  +3 ~ +71   : JSON 数据 (定长 69 字节)
  +72~ +79   : 余量
```

读写模式：写 = 先长度后数据；读 = 固定开 69 字节缓冲 + `string.find` 格式校验；指针到 9 后回绕到 0（覆盖最旧）。

## 附录 C：Modbus 帧速查

> 本附录是 **Lua 侧**（`modbus.lua`，主控发帧）的帧格式速查。**屏幕侧**（22.BIN 配置、屏幕自己当 Modbus 主机直连外设）的配置指南见《晶兴Modbus开发指南.md》（项目根目录）——两条路完全独立，别混淆。

```
请求（主→从）: [从站][功能码][数据…][CRC16 低字节在前]
响应（从→主）: 格式随功能码变化；异常 = 功能码|0x80 + 异常码（固定5字节）
```

| 功能码 | 含义 | 关键参数 |
|---|---|---|
| 0x01/0x02 | 读线圈/离散输入 | 起始地址 + 数量 |
| 0x03/0x04 | 读保持/输入寄存器 | 起始地址 + 数量（响应含字节数字段） |
| 0x05 | 写单线圈 | 地址 + 0xFF00=ON / 0x0000=OFF |
| 0x06 | 写单寄存器 | 地址 + 值 |
| 0x0F | 写多线圈 | 起始 + 数量 + 字节数 + 位数据 |
| 0x10 | 写多寄存器 | 起始 + 数量 + 字节数 + 字数据（请求9+N字节；响应固定8字节） |
| 异常 | 功能码+0x80 | 01非法功能 02非法地址 03非法值 04从站故障 |

CRC16：多项式 0xA001（反射），初值 0xFFFF，低字节在前。C 参考代码见官方 P29。

## 附录 D：Lua ↔ C 函数对照总表

| 用途 | C | Lua |
|---|---|---|
| 字节→数值 | `x = s[i]` | `string.byte(s, i)` |
| 数值→字节 | `s[i] = x` | `s .. string.char(x)` |
| 截取 | `memcpy(dst, s+i, n)` | `string.sub(s, i, j)` |
| 拼接 | `strcat / memcpy` | `a .. b` |
| 长度 | `strlen` | `#s` |
| 格式化 | `sprintf` | `string.format` |
| 清零缓冲 | `memset(buf,0,n)` | `string.rep("\0", n)` |
| 整除 | `a / b`（整型） | `math.floor(a / b)` |
| 位运算 | `a & b, a >> 2` | 5.3+ 原生同写法（或 crc16.band 等封装） |
| 延时 | `HAL_Delay / vTaskDelay` | `sys.wait`（任务内）/ `msleep`（调度空转） |
| 时基 | `HAL_GetTick()` | `jgus.tick_get()` |
| 开任务 | `xTaskCreate` | `sys.taskInit` |
| 模块 | `.h` + `.c` + 链接 | `require` + `return table` |

## 附录 E：官方手册关键页码索引

| 内容 | 页码 |
|---|---|
| 串口参数/帧结构 | P23 |
| 0x82 写变量 / 0x83 读变量 | P25 |
| RAM 变量空间总览 | P22 |
| 系统接口地址表（整章） | P30-38 |
| 页面切换 0x0084 | P34 |
| RTC 读 0x0010 / RTC 写 0x009C | P30 / P34 |
| 蜂鸣器 0x00A0 | P35 |
| 按键值返回控件 | P63 |
| 数据变量显示控件 | P96 |
| 文本显示控件 | P101 |
| CRC-16 C 参考代码 | P29 |
| Config.txt 配置 | P42-48 |

## 附录 F：参考工程可复用代码段（摘自 `参考\main-ASCII显示正常.lua`）

> 使用前注意 8.10 节"反面清单"——源文件有 5 处已知 bug，以下片段均已确认不含这些问题。

### F-1 CRC16 计算（纯位运算版，不依赖 crc16.lua）

```lua
local function Calculate_CRC16(data, len)
    local Reg_CRC = 0xFFFF
    for i = 1, len do
        Reg_CRC = Reg_CRC ~ data[i]                 -- ~ 异或（Lua 5.3+ 原生位运算）
        for j = 1, 8 do
            if (Reg_CRC & 0x0001) ~= 0 then
                Reg_CRC = (Reg_CRC >> 1) ~ 0xA001   -- 反射多项式 0xA001
            else
                Reg_CRC = Reg_CRC >> 1
            end
        end
    end
    return Reg_CRC
end
-- data 是字节数组（下标 1 起）；返回 16 位，发送顺序低字节在前需自行拆
```

### F-2 自定义帧收发骨架（A5 5A 帧 + CRC + 逐字节收帧状态机）

**组帧发送**（读命令 0xAF / 写命令 0xFA 同构，只是命令字节不同）：

```lua
local function build_frame(cmd, TreatmentTable)
    local buffer = {}
    buffer[1]  = 0xA5              -- 帧头（故意与 JGUS 的 5A A5 反序，避免同串口撞帧）
    buffer[2]  = 0x5A
    buffer[3]  = cmd               -- 0xAF=读 0xFA=写
    buffer[4]  = TreatmentTable.Voice
    buffer[5]  = TreatmentTable.Language
    buffer[6]  = TreatmentTable.Screen
    buffer[7]  = TreatmentTable.FunctionKey
    buffer[8]  = TreatmentTable.FunctionValue
    buffer[9]  = TreatmentTable.When
    buffer[10] = TreatmentTable.Minutes
    buffer[11] = TreatmentTable.Seconds
    local crc = Calculate_CRC16(buffer, 11)
    buffer[12] = crc >> 8         -- 高字节
    buffer[13] = crc & 0xFF       -- 低字节
    uart.send(uart_no, string.char(table.unpack(buffer)))
end
```

**逐字节收帧状态机**（半包/粘包安全，帧头识别→攒满→CRC 校验→分发）：

```lua
local cmdbuf, cmdcount, cmdflags = {}, 0, 0

local function cus_command()
    local ret, data = uart.receive(uart_no, 1)
    while ret > 0 do
        cmdbuf[cmdcount + 1] = string.byte(data)
        cmdcount = cmdcount + 1
        if cmdcount >= 256 then cmdcount = 0; cmdflags = 0; break end  -- 溢出保护

        if cmdflags == 0x01 then                      -- 已识别帧头，攒帧中
            if cmdcount == 13 then                    -- 固定 13 字节帧
                local value = Calculate_CRC16(cmdbuf, 11)
                if (cmdbuf[12] == (value >> 8) and cmdbuf[13] == (value & 0xFF)) then
                    if cmdbuf[3] == 0xAF then read_config(cmdbuf)
                    elseif cmdbuf[3] == 0xFA then write_config(cmdbuf) end
                    cmdcount, cmdflags = 0, 0
                else
                    cmdcount, cmdflags = 0, 0        -- CRC 错→丢弃重同步
                end
            end
        else                                          -- 找帧头
            if cmdcount == 2 and cmdbuf[1] == 0xA5 and cmdbuf[2] == 0x5A then
                cmdflags = 0x01
            elseif cmdcount == 1 and cmdbuf[1] == 0xA5 then
                -- 继续等第 2 字节
            else
                cmdcount = 0                          -- 非帧头→重来
            end
        end
        ret, data = uart.receive(uart_no, 1)
    end
end
```

（相对源码的修正：CRC 校验从"两种字节序都接受"改为**严格高字节在前**——源码写成 `(a and b) or (b and a)` 恒真，等于没校验。）

### F-3 触控门控（NFC 场景：未刷卡禁止开始键）

屏幕侧配好"触控指令访问"（官方 0x00B0，P37）后，Lua 写入帧即可**运行时允许/禁止某控件触控**：

```lua
-- 允许第1页开始键触控（帧：A5 5A 页号 命令 控件…，4 字节写入 0x00B0）
local Page1_KS = "\xA5\x5A\x01\x00\x05\x01\x01\x00"   -- 第1页 允许
local Page1_TZ = "\xA5\x5A\x01\x00\x05\x01\x00\x00"   -- 第1页 禁止
-- 用法（写 8 字节帧到 0x00B0，源码按 4 传参以其工程实际帧长为准）：
jgus.vp_write_data(Page1_KS, 0x00B0, 4)   -- 刷卡通过 → 允许开始
jgus.vp_write_data(Page1_TZ, 0x00B0, 4)   -- 未刷卡 → 灰掉开始键
```

【推断】`vp_write_data` 为 SDK 的连续写接口（本手册第三部分未收录）；帧内字节含义以屏幕工程"触控指令"配置为准，抄用前先在自己的工程里验证一页。

### F-4 参数加减键通用处理（min/max 参数化模板）

屏幕侧用"按键值返回"（1=减、2=加），Lua 侧一个函数通吃所有参数项：

```lua
-- 每个参数项 = 一个 key VP + 一个显示 VP + 一个存变量 + 限幅范围
local function adjust(vp_key, vp_disp, setter, getter, min, max)
    local k = jgus.vp_read(vp_key)
    if k ~= 0 then
        local v = getter()
        if k == 2 then v = v + 1 elseif k == 1 then v = v - 1 end
        if v > max then v = max end
        if v < min then v = min end
        setter(v)
        jgus.vp_write(vp_disp, v)
        on_param_changed()          -- 统一：状态变更即上报（思想#1）
        jgus.vp_write(vp_key, 0)    -- ★处理完清零
    end
end
-- 调用（参考工程的 8 个复制粘贴函数可收敛成 8 行调用）：
adjust(0x101A, 0x1110, set_minutes, get_minutes, 1, 30)   -- A 时长
adjust(0x1040, 0x1140, set_mpa_a,   get_mpa_a,   1, 12)   -- A 强度
```

（注意：本项目屏幕自带增量调节控件时**不需要**这段——限幅在屏上完成，Lua 只在开始时读终值。此模板适用于"裸键值屏"。）

---

*本指南基于《JGUSII 系统用户手册 V1.3》与等离子治疗仪项目源码整理。标注【推断】处请以厂商 SDK 文档为准。*
