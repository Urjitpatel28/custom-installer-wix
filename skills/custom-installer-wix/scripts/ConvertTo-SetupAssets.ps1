<#
.SYNOPSIS
    Draws the installer's images from the app's icon (or a PNG logo).

.DESCRIPTION
    -Kind Msi     Banner.bmp (493x58) and Dialog.bmp (493x312) for the WixUI dialogs.
    -Kind Bundle  Logo.png (64x64), LogoSide.png (165x450) and the 88x26 button states for the
                  Burn wizard in templates\bundle\Theme.xml.
    -Kind Ico     Only converts -Source (a PNG) into a multi-size .ico at -IcoOut.

    The accent colour (primary button, Dialog.bmp panel) is taken from the logo's most saturated
    pixels unless -Accent is given, then darkened until white text on it is readable.

    Every image is flattened onto the colour it will sit on. thmutil draws PNGs without blending
    them against what is behind, so a transparent corner comes out black; WixUI bitmaps have no alpha.

.EXAMPLE
    .\ConvertTo-SetupAssets.ps1 -Source app.ico -OutDir Contoso.Setup\Assets -Kind Msi -ProductName Contoso
#>
[CmdletBinding()]
param(
    # .ico or .png. Optional for -Kind Bundle, which then draws a lettered tile instead of a logo.
    [string]$Source,
    [string]$OutDir,
    [ValidateSet('Msi', 'Bundle', 'Ico')] [string]$Kind = 'Msi',
    [string]$ProductName = 'Setup',
    [string]$Manufacturer = '',
    # RRGGBB. Defaults to a colour taken from the logo.
    [string]$Accent,
    # With a PNG -Source, also write it as a multi-size .ico here.
    [string]$IcoOut
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

function Get-SourceBitmap([string]$Path) {
    <# The largest image in an .ico (PNG or BMP frame), or the PNG itself, as a 32bpp Bitmap. #>
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 6 -and $bytes[0] -eq 0 -and $bytes[1] -eq 0 -and $bytes[2] -eq 1 -and $bytes[3] -eq 0) {
        $count = [BitConverter]::ToUInt16($bytes, 4)
        $best = $null
        for ($i = 0; $i -lt $count; $i++) {
            $o = 6 + 16 * $i
            $w = $bytes[$o]; if ($w -eq 0) { $w = 256 }
            $h = $bytes[$o + 1]; if ($h -eq 0) { $h = 256 }
            $entry = [pscustomobject]@{
                Area = $w * $h; Bpp = [BitConverter]::ToUInt16($bytes, $o + 6)
                Size = [BitConverter]::ToUInt32($bytes, $o + 8); Offset = [BitConverter]::ToUInt32($bytes, $o + 12)
                Header = $bytes[$o..($o + 15)]
            }
            if (-not $best -or $entry.Area -gt $best.Area -or ($entry.Area -eq $best.Area -and $entry.Bpp -gt $best.Bpp)) { $best = $entry }
        }
        if (-not $best) { throw "$Path contains no images." }
        $data = New-Object byte[] $best.Size
        [Array]::Copy($bytes, [int]$best.Offset, $data, 0, [int]$best.Size)
        if ($data[0] -eq 0x89 -and $data[1] -eq 0x50) {
            $image = [System.Drawing.Image]::FromStream((New-Object System.IO.MemoryStream(, $data)))
            return New-Object System.Drawing.Bitmap($image)
        }
        # A BMP frame: wrap it as a one-image .ico, which System.Drawing.Icon decodes with its alpha.
        $single = New-Object System.IO.MemoryStream
        $writer = New-Object System.IO.BinaryWriter($single)
        $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]1)
        $writer.Write([byte[]]$best.Header[0..11]); $writer.Write([uint32]22)
        $writer.Write($data); $writer.Flush(); $single.Position = 0
        $icon = New-Object System.Drawing.Icon($single)
        return $icon.ToBitmap()
    }
    $png = [System.Drawing.Image]::FromFile($Path)
    try { return New-Object System.Drawing.Bitmap($png) } finally { $png.Dispose() }
}

function Get-RelativeLuminance([System.Drawing.Color]$c) {
    $channel = { param($v) $s = $v / 255.0; if ($s -le 0.03928) { $s / 12.92 } else { [Math]::Pow(($s + 0.055) / 1.055, 2.4) } }
    return 0.2126 * (& $channel $c.R) + 0.7152 * (& $channel $c.G) + 0.0722 * (& $channel $c.B)
}

function Get-Shade([System.Drawing.Color]$c, [double]$factor) {
    return [System.Drawing.Color]::FromArgb(255, [int]($c.R * $factor), [int]($c.G * $factor), [int]($c.B * $factor))
}

function Get-AccentColor($Bitmap) {
    <# Mean of the logo's saturated, mid-brightness, opaque pixels; Windows blue when there are too few. #>
    $fallback = [System.Drawing.Color]::FromArgb(255, 0x0F, 0x6C, 0xBD)
    if (-not $Bitmap) { return $fallback }
    $small = New-Object System.Drawing.Bitmap($Bitmap, 48, 48)
    $r = 0; $g = 0; $b = 0; $n = 0
    for ($x = 0; $x -lt 48; $x++) {
        for ($y = 0; $y -lt 48; $y++) {
            $p = $small.GetPixel($x, $y)
            if ($p.A -lt 200) { continue }
            if ($p.GetSaturation() -lt 0.35 -or $p.GetBrightness() -lt 0.2 -or $p.GetBrightness() -gt 0.85) { continue }
            $r += $p.R; $g += $p.G; $b += $p.B; $n++
        }
    }
    $small.Dispose()
    if ($n -lt 20) { return $fallback }
    return [System.Drawing.Color]::FromArgb(255, [int]($r / $n), [int]($g / $n), [int]($b / $n))
}

function New-Canvas([int]$Width, [int]$Height, [System.Drawing.Color]$Fill, $Format = [System.Drawing.Imaging.PixelFormat]::Format32bppArgb) {
    $bitmap = New-Object System.Drawing.Bitmap($Width, $Height, $Format)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $graphics.Clear($Fill)
    return , @($bitmap, $graphics)
}

function Draw-Logo($Graphics, $Logo, [int]$X, [int]$Y, [int]$Size, [System.Drawing.Color]$TileColor, [string]$Letter) {
    <# The logo scaled into a square, aspect kept; or, with no logo, a rounded tile carrying a letter. #>
    if ($Logo) {
        $scale = [Math]::Min($Size / $Logo.Width, $Size / $Logo.Height)
        $w = [int]($Logo.Width * $scale); $h = [int]($Logo.Height * $scale)
        $Graphics.DrawImage($Logo, (New-Object System.Drawing.Rectangle(($X + ($Size - $w) / 2), ($Y + ($Size - $h) / 2), $w, $h)))
        return
    }
    $path = New-RoundedPath $X $Y $Size $Size ([Math]::Max(4, $Size / 6))
    $brush = New-Object System.Drawing.SolidBrush($TileColor)
    $Graphics.FillPath($brush, $path); $brush.Dispose(); $path.Dispose()
    $font = New-Object System.Drawing.Font('Segoe UI', [single]($Size * 0.55), [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $format = New-Object System.Drawing.StringFormat
    $format.Alignment = [System.Drawing.StringAlignment]::Center; $format.LineAlignment = [System.Drawing.StringAlignment]::Center
    $Graphics.DrawString($Letter, $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF($X, $Y, $Size, $Size)), $format)
    $font.Dispose()
}

function New-RoundedPath([single]$X, [single]$Y, [single]$W, [single]$H, [single]$Radius) {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $Radius * 2
    $path.AddArc($X, $Y, $d, $d, 180, 90)
    $path.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
    $path.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90)
    $path.AddArc($X, $Y + $H - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    return $path
}

function Save-Ico($Bitmap, [string]$Path) {
    <# Multi-size .ico with PNG frames (supported by every Windows since Vista). #>
    $sizes = 16, 24, 32, 48, 64, 128, 256
    $frames = @()
    foreach ($s in $sizes) {
        $pair = New-Canvas $s $s ([System.Drawing.Color]::Transparent)
        Draw-Logo $pair[1] $Bitmap 0 0 $s ([System.Drawing.Color]::Transparent) ''
        $pair[1].Dispose()
        $ms = New-Object System.IO.MemoryStream
        $pair[0].Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $pair[0].Dispose()
        $frames += , $ms.ToArray()
    }
    $out = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($out)
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $dim = $sizes[$i]; if ($dim -ge 256) { $dim = 0 }
        $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
        $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$frames[$i].Length); $w.Write([uint32]$offset)
        $offset += $frames[$i].Length
    }
    foreach ($f in $frames) { $w.Write($f) }
    $w.Flush()
    [System.IO.File]::WriteAllBytes($Path, $out.ToArray())
}

$logo = $null
if ($Source) {
    if (-not (Test-Path -LiteralPath $Source)) { throw "Logo not found: $Source" }
    $logo = Get-SourceBitmap (Resolve-Path -LiteralPath $Source).ProviderPath
}

if ($IcoOut) {
    if (-not $logo) { throw "-IcoOut needs -Source." }
    Save-Ico $logo $IcoOut
    Write-Output "  $IcoOut"
}
if ($Kind -eq 'Ico') { return }

if (-not $OutDir) { throw "-OutDir is required for -Kind $Kind." }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

if ($Accent) {
    $accentColor = [System.Drawing.Color]::FromArgb(255, [Convert]::ToInt32($Accent.Substring(0, 2), 16), [Convert]::ToInt32($Accent.Substring(2, 2), 16), [Convert]::ToInt32($Accent.Substring(4, 2), 16))
}
else {
    $accentColor = Get-AccentColor $logo
}
# White button text needs contrast: darken until the accent is dark enough (about 4.5:1).
while ((Get-RelativeLuminance $accentColor) -gt 0.18) { $accentColor = Get-Shade $accentColor 0.9 }

$letter = ''
if ($ProductName) { $letter = $ProductName.Substring(0, 1).ToUpperInvariant() }
$white = [System.Drawing.Color]::White
$sidebarText = $white
# White at 75% over the accent, precomputed: thmutil draws without alpha.
$sidebarMuted = [System.Drawing.Color]::FromArgb(255, [int](255 * 0.75 + $accentColor.R * 0.25), [int](255 * 0.75 + $accentColor.G * 0.25), [int](255 * 0.75 + $accentColor.B * 0.25))

function Fill-Sidebar($Graphics, [int]$Width, [int]$Height) {
    <# The brand panel: the accent colour, deepening towards the bottom. White text on it stays readable
       because the accent was darkened above for exactly that. #>
    $rect = New-Object System.Drawing.Rectangle(0, 0, $Width, $Height)
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $accentColor, (Get-Shade $accentColor 0.55), [single]90)
    $Graphics.FillRectangle($brush, $rect); $brush.Dispose()
}

function Draw-LogoCard($Graphics, $Logo, [int]$X, [int]$Y, [int]$Size) {
    <# The logo on a white rounded card, so a logo in the accent colour does not vanish into the panel. #>
    $path = New-RoundedPath $X $Y $Size $Size ([Math]::Max(6, $Size / 6))
    $Graphics.FillPath([System.Drawing.Brushes]::White, $path); $path.Dispose()
    $pad = [int]($Size * 0.16)
    Draw-Logo $Graphics $Logo ($X + $pad) ($Y + $pad) ($Size - 2 * $pad) $accentColor $letter
}

if ($Kind -eq 'Msi') {
    if (-not $logo) { throw "-Kind Msi needs -Source; without a logo, leave WiX's default dialog images in place." }
    $rgb24 = [System.Drawing.Imaging.PixelFormat]::Format24bppRgb

    # Banner.bmp: the strip across the top of every inner dialog. WixUI draws the title and
    # description over its left side, so the logo sits on the right.
    $pair = New-Canvas 493 58 $white $rgb24
    Draw-Logo $pair[1] $logo (493 - 44 - 10) 7 44 $accentColor $letter
    $pair[1].Dispose()
    $pair[0].Save((Join-Path $OutDir 'Banner.bmp'), [System.Drawing.Imaging.ImageFormat]::Bmp); $pair[0].Dispose()

    # Dialog.bmp: the background of the Welcome and Finish pages. WixUI draws text from about x=180,
    # so the brand panel stays left of that and the rest is white.
    $pair = New-Canvas 493 312 $white $rgb24
    $g = $pair[1]
    Fill-Sidebar $g 164 312
    Draw-LogoCard $g $logo 38 56 88
    $font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $centred = New-Object System.Drawing.StringFormat; $centred.Alignment = [System.Drawing.StringAlignment]::Center
    $textBrush = New-Object System.Drawing.SolidBrush($sidebarText)
    $g.DrawString($ProductName, $font, $textBrush, (New-Object System.Drawing.RectangleF(8, 168, 148, 60)), $centred)
    $textBrush.Dispose(); $font.Dispose(); $g.Dispose()
    $pair[0].Save((Join-Path $OutDir 'Dialog.bmp'), [System.Drawing.Imaging.ImageFormat]::Bmp); $pair[0].Dispose()
}

if ($Kind -eq 'Bundle') {
    # Must match the panel colour in Theme.xml (Font 0's Background).
    $wizardBg = $white
    $surface = $white
    $border = [System.Drawing.Color]::FromArgb(255, 0xD0, 0xD7, 0xDE)
    $hover = [System.Drawing.Color]::FromArgb(255, 0xF3, 0xF4, 0xF6)
    $pressed = [System.Drawing.Color]::FromArgb(255, 0xEA, 0xEC, 0xEF)
    $disabled = [System.Drawing.Color]::FromArgb(255, 0xEE, 0xF0, 0xF2)

    $pair = New-Canvas 64 64 $wizardBg
    Draw-Logo $pair[1] $logo 2 2 60 $accentColor $letter
    $pair[1].Dispose()
    $pair[0].Save((Join-Path $OutDir 'Logo.png'), [System.Drawing.Imaging.ImageFormat]::Png); $pair[0].Dispose()

    # Full client height, so thmutil never stretches it.
    $pair = New-Canvas 165 450 $accentColor
    $g = $pair[1]
    Fill-Sidebar $g 165 450
    Draw-LogoCard $g $logo 37 96 92
    $titleFont = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $bodyFont = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $centred = New-Object System.Drawing.StringFormat; $centred.Alignment = [System.Drawing.StringAlignment]::Center
    $titleBrush = New-Object System.Drawing.SolidBrush($sidebarText)
    $mutedBrush = New-Object System.Drawing.SolidBrush($sidebarMuted)
    $g.DrawString($ProductName, $titleFont, $titleBrush, (New-Object System.Drawing.RectangleF(8, 210, 149, 44)), $centred)
    $g.FillRectangle($mutedBrush, 66, 262, 33, 2)
    if ($Manufacturer) { $g.DrawString($Manufacturer, $bodyFont, $mutedBrush, (New-Object System.Drawing.RectangleF(8, 414, 149, 18)), $centred) }
    $titleFont.Dispose(); $bodyFont.Dispose(); $titleBrush.Dispose(); $mutedBrush.Dispose(); $g.Dispose()
    $pair[0].Save((Join-Path $OutDir 'LogoSide.png'), [System.Drawing.Imaging.ImageFormat]::Png); $pair[0].Dispose()

    # One file per button state, flattened onto the panel colour (no alpha blending in thmutil).
    $buttons = @(
        @('ButtonPrimary.png', $accentColor, $null),
        @('ButtonPrimaryHover.png', (Get-Shade $accentColor 0.85), $null),
        @('ButtonPrimaryPressed.png', (Get-Shade $accentColor 0.72), $null),
        @('ButtonDisabled.png', $disabled, $border),
        @('ButtonSecondary.png', $surface, $border),
        @('ButtonSecondaryHover.png', $hover, $accentColor),
        @('ButtonSecondaryPressed.png', $pressed, $accentColor)
    )
    foreach ($b in $buttons) {
        $pair = New-Canvas 88 26 $wizardBg
        $shape = New-RoundedPath 0.5 0.5 87 25 4
        $brush = New-Object System.Drawing.SolidBrush($b[1])
        $pair[1].FillPath($brush, $shape); $brush.Dispose()
        if ($null -ne $b[2]) { $pen = New-Object System.Drawing.Pen($b[2], 1); $pair[1].DrawPath($pen, $shape); $pen.Dispose() }
        $shape.Dispose(); $pair[1].Dispose()
        $pair[0].Save((Join-Path $OutDir $b[0]), [System.Drawing.Imaging.ImageFormat]::Png); $pair[0].Dispose()
    }
}

if ($logo) { $logo.Dispose() }
Get-ChildItem -LiteralPath $OutDir -File | Sort-Object Name | ForEach-Object { Write-Output "  $($_.FullName)" }
