# ============================================================================
#  pi-bootstrap.ps1  —  Pi work environment migration, cloud side.
#
#  Public plaintext driver. Downloads AES-encrypted assets from the release,
#  decrypts them locally (openssl-compatible: AES-256-CBC + PBKDF2/200k/SHA256),
#  then installs: Pi env + runtime, projects, accelerator.
#
#  Usage (single line):
#    & ([scriptblock]::Create((iwr <url> -UseBasicParsing).Content)) -Key '<key>'
#  or, if the file is already on disk:
#    .\pi-bootstrap.ps1 -Key '<key>'
# ============================================================================
[CmdletBinding()]
param(
	[string]$Key = $env:PI_MIGRATE_KEY,
	[string]$Repo = 'DireSabbath/pi-migration',
	[string]$Tag = 'pi-migrate-v1',
	[string]$Work = "$env:TEMP\pi-migrate",
	[ValidateSet('all', 'core', 'projects', 'feiniao')][string]$Stage = 'all',
	[switch]$NoShortcut,
	[switch]$WithToolchain,
	[int]$Iter = 200000
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:failed = $false

function Say([string]$m) { Write-Host ("[pi] " + $m) }
function Head([string]$m) { Write-Host ""; Write-Host ("[pi] ==== " + $m + " ====") }
function Warn([string]$m) { Write-Host ("[pi] !! " + $m) }

if (-not $Key) { throw "missing -Key (the transfer key)" }

# --------------------------------------------------------------- decrypt ----
function Unprotect-OpenSslFile {
	param([string]$Cipher, [string]$Plain, [string]$Password, [int]$Iterations)
	$bytes = [IO.File]::ReadAllBytes($Cipher)
	if ($bytes.Length -lt 32) { throw "ciphertext too short: $Cipher" }
	if ([Text.Encoding]::ASCII.GetString($bytes, 0, 8) -ne 'Salted__') { throw "not an openssl salted file: $Cipher" }
	$salt = New-Object byte[] 8
	[Array]::Copy($bytes, 8, $salt, 0, 8)
	$kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(
		$Password, $salt, $Iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
	$aes = [System.Security.Cryptography.Aes]::Create()
	$aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'
	$aes.Key = $kdf.GetBytes(32); $aes.IV = $kdf.GetBytes(16)
	$src = New-Object IO.MemoryStream(, $bytes)
	$null = $src.Seek(16, 'Begin')
	$fs = [IO.File]::Create($Plain)
	$cs = New-Object System.Security.Cryptography.CryptoStream($fs, $aes.CreateDecryptor(), 'Write')
	$buf = New-Object byte[] (4MB)
	while (($n = $src.Read($buf, 0, $buf.Length)) -gt 0) { $cs.Write($buf, 0, $n) }
	$cs.FlushFinalBlock(); $cs.Dispose(); $fs.Dispose(); $src.Dispose()
}

# -------------------------------------------------------------- expand ------
function Expand-ZipFast([string]$Zip, [string]$Dir) {
	if (Test-Path $Dir) { Remove-Item $Dir -Recurse -Force }
	New-Item -ItemType Directory -Force -Path $Dir | Out-Null
	$tar = Join-Path $env:SystemRoot 'System32\tar.exe'
	if (Test-Path $tar) {
		& $tar -xf $Zip -C $Dir
		if ($LASTEXITCODE -ne 0) { throw "tar extraction failed for $Zip" }
	} else {
		Expand-Archive -Path $Zip -DestinationPath $Dir -Force
	}
}
function Find-Marker([string]$Dir, [string]$Name) {
	$hit = Get-ChildItem -Path $Dir -Filter $Name -Recurse -Depth 2 -File -ErrorAction SilentlyContinue |
		Select-Object -First 1
	if ($hit) { return $hit.DirectoryName }
	return $null
}

# ------------------------------------------------------------- download -----
function Get-Asset([string]$Name) {
	$dest = Join-Path $Work $Name
	$url = "https://github.com/$Repo/releases/download/$Tag/$Name"
	$sw = [Diagnostics.Stopwatch]::StartNew()
	Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -TimeoutSec 3600
	$sw.Stop()
	$mb = (Get-Item $dest).Length / 1MB
	Say ("{0,-22} {1,7:N0} MB  {2,6:N1}s  {3,5:N1} MB/s" -f $Name, $mb, $sw.Elapsed.TotalSeconds, ($mb / $sw.Elapsed.TotalSeconds))
}

function Fetch-Stage([string]$Asset, [string]$FolderHint) {
	$enc = Join-Path $Work $Asset
	if (-not (Test-Path $enc)) { Get-Asset $Asset }
	$zip = Join-Path $Work ($Asset -replace '\.enc$', '')
	if (-not (Test-Path $zip)) {
		Say "decrypt  : $Asset"
		Unprotect-OpenSslFile -Cipher $enc -Plain $zip -Password $Key -Iterations $Iter
		Say ("           {0:N0} MB plaintext" -f ((Get-Item $zip).Length / 1MB))
	}
	$dir = Join-Path $Work $FolderHint
	if (-not (Test-Path $dir)) {
		Say "expand   : $FolderHint"
		$sw = [Diagnostics.Stopwatch]::StartNew()
		Expand-ZipFast -Zip $zip -Dir $dir
		$sw.Stop()
		Say ("           {0:N1}s" -f $sw.Elapsed.TotalSeconds)
	}
	return $dir
}

# ---------------------------------------------------------------- start -----
Head "preflight"
Say "target home : $env:USERPROFILE"
Say "work dir    : $Work"
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$free = (Get-PSDrive -Name ([IO.Path]::GetPathRoot($Work).TrimEnd(':\'))).Free
Say ("free space  : {0:N1} GB" -f ($free / 1GB))
if ($free -lt 8GB) { Warn "less than 8 GB free; the migration needs about 6 GB" }
try {
	$null = Invoke-WebRequest -Uri "https://api.github.com" -UseBasicParsing -TimeoutSec 30
	Say "github      : reachable"
} catch {
	throw "github is not reachable from this machine. Fallback: copy the *.zip.enc files into $Work using the cloud-desktop client's file redirection, then re-run this script with the same -Key."
}
Say "powershell  : $($PSVersionTable.PSVersion)"

# ------------------------------------------------------------------ core ----
if ($Stage -in @('all', 'core')) {
	Head "stage 1/3  pi core (env + runtime + node)"
	try {
		$dir = Fetch-Stage 'pi-core.zip.enc' 'pi-core'
		$root = Find-Marker $dir 'install-cloud.ps1'
		if (-not $root) { throw "install-cloud.ps1 not found in payload" }
		& (Join-Path $root 'install-cloud.ps1')
	} catch { $script:failed = $true; Warn "core stage failed: $($_.Exception.Message)" }
}

# -------------------------------------------------------------- projects ----
if ($Stage -in @('all', 'projects')) {
	Head "stage 2/3  pi projects (workspace + pi-remote + android sdk-lite)"
	try {
		$dir = Fetch-Stage 'pi-projects.zip.enc' 'pi-projects'
		$root = Find-Marker $dir 'install-projects.ps1'
		if (-not $root) { throw "install-projects.ps1 not found in payload" }
		& (Join-Path $root 'install-projects.ps1')
	} catch { $script:failed = $true; Warn "projects stage failed: $($_.Exception.Message)" }
}

# -------------------------------------------------------------- feiniao -----
if ($Stage -in @('all', 'feiniao')) {
	Head "stage 3/3  飞鸟加速 (clash-based accelerator)"
	try {
		$dir = Fetch-Stage 'feiniao.zip.enc' 'feiniao'
		$root = Find-Marker $dir 'install-feiniao.ps1'
		if (-not $root) { throw "install-feiniao.ps1 not found in payload" }
		$runner = Join-Path $root 'install-feiniao.ps1'
		if ($NoShortcut) { & $runner -NoShortcut } else { & $runner }
	} catch { $script:failed = $true; Warn "feiniao stage failed: $($_.Exception.Message)" }
}

# ------------------------------------------------------------- toolchain ----
if ($WithToolchain) {
	Head "optional  toolchain (git / python / 7-zip)"
	$req = Join-Path $Work 'pi-projects\requirements-freeze.txt'
	if (-not (Test-Path $req)) { $req = (Get-ChildItem $Work -Filter 'requirements-freeze.txt' -Recurse | Select-Object -First 1).FullName }
	if (Get-Command winget -ErrorAction SilentlyContinue) {
		foreach ($id in @('Git.Git', 'Python.Python.3.12', '7zip.7zip')) {
			Say "winget install $id"
			try { winget install --id $id -e --accept-package-agreements --accept-source-agreements --silent } catch { Warn "winget $id failed" }
		}
	} else {
		Warn "winget not available. Install manually: Git for Windows, Python 3.12, 7-Zip."
	}
	if ($req) {
		Say "pip install -r requirements-freeze.txt  (tsinghua mirror)"
		try { & python -m pip install -r $req -i https://pypi.tuna.tsinghua.edu.cn/simple --no-warn-script-location } catch { Warn "pip install failed" }
	}
}

# --------------------------------------------------------------- summary ----
Head "summary"
$piRoot = Join-Path $env:USERPROFILE '.pi'
$nodeExe = Join-Path $piRoot 'node\node.exe'
$launcher = Join-Path $piRoot 'agent\bin\pi-launcher.js'
if ((Test-Path $nodeExe) -and (Test-Path $launcher)) {
	$v = (& $nodeExe $launcher --version) 2>&1
	Say "pi version   : $v"
	Say "pi launcher  : $piRoot\agent\bin\pi.cmd"
	& $nodeExe (Join-Path $piRoot 'agent\bin\verify-extensions.mjs')
	Say "ext loader   : exit=$LASTEXITCODE"
}
foreach ($p in @('agent\extensions', 'agent\skills', 'agent\memory', 'agent\sessions',
                 'agent\workspace', '..\pi-remote', 'node')) {
	$full = Join-Path $piRoot $p
	if (Test-Path $full) {
		$mb = (Get-ChildItem $full -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB
		Say ("{0,-24} {1,9:N1} MB" -f $p, $mb)
	}
}
Say "feiniao      : $(if (Test-Path (Join-Path $env:LOCALAPPDATA 'Programs\飞鸟加速')) { 'installed' } else { 'not installed' })"
Say "key/params   : stage=$Stage toolchain=$WithToolchain"
if ($script:failed) { Say "RESULT: COMPLETED WITH FAILURES (see warnings above)" }
else { Say "RESULT: OK - migration complete" }
Say "next: open a NEW terminal and run  pi"
Say "note: delete the public repo when you are done: gh repo delete $Repo"
