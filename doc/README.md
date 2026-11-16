# 项目开发文档索引

本目录集中存放本项目的全部开发文档(Lua / Modbus / JGUS 串口屏)。
`.lua` 运行代码(`main.lua`、`modbus.lua`、`crc16.lua`、`json.lua`、`sys.lua`)仍在项目根目录,请勿混放。

## 文档清单

| 文件 | 用途 | 说明 |
|---|---|---|
| `JGUS开发手册.md` | **主手册(人看,唯一编辑源)** | JGUSII 串口屏 + Lua 模组完整开发指南:Lua 速成、jgus/uart API、数据通路、实战配方、调试排错 |
| `AI开发手册.txt` | AI 助手阅读镜像 | 由 `make_ai_txt.ps1` 从 `JGUS开发手册.md` 自动生成的纯文本,勿手改 |
| `晶兴Modbus开发指南.md` | Modbus 开发指南(屏幕侧) | 整理自厂商 PDF,对比"屏幕侧 Modbus"与"Lua 侧 Modbus"两条路径 |
| `晶兴Modbus开发指南V1.0.pdf` | 厂商原始 PDF | 深圳晶兴科技 2015-08-30,6 页;md 版为其整理稿 |
| `uart 模块 API 文档.md` | uart 模块 API 参考 | uart.init / send / recv 等接口参数说明 |
| `代码块库.md` | **开发代码块库(通用模式,占位符版)** | 20 个可复制代码块,每块附「能做什么/怎么用/依赖/要改什么」说明卡;含使用指南、占位符对照表、块调用关系图 |
| `工程模板.lua` | 完整可跑工程模板(上一项目实例) | 具体 VP 地址、A/B/C 页面、NFC 联动等业务逻辑都在这里;新工程整体复制后按适配清单改 |
| `make_ai_txt.ps1` | 文档同步脚本 | 把 `JGUS开发手册.md` 转成纯文本 `AI开发手册.txt` |

## 维护流程

1. 修改手册内容:**只编辑 `JGUS开发手册.md`**(它是唯一编辑源)。
2. 改完后在 `doc/` 目录运行同步脚本,更新 AI 镜像:
   ```
   powershell -ExecutionPolicy Bypass -File make_ai_txt.ps1
   ```
3. 新增文档时放入本目录,并在此清单中登记一行。

## 相关代码位置

- 项目主程序:根目录 `main.lua`(依赖同目录 `modbus.lua`、`crc16.lua`、`json.lua`、`sys.lua`)
- 历史参考代码:`参考/main-ASCII显示正常.lua`
- 另一套练习工程:`practice2/`(含 `DD_SET/main.lua`)
- AI 开发 skill:`.opencode/skills/jgus-dev/`(其索引指向本目录文档)
