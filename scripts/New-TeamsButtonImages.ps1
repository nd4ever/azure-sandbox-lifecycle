#Requires -Version 7.0
<#
.SYNOPSIS
    Generates the base64-encoded PNG button images used by the Teams approval card.
.DESCRIPTION
    Draws bright green (approve) and bright red (reject) rounded buttons that match the
    approval email colors and writes their base64 strings to out/ for embedding in the module.
    Windows-only (uses System.Drawing).
#>

[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'out')
)

Add-Type -AssemblyName System.Drawing

function New-SandboxButtonBase64 {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Draws an image in memory and returns a base64 string; performs no state change.')]
    param(
        [Parameter(Mandatory)] [string]$Text,
        [Parameter(Mandatory)] [string]$HexColor
    )

    $width = 280
    $height = 56
    $bitmap = [System.Drawing.Bitmap]::new($width, $height)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
        $graphics.Clear([System.Drawing.Color]::FromArgb(0, 255, 255, 255))

        $radius = 12
        $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
        $path.AddArc(0, 0, $radius * 2, $radius * 2, 180, 90)
        $path.AddArc($width - 1 - $radius * 2, 0, $radius * 2, $radius * 2, 270, 90)
        $path.AddArc($width - 1 - $radius * 2, $height - 1 - $radius * 2, $radius * 2, $radius * 2, 0, 90)
        $path.AddArc(0, $height - 1 - $radius * 2, $radius * 2, $radius * 2, 90, 90)
        $path.CloseFigure()

        $color = [System.Drawing.ColorTranslator]::FromHtml($HexColor)
        $brush = [System.Drawing.SolidBrush]::new($color)
        $graphics.FillPath($brush, $path)

        $font = [System.Drawing.Font]::new('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
        $format = [System.Drawing.StringFormat]::new()
        $format.Alignment = [System.Drawing.StringAlignment]::Center
        $format.LineAlignment = [System.Drawing.StringAlignment]::Center
        $layout = [System.Drawing.RectangleF]::new(0, 0, $width, $height)
        $graphics.DrawString($Text, $font, [System.Drawing.Brushes]::White, $layout, $format)

        $brush.Dispose()
        $font.Dispose()
        $format.Dispose()
        $path.Dispose()
        $graphics.Dispose()

        $stream = [System.IO.MemoryStream]::new()
        $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        return [Convert]::ToBase64String($stream.ToArray())
    }
    finally {
        $bitmap.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

$green = New-SandboxButtonBase64 -Text 'Approve deletion' -HexColor '#107C10'
$red = New-SandboxButtonBase64 -Text 'Reject' -HexColor '#A4262C'

Set-Content -Path (Join-Path $OutputDirectory 'btn-green.txt') -Value $green -NoNewline
Set-Content -Path (Join-Path $OutputDirectory 'btn-red.txt') -Value $red -NoNewline

[pscustomobject]@{ GreenLength = $green.Length; RedLength = $red.Length }
