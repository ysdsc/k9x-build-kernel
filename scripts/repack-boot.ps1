<#
.SYNOPSIS
    用云端编译出的 Image.gz 替换原厂 boot.img 的内核段，重打包并（可选）刷入 OPPO K9x。

.DESCRIPTION
    设备：OPPO K9x (MT6833 / PERM00)，内核 4.19.191
    原厂 boot.img 结构（已实测）：
        HEADER_VER [2]  PAGESIZE [2048]
        KERNEL_SZ  [19373517]  KERNEL_FMT [gzip]   <-- 替换这一段
        RAMDISK_SZ [2177112]   RAMDISK_FMT [gzip]  <-- 保持不动
        DTB_SZ     [160733]
    因此只需把 Image.gz 解压成 raw 后覆盖解包出来的 kernel 文件，再 repack。

.PARAMETER ImageGz
    云端产物 Image.gz 的路径。

.PARAMETER StockBoot
    原厂 boot.img 的路径。

.PARAMETER Out
    输出镜像路径。

.PARAMETER Flash
    指定则该镜像会经 fastboot 刷入设备。默认只生成镜像，不刷。

.EXAMPLE
    .\repack-boot.ps1 -ImageGz D:\k9x-build\dist\Image.gz
    .\repack-boot.ps1 -ImageGz D:\k9x-build\dist\Image.gz -Flash
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ImageGz,

    [string]$StockBoot = 'D:\Downloads\oppok9x\boot.img',

    [string]$Out = (Join-Path $PSScriptRoot 'boot-resukisu.img'),

    [string]$Magiskboot = 'D:\Downloads\gongju\KernelSU-patch\bin\magiskboot.exe',

    [string]$Fastboot = 'D:\Downloads\platform-tools\fastboot.exe',

    [switch]$Flash
)

$ErrorActionPreference = 'Stop'

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  [注意] $msg" -ForegroundColor Yellow }
function Die($msg)  { Write-Host "  [失败] $msg" -ForegroundColor Red; throw "K9X_REPACK_FAILED: $msg" }

# 注意：不能用 $Args 作参数名 —— 它是 PowerShell 自动变量（之前正是这个 bug 导致
# 参数被吞掉，magiskboot 只收到空参数而打印用法）。
# magiskboot 把横幅写到 stderr，PowerShell 会包装成 ErrorRecord 并在 Stop 下抛出，
# 所以临时降级为 Continue，用 exit code 判定成败。
function Invoke-Magiskboot {
    param([string[]]$MagiskArgs, [string]$WorkDir)
    Push-Location $WorkDir
    $prev = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $proc = & $Magiskboot @MagiskArgs 2>&1
        $code = $LASTEXITCODE
        $lines = @($proc | ForEach-Object { "$_" })
        return @{ Code = $code; Output = $lines }
    }
    finally {
        $ErrorActionPreference = $prev
        Pop-Location
        $global:Error.Clear()
    }
}

Step '0. 环境检查'
foreach ($p in @($ImageGz, $StockBoot, $Magiskboot)) {
    if (-not (Test-Path -LiteralPath $p)) { Die "找不到文件: $p" }
}
Ok "Image.gz   : $ImageGz"
Ok "原厂 boot  : $StockBoot"
Ok "magiskboot : $Magiskboot"

$imgSize = (Get-Item -LiteralPath $ImageGz).Length
Write-Host ("  Image.gz 大小: {0:N0} 字节" -f $imgSize)
if ($imgSize -lt 1MB) { Die "Image.gz 太小（$imgSize 字节），可能下载不完整或传错了文件" }
if ($imgSize -gt 40MB) { Warn "Image.gz 偏大（$([math]::Round($imgSize/1MB,1)) MB），确认它是内核而不是整包" }

$fs = [System.IO.File]::OpenRead($ImageGz)
try {
    $magic = New-Object byte[] 2
    [void]$fs.Read($magic, 0, 2)
} finally { $fs.Dispose() }
if ($magic[0] -ne 0x1F -or $magic[1] -ne 0x8B) {
    Die ("Image.gz 不是 gzip 格式（魔数 {0:X2} {1:X2}）。应为 1F 8B；若拿到的是未压缩 Image，请先压缩。" -f $magic[0], $magic[1])
}
Ok 'gzip 魔数校验通过 (1F 8B)'

Step '1. 备份原厂 boot.img'
$backupDir = Join-Path $PSScriptRoot 'backup'
if (-not (Test-Path $backupDir)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $backupDir "boot-original-$stamp.img"
Copy-Item -LiteralPath $StockBoot -Destination $backup
$hash = (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash
Ok "已备份到 $backup"
Write-Host "  SHA256: $hash"
Set-Content -LiteralPath (Join-Path $backupDir "boot-original-$stamp.sha256") -Value "$hash  boot-original-$stamp.img"

Step '2. 解包原厂 boot.img'
$work = Join-Path $PSScriptRoot "work-$stamp"
if (-not (Test-Path $work)) { New-Item -ItemType Directory -Path $work | Out-Null }
Copy-Item -LiteralPath $StockBoot -Destination (Join-Path $work 'boot.img')

$r = Invoke-Magiskboot -MagiskArgs @('unpack', 'boot.img') -WorkDir $work
if ($r.Code -ne 0) {
    $tail = ($r.Output | Select-Object -First 12) -join "`n"
    Die "magiskboot unpack 失败 (exit=$($r.Code)):`n$tail"
}
$r.Output | Where-Object { $_ -match 'HEADER_VER|KERNEL_SZ|RAMDISK_SZ|PAGESIZE|KERNEL_FMT|CMDLINE' } |
    ForEach-Object { Write-Host "  $_" }

$kernelPath = Join-Path $work 'kernel'
foreach ($f in 'kernel', 'ramdisk.cpio', 'dtb') {
    if (-not (Test-Path (Join-Path $work $f))) { Die "解包缺少 $f，boot.img 结构异常" }
}
Ok ("解包完成，原 kernel 段 {0:N0} 字节（已解压为 raw）" -f (Get-Item $kernelPath).Length)

Step '3. 记录原厂内核版本'
$origVer = $null
$text = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($kernelPath))
$m = [regex]::Match($text, 'Linux version [0-9]+\.[0-9]+\.[0-9]+[^\x00\r\n]{0,80}')
if ($m.Success) { $origVer = $m.Value; Write-Host "  原厂: $origVer" }
else { Warn '原厂内核中未找到版本串' }

Step '4. 用新内核替换 kernel 段'
# 关键：magiskboot 解包后 kernel 是 raw；若直接把 gzip 塞进去，repack 会认为"已压缩"
# 而跳过压缩，导致 KERNEL_FMT=gzip 但内容是二次封装，BootROM 解压失败。
# 所以必须先把 Image.gz 解压成 raw。
$tmpKernel = Join-Path $work 'newkernel.raw'
$r = Invoke-Magiskboot -MagiskArgs @('decompress', $ImageGz, $tmpKernel) -WorkDir $work
if ($r.Code -ne 0) {
    $tail = ($r.Output | Select-Object -First 12) -join "`n"
    Die "解压 Image.gz 失败 (exit=$($r.Code)):`n$tail"
}
if (-not (Test-Path $tmpKernel)) { Die 'decompress 未产生输出文件' }
Write-Host ("  新 kernel (raw): {0:N0} 字节" -f (Get-Item $tmpKernel).Length)

# ARM64 Image 在偏移 0x38 处有魔数 0x644d5241（小端存储为 'ARM' + 0x64）
$arm64magic = New-Object byte[] 4
$fs = [System.IO.File]::OpenRead($tmpKernel)
[void]$fs.Seek(0x38, 'Begin')
[void]$fs.Read($arm64magic, 0, 4)
$fs.Dispose()
$magicStr = -join ($arm64magic | ForEach-Object { [char]$_ })
if ($magicStr -eq ('ARM' + [char]0x64)) {
    Ok 'ARM64 Image 魔数校验通过 (0x38 处为 ARM\x64)'
} else {
    Warn ("0x38 处不是 ARM64 Image 魔数（得到 '{0}'）—— 可能不是内核 Image" -f $magicStr)
}

if ($origVer) {
    $newText = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($tmpKernel))
    $nm = [regex]::Match($newText, 'Linux version [0-9]+\.[0-9]+\.[0-9]+[^\x00\r\n]{0,80}')
    if ($nm.Success) {
        Write-Host "  新内核: $($nm.Value)"
        if ($nm.Value -notmatch '4\.19\.') {
            Warn '新内核版本不是 4.19.x —— 与原厂 4.19.191 不匹配，刷入极可能无法开机！'
            $ans = Read-Host '  仍要继续吗？(输入 yes 继续)'
            if ($ans -ne 'yes') { Die '用户中止' }
        } else { Ok '新内核版本 4.19.x 与本设备匹配' }
    } else { Warn '新内核中未找到版本串（可能被剥离），请人工确认' }
}

Copy-Item -LiteralPath $tmpKernel -Destination $kernelPath -Force
Ok 'kernel 段已替换'

Step '5. 重打包'
$outFull = [System.IO.Path]::GetFullPath($Out)
$tmpOut = Join-Path $work 'new-boot.img'
$r = Invoke-Magiskboot -MagiskArgs @('repack', 'boot.img', $tmpOut) -WorkDir $work
if ($r.Code -ne 0) {
    $tail = ($r.Output | Select-Object -First 12) -join "`n"
    Die "repack 失败 (exit=$($r.Code)):`n$tail"
}
if (-not (Test-Path $tmpOut)) { Die 'repack 未生成镜像' }
Ok ("重打包完成: {0:N0} 字节" -f (Get-Item $tmpOut).Length)

Step '6. 校验新镜像可被 magiskboot 正常解析'
$verifyDir = Join-Path $work 'verify'
New-Item -ItemType Directory -Path $verifyDir -Force | Out-Null
Copy-Item -LiteralPath $tmpOut -Destination (Join-Path $verifyDir 'boot.img')
$r = Invoke-Magiskboot -MagiskArgs @('unpack', 'boot.img') -WorkDir $verifyDir
if ($r.Code -ne 0) {
    $tail = ($r.Output | Select-Object -First 12) -join "`n"
    Die "新镜像无法解包，重打包结果损坏:`n$tail"
}
$r.Output | Where-Object { $_ -match 'HEADER_VER|KERNEL_SZ|RAMDISK_SZ|PAGESIZE|KERNEL_FMT|CMDLINE' } |
    ForEach-Object { Write-Host "  $_" }
Ok '新镜像可正常解析'

Copy-Item -LiteralPath $tmpOut -Destination $outFull -Force
$outHash = (Get-FileHash -LiteralPath $outFull -Algorithm SHA256).Hash
Write-Host "`n  输出: $outFull" -ForegroundColor Green
Write-Host "  SHA256: $outHash"

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

if (-not $Flash) {
    Write-Host "`n未刷入（未指定 -Flash）。手动刷入：" -ForegroundColor Yellow
    Write-Host "  & '$Fastboot' flash boot '$outFull'"
    Write-Host "回滚："
    Write-Host "  & '$Fastboot' flash boot '$backup'"
    return
}

Step '7. 刷入前确认设备状态'
$r = & $Fastboot devices 2>&1
if (-not $r) {
    Warn 'fastboot 未检测到设备。请让手机进入 fastboot 模式：'
    Write-Host '  关机后按住音量下 + 电源键，或 adb reboot bootloader'
    Die '无设备'
}
Write-Host "  设备: $r"

$ans = Read-Host "`n即将刷入 boot 分区。输入 YES 继续"
if ($ans -ne 'YES') { Die '用户中止刷入' }

Step '8. 刷入'
& $Fastboot flash boot $outFull
if ($LASTEXITCODE -ne 0) {
    Warn '刷入失败。立即恢复原厂 boot：'
    Write-Host "  & '$Fastboot' flash boot '$backup'"
    Die 'flash 失败'
}
Ok '刷入完成'
Write-Host "`n重启：" -ForegroundColor Yellow
Write-Host "  & '$Fastboot' reboot"

Write-Host "`n===== 刷机后核对清单 =====" -ForegroundColor Cyan
Write-Host "  1. 若能开机：adb shell uname -a  应为 4.19.191"
Write-Host "  2. 安装 BakaSU/ReSukiSU 管理器 APK，应显示已工作"
Write-Host "  3. 若卡开机动画/黑屏："
Write-Host "     & '$Fastboot' flash boot '$backup'"
Write-Host "  4. 若 fastboot 也不可用：用 SP Flash Tool + MTK_AllInOne_DA 刷回备份"
