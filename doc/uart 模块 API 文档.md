# uart 模块 API 文档

本模块提供对底层 UART 硬件的 Lua 接口。所有函数通过整数索引（如 0、1）指定 UART 通道。

## uart.init(idx, rate\[, databits\[, stopbits\[, parity\]\]\])

初始化 UART 通道。

**参数说明：**

| 参数 | 类型 | 是否必填 | 默认值 | 说明 |
| --- | --- | --- | --- | --- |
| idx | 整数 | 是 | — | UART 通道编号（如 0） |
| rate | 整数 | 是 | — | 波特率（如 115200） |
| databits | 整数 | 否 | 8 | 数据位（5~8） |
| stopbits | 整数 | 否 | 1 | 停止位（1 或 2） |
| parity | 整数 | 否 | 0 | 校验模式：<br>0 = 无校验<br>1 = 奇校验<br>2 = 偶校验 |

**返回值：**  

*   成功：返回非负整数（通常为 0） 
    
*   失败：返回 `nil` 和错误字符串（如 "UART initialization not supported"）
    

## uart.deinit(idx)

释放 UART 资源。

**参数：**

| 参数 | 类型 | 是否必填 | 说明 |
| --- | --- | --- | --- |
| idx | 整数 | 是 | UART 通道编号 |

**返回值：**  

*   成功：非负整数 
    
*   失败：`nil, "UART deinitialization not supported"`
    

## uart.send(idx, data)

发送数据。

**参数：**

| 参数 | 类型 | 是否必填 | 说明 |
| --- | --- | --- | --- |
| idx | 整数 | 是 | UART 通道编号 |
| data | 字符串 | 是 | 要发送的原始字节（支持二进制） |

**返回值：**  

*   成功：返回实际发送的字节数（≥0） 
    
*   失败：`nil, "UART send not supported"`
    

## uart.receive(idx, maxlen)

接收数据（返回两个值）。

**参数：**

| 参数 | 类型 | 是否必填 | 说明 |
| --- | --- | --- | --- |
| idx | 整数 | 是 | UART 通道编号 |
| maxlen | 整数 | 是 | 最大接收字节数（必须 > 0） |

**返回值说明：**

| 第一个返回值 | 第二个返回值 | 含义 |
| --- | --- | --- |
| n > 0 | 字符串（长度 n） | 成功接收 n 字节 |
| 0 | nil | 无数据（超时或空） |
| < 0（如 -1） | nil | 错误（如不支持） |

## uart.get\_default\_index()

获取系统默认 UART 编号（常用于调试串口）。

**参数：** 无  
**返回值：** 整数（如 0）

## 使用示例

```plaintext
-- 加载 uart 模块
local uart = require("uart")

-- 初始化默认 UART
local idx = uart.get_default_index()
uart.init(idx, 115200, 8, 1, 0)

-- 发送并接收
uart.send(idx, "AT\r\n")
local n, resp = uart.receive(idx, 64)
if n > 0 then print(resp) end

-- 释放
uart.deinit(idx)

```