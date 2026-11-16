# 从 JGUS开发手册.md 生成 AI开发手册.txt（纯文本镜像）
# md 是唯一编辑源；改完 md 后重新运行本脚本即可同步 txt
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$src  = Join-Path $root "JGUS开发手册.md"
$dst  = Join-Path $root "AI开发手册.txt"

$text = [System.IO.File]::ReadAllText($src, [System.Text.Encoding]::UTF8)

# 1. 剥目录/正文的 Markdown 链接 [文字](#锚点) / [文字](url) → 纯文字（先剥链接再防嵌套）
$text = [regex]::Replace($text, '\[([^\]]+)\]\([^)]*\)', '$1')

# 2. 加粗 **文字** → 文字
$text = [regex]::Replace($text, '\*\*([^*]+)\*\*', '$1')

# 3. 引用块去 "> " 前缀（内容保留）
$text = [regex]::Replace($text, '(?m)^> ?', '')

# 4. 标题降级为纯文本标记（顺序：H3 -> H2 -> H1，避免互相误伤）
$text = [regex]::Replace($text, '(?m)^### (.+)$', '~~~~~~~~ $1 ~~~~~~~~')
$text = [regex]::Replace($text, '(?m)^## (.+)$',  '-------- $1 --------')
$text = [regex]::Replace($text, '(?m)^# (.+)$',   '======== $1 ========')

# 5. 注入文件头（说明用途/源/同步方法）
$header = @"
================================================================
AI 开发手册（纯文本版）
================================================================
来源      : JGUS开发手册.md（唯一编辑源，本文件由 make_ai_txt.ps1 生成）
用途      : 供 AI 助手阅读的全量镜像；格式已去 Markdown 化
同步方法  : 修改 md 后运行  powershell -ExecutionPolicy Bypass -File make_ai_txt.ps1
章节标记  : ======== 一级 ========  /  -------- 二级 --------  /  ~~~~~~~~ 三级 ~~~~~~~~
================================================================

"@

[System.IO.File]::WriteAllText($dst, $header + $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("generated: " + $dst + " (" + (Get-Item $dst).Length + " bytes)")
