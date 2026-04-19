#Requires -Version 5.1
<#
.SYNOPSIS
    ssj — JUI terminal transport (PowerShell client for Windows)
.DESCRIPTION
    Usage:
      ssj host                      # connect on default port 7878
      ssj host:port                 # connect on custom port
      ssj user@host                 # SSH as user (for token fetch only)
      ssj user@host:port
      ssj host --refresh            # force re-fetch token from server
      ssj host --token TOKEN        # use explicit token (skip SSH fetch)

    First connect: SSH to host to read ~/.config/jui/token, cache locally.
    Subsequent connects: use cached token directly (no SSH needed).
    Session persists on server — disconnect and reconnect anytime.
.EXAMPLE
    .\ssj.ps1 192.168.14.30
    .\ssj.ps1 js@192.168.14.30:7878 --refresh
    .\ssj.ps1 192.168.14.30 --token mytoken123
#>

param(
    [Parameter(Mandatory=$true, Position=0)]
    [string]$HostArg,

    [switch]$Refresh,

    [string]$Token = ""
)

$ErrorActionPreference = "Stop"

$Julia    = if ($env:JUI_JULIA)   { $env:JUI_JULIA }   else { "julia" }
$JuiProj  = if ($env:JUI_PROJECT) { $env:JUI_PROJECT } else { "" }
$ConfigDir = Join-Path $env:APPDATA "ssj"
New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null

# ── Parse [user@]host[:port] ──────────────────────────────────────────────
$SshUser = ""
if ($HostArg -match "^([^@]+)@(.+)$") {
    $SshUser = $Matches[1]
    $HostArg = $Matches[2]
}

$Port = 7878
if ($HostArg -match "^(.+):(\d+)$") {
    $HostArg = $Matches[1]
    $Port    = [int]$Matches[2]
}

$Host_ = $HostArg
$SafeHost = ($SshUser -replace '[^a-zA-Z0-9]','_') + ($Host_ -replace '[^a-zA-Z0-9]','_') + "_$Port"
$TokenCache = Join-Path $ConfigDir "$SafeHost.token"

# ── Get token ─────────────────────────────────────────────────────────────
if ($Token -ne "") {
    # explicit --token flag: use as-is
} elseif ($Refresh -or -not (Test-Path $TokenCache)) {
    $Target = if ($SshUser) { "${SshUser}@${Host_}" } else { $Host_ }
    Write-Host "ssj: fetching token from $Target..." -ForegroundColor Cyan
    try {
        $Token = & ssh $Target "cat ~/.config/jui/token 2>/dev/null || cat ~/.jui-token 2>/dev/null" 2>$null
        $Token = $Token.Trim()
    } catch {
        $Token = ""
    }
    if (-not $Token) {
        Write-Error "ssj: ERROR — could not get JUI token from $Host_."
        Write-Host  "     Is jui-server running? Start with: julia jui-server.jl" -ForegroundColor Yellow
        exit 1
    }
    Set-Content -Path $TokenCache -Value $Token -NoNewline -Encoding UTF8
    Write-Host "ssj: token cached at $TokenCache" -ForegroundColor Gray
} else {
    $Token = (Get-Content -Path $TokenCache -Raw -Encoding UTF8).Trim()
}

# ── Build Julia activation snippet ────────────────────────────────────────
$Activate = ""
if ($JuiProj -ne "") {
    $Activate = "import Pkg; Pkg.activate(`"$JuiProj`"); "
}

# ── Connect ───────────────────────────────────────────────────────────────
Write-Host "ssj: connecting to ${Host_}:${Port}..." -ForegroundColor Cyan

$JuliaCode = @"
${Activate}using JUI
try
    JUI.run_client("${Host_}", ${Port}, "${Token}")
catch e
    if e isa JUI.AuthError && occursin("SPKI pin mismatch", string(e))
        println(stderr, "ssj: SPKI mismatch -- server cert changed.")
        println(stderr, "     Run: ssj ${Host_}:${Port} --refresh  to re-pin.")
        exit(2)
    elseif e isa JUI.AuthError
        println(stderr, "ssj: auth failed -- ", e)
        println(stderr, "     Token may be stale. Run: ssj ${Host_}:${Port} --refresh")
        exit(3)
    end
    rethrow()
end
"@

& $Julia -e $JuliaCode
exit $LASTEXITCODE
