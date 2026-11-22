<#
.SYNOPSIS
Serves a local web UI that manages the model download entries in the bash provisioning
scripts next to this file (minimax_h3.sh, krea2.sh, flux2.sh, wan2.sh, ...).

.DESCRIPTION
The UI lists every top-level *.sh script in the scripts folder, parses the model download
calls in the selected script (Civitai: download_civitai_primary / civitai download --version
/ --model / bare; HuggingFace: download_hf_file blocks, hf download, download_hf, wget of
huggingface.co URLs), and shows them in a table with source badges, target dirs, inline or
adjacent-comment descriptions, and links.

Extra capabilities:
- "Check new versions" queries the Civitai API for every active civitai-version entry and
  flags entries whose pinned version is no longer the model's newest version (orange badge
  linking to the new version). HuggingFace entries have no meaningful version concept and
  are not checked.
- Rows can be deleted (the exact line block is removed from the script file).
- New models can be added by pasting a Civitai or HuggingFace URL; the URL is resolved
  through the public APIs and a call line/block is inserted after the last active entry
  using the dominant call form already used by that script.

Safety: the server binds to localhost only, embeds a per-session random token into the page
(X-Auth header required on every API call), and rejects cross-origin requests. Before the
first mutation of a script in a server session, a one-shot sidecar backup <name>.sh.bak is
written. Files are always written as UTF-8 without BOM with LF line endings (bash-safe).
The scripts folder is expected to be a git repo, which is the primary recovery path.

.PARAMETER Port
Local TCP port for the web UI. Defaults to 8766; the script increments on conflict.

.PARAMETER ScriptsDir
Folder containing the provisioning scripts. Defaults to the folder of this script.

.PARAMETER NoBrowser
Do not open the default browser automatically.

.EXAMPLE
.\model_manager.ps1

.EXAMPLE
.\model_manager.ps1 -Port 8800 -NoBrowser
#>
[CmdletBinding()]
param(
    [int]$Port = 8766,

    [string]$ScriptsDir = '',

    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$env:GIT_TERMINAL_PROMPT = '0'   # git push must fail fast in the UI, never hang on a credential prompt
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$script:utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if ([string]::IsNullOrWhiteSpace($ScriptsDir)) {
    $ScriptsDir = $PSScriptRoot
}
if ([string]::IsNullOrWhiteSpace($ScriptsDir)) {
    throw 'ScriptsDir could not be determined; pass -ScriptsDir explicitly.'
}
$script:ScriptsDir = [System.IO.Path]::GetFullPath($ScriptsDir)
if (-not ([System.IO.Directory]::Exists($script:ScriptsDir))) {
    throw "Scripts directory not found: $script:ScriptsDir"
}

# ---------------------------------------------------------------------------
# Log ring buffer (returned to the web UI and echoed to the console)
# ---------------------------------------------------------------------------
$script:log = New-Object System.Collections.Generic.List[string]

function Add-Log {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    $script:log.Add($line)
    while ($script:log.Count -gt 400) { $script:log.RemoveAt(0) }
    Write-Host $line
}

function Get-LogTailText {
    $count = $script:log.Count
    if ($count -eq 0) { return '' }
    $take = [Math]::Min($count, 150)
    return (($script:log.GetRange($count - $take, $take)) -join "`n")
}

# ---------------------------------------------------------------------------
# Script parsing
# ---------------------------------------------------------------------------
function Get-ScriptText {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path, $script:utf8NoBom)
}

function Split-ScriptLines {
    param([string]$Text)
    # Keeps a trailing empty element when the text ends with a newline, so a
    # join with "`n" reproduces the final line ending exactly.
    return [System.Text.RegularExpressions.Regex]::Split($Text, '\r?\n')
}

function Get-AdjacentComment {
    # Text of the standalone comment line immediately above a (1-based) line,
    # used as the entry description. Rejects comment lines that are actually
    # parts of a commented-out backslash-continued block (they end with a
    # continuation marker, or the line above them does) and commented-out
    # model call lines themselves.
    param([string[]]$Lines, [int]$LineNo)
    if ($LineNo -lt 2) { return '' }
    $prev = $Lines[$LineNo - 2].Trim()
    if (-not $prev.StartsWith('#')) { return '' }
    $t = $prev.TrimStart('#').Trim()
    if ($t.Length -eq 0) { return '' }
    if ($t.EndsWith('\')) { return '' }
    if ($LineNo -ge 3) {
        $above = $Lines[$LineNo - 3].Trim()
        if ($above.StartsWith('#')) {
            $ta = $above.TrimStart('#').Trim()
            if ($ta.EndsWith('\')) { return '' }
        }
    }
    if ($t -match '^(download_hf_file|download_civitai_primary|download_hf)\b' -or
        $t -match '^(civitai|hf|wget)\s') { return '' }
    return $t
}

function Get-ScriptModels {
    param([string]$Path)

    $models = New-Object System.Collections.Generic.List[object]
    $warnings = New-Object System.Collections.Generic.List[object]
    $text = Get-ScriptText $Path
    $lines = Split-ScriptLines $text
    $total = $lines.Count
    $i = 0

    while ($i -lt $total) {
        $trimmed = $lines[$i].Trim()
        $i++
        if ($trimmed.Length -eq 0) { continue }

        $active = $true
        $work = $trimmed
        if ($work.StartsWith('#')) {
            $active = $false
            $work = $work.TrimStart('#').Trim()
            if ($work.Length -eq 0) { continue }
        }
        $lineNo = $i          # 1-based line number of the first line of this candidate
        $blockEnd = $i        # 1-based line number of the last line of this entry
        $joined = $work

        # --- download_hf_file: single-line or multi-line (backslash continuations) ---
        $isHfFileCall = ($work -eq 'download_hf_file') -or ($work -match '^download_hf_file[\s\\]')
        if ($isHfFileCall) {
            if ($work.EndsWith('\') -or $work -eq 'download_hf_file') {
                $parts = New-Object System.Collections.Generic.List[string]
                $first = $work
                if ($first.EndsWith('\')) { $first = $first.Substring(0, $first.Length - 1).Trim() }
                if ($first.Length -gt 0) { $parts.Add($first) }
                $done = $false
                $j = $i
                while (-not $done -and $j -lt $total) {
                    $c = $lines[$j].Trim()
                    $j++
                    if ($c.StartsWith('#')) { $c = $c.TrimStart('#').Trim() }
                    if ($c.Length -eq 0) { $j--; break }
                    $hadCont = $c.EndsWith('\')
                    if ($hadCont) { $c = $c.Substring(0, $c.Length - 1).Trim() }
                    if ($c.Length -gt 0) { $parts.Add($c) }
                    if (-not $hadCont) { $done = $true }
                }
                $blockEnd = $j
                $joined = ($parts -join ' ')
            }

            $mHf = [regex]::Match($joined, '^download_hf_file\s+([^\s"''$]+)\s+([^\s"''$]+)\s+([^\s"''$]+)(?:\s+#\s*(.+?))?\s*$')
            if ($mHf.Success) {
                $repo = $mHf.Groups[1].Value
                $remotePath = $mHf.Groups[2].Value
                $dest = $mHf.Groups[3].Value
                $inlineDesc = $mHf.Groups[4].Value
                if ([string]::IsNullOrWhiteSpace($inlineDesc) -and $active) {
                    $inlineDesc = Get-AdjacentComment -Lines $lines -LineNo $lineNo
                }
                $dir = $dest
                $fileName = ''
                $sep = $dest.LastIndexOf('/')
                if ($sep -ge 0) {
                    $dir = $dest.Substring(0, $sep)
                    $fileName = $dest.Substring($sep + 1)
                }
                $models.Add([ordered]@{
                    lineStart   = $lineNo
                    lineEnd     = $blockEnd
                    active      = $active
                    source      = 'hf'
                    kind        = 'hf-file'
                    callForm    = 'download_hf_file'
                    ids         = @{}
                    dir         = $dir
                    description = $inlineDesc
                    url         = "https://huggingface.co/$repo"
                    name        = ''
                    repo        = $repo
                    path        = $remotePath
                    filename    = $fileName
                })
            }
            else {
                $warnings.Add(@{ line = $lineNo; reason = 'download_hf_file with non-literal arguments ignored (shell variables/quotes)' })
            }
            $i = $blockEnd
            continue
        }

        # --- Civitai forms ---
        $entry = $null
        $m = [regex]::Match($work, '^download_civitai_primary\s+(\d+)\s+([^\s#]+)(?:\s+#\s*(.+?))?\s*$')
        if ($m.Success) {
            $entry = [ordered]@{
                lineStart = $lineNo; lineEnd = $blockEnd; active = $active
                source = 'civitai'; kind = 'civitai-version'; callForm = 'primary'
                ids = @{ versionId = $m.Groups[1].Value }; dir = $m.Groups[2].Value
                description = $m.Groups[3].Value; url = $null; name = ''
                repo = $null; path = $null; filename = $null
            }
        }
        if (-not $entry) {
            $m = [regex]::Match($work, '^civitai\s+download\s+--version\s+(\d+)\s+--out-dir\s+([^\s#]+)(?:\s+#\s*(.+?))?\s*$')
            if ($m.Success) {
                $entry = [ordered]@{
                    lineStart = $lineNo; lineEnd = $blockEnd; active = $active
                    source = 'civitai'; kind = 'civitai-version'; callForm = 'flag'
                    ids = @{ versionId = $m.Groups[1].Value }; dir = $m.Groups[2].Value
                    description = $m.Groups[3].Value; url = $null; name = ''
                    repo = $null; path = $null; filename = $null
                }
            }
        }
        if (-not $entry) {
            $m = [regex]::Match($work, '^civitai\s+download\s+--model\s+(\d+)\s+--out-dir\s+([^\s#]+)(?:\s+#\s*(.+?))?\s*$')
            if ($m.Success) {
                $entry = [ordered]@{
                    lineStart = $lineNo; lineEnd = $blockEnd; active = $active
                    source = 'civitai'; kind = 'civitai-model'; callForm = 'model'
                    ids = @{ modelId = $m.Groups[1].Value }; dir = $m.Groups[2].Value
                    description = $m.Groups[3].Value; url = $null; name = ''
                    repo = $null; path = $null; filename = $null
                }
            }
        }
        if (-not $entry) {
            $m = [regex]::Match($work, '^civitai\s+download\s+(\d+)\s+--out-dir\s+([^\s#]+)(?:\s+#\s*(.+?))?\s*$')
            if ($m.Success) {
                $entry = [ordered]@{
                    lineStart = $lineNo; lineEnd = $blockEnd; active = $active
                    source = 'civitai'; kind = 'civitai-version'; callForm = 'bare'
                    ids = @{ versionId = $m.Groups[1].Value }; dir = $m.Groups[2].Value
                    description = $m.Groups[3].Value; url = $null; name = ''
                    repo = $null; path = $null; filename = $null
                }
            }
        }

        # --- hf download: hf://repo/path --local-dir DIR  |  repo FILE --local-dir DIR ---
        if (-not $entry) {
            $m = [regex]::Match($work, '^hf\s+download\s+(?:hf://)?([\w.-]+/[\w.-]+)(?:/([^\s#]+?))?\s+--local-dir\s+([^\s#]+)(?:\s+#\s*(.+?))?\s*$')
            if ($m.Success) {
                $repo = $m.Groups[1].Value
                $remotePath = $m.Groups[2].Value
                $dir = $m.Groups[3].Value
                $fileName = ''
                if ($remotePath) {
                    $sep = $remotePath.LastIndexOf('/')
                    if ($sep -ge 0) { $fileName = $remotePath.Substring($sep + 1) } else { $fileName = $remotePath }
                }
                $entry = [ordered]@{
                    lineStart = $lineNo; lineEnd = $blockEnd; active = $active
                    source = 'hf'; kind = 'hf-file'; callForm = 'hf_download'
                    ids = @{}; dir = $dir; description = $m.Groups[4].Value
                    url = "https://huggingface.co/$repo"; name = ''
                    repo = $repo; path = $remotePath; filename = $fileName
                }
            }
        }
        if (-not $entry) {
            $m = [regex]::Match($work, '^hf\s+download\s+([\w.-]+/[\w.-]+)\s+([^/\s"''$]+)\s+--local-dir\s+([^\s#]+)(?:\s+#\s*(.+?))?\s*$')
            if ($m.Success) {
                $entry = [ordered]@{
                    lineStart = $lineNo; lineEnd = $blockEnd; active = $active
                    source = 'hf'; kind = 'hf-file'; callForm = 'hf_download'
                    ids = @{}; dir = $m.Groups[3].Value; description = $m.Groups[4].Value
                    url = "https://huggingface.co/$($m.Groups[1].Value)"; name = ''
                    repo = $m.Groups[1].Value; path = $m.Groups[2].Value; filename = $m.Groups[2].Value
                }
            }
        }

        # --- download_hf helper (uri + local dir) ---
        if (-not $entry) {
            $m = [regex]::Match($work, '^download_hf\s+(?:hf://)?([\w.-]+/[\w.-]+)(?:/([^\s#]+?))?\s+([^\s#]+)(?:\s+#\s*(.+?))?\s*$')
            if ($m.Success) {
                $repo = $m.Groups[1].Value
                $remotePath = $m.Groups[2].Value
                $fileName = ''
                if ($remotePath) {
                    $sep = $remotePath.LastIndexOf('/')
                    if ($sep -ge 0) { $fileName = $remotePath.Substring($sep + 1) } else { $fileName = $remotePath }
                }
                $entry = [ordered]@{
                    lineStart = $lineNo; lineEnd = $blockEnd; active = $active
                    source = 'hf'; kind = 'hf-file'; callForm = 'download_hf'
                    ids = @{}; dir = $m.Groups[3].Value; description = $m.Groups[4].Value
                    url = "https://huggingface.co/$repo"; name = ''
                    repo = $repo; path = $remotePath; filename = $fileName
                }
            }
        }

        # --- wget of a huggingface.co resolve URL ---
        if (-not $entry) {
            $m = [regex]::Match($work, '^wget\s+-P\s+([^\s#]+)\s+(https://huggingface\.co/[^\s#]+)(?:\s+#\s*(.+?))?\s*$')
            if ($m.Success) {
                $u = $m.Groups[2].Value
                $mu = [regex]::Match($u, '^https://huggingface\.co/([^/\s]+)/([^/\s]+)/resolve/([^/\s]+)/(.+)$')
                $repo = ''
                $remotePath = ''
                $fileName = ''
                if ($mu.Success) {
                    $repo = "$($mu.Groups[1].Value)/$($mu.Groups[2].Value)"
                    $remotePath = $mu.Groups[4].Value
                    $sep = $remotePath.LastIndexOf('/')
                    if ($sep -ge 0) { $fileName = $remotePath.Substring($sep + 1) } else { $fileName = $remotePath }
                }
                $entry = [ordered]@{
                    lineStart = $lineNo; lineEnd = $blockEnd; active = $active
                    source = 'hf'; kind = 'hf-file'; callForm = 'wget'
                    ids = @{}; dir = $m.Groups[1].Value; description = $m.Groups[3].Value
                    url = $u; name = ''
                    repo = $repo; path = $remotePath; filename = $fileName
                }
            }
        }

        if (-not $entry) { continue }

        # Standalone comment directly above an ACTIVE entry (no blank line between).
        $desc = [string]$entry['description']
        if ([string]::IsNullOrWhiteSpace($desc) -and $active) {
            $desc = Get-AdjacentComment -Lines $lines -LineNo $lineNo
        }
        $entry['description'] = $desc
        $models.Add($entry)
    }

    return @{ models = $models; warnings = $warnings }
}

# ---------------------------------------------------------------------------
# Script file validation, backup, mutation
# ---------------------------------------------------------------------------
function Resolve-ScriptPath {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { throw 'A script name is required.' }
    if ($Name.IndexOfAny([char[]]@('/', '\')) -ge 0 -or $Name -eq '.' -or $Name -eq '..') {
        throw "Invalid script name: $Name"
    }
    $full = [System.IO.Path]::Combine($script:ScriptsDir, $Name)
    if (-not ([System.IO.File]::Exists($full))) { throw "Script not found: $Name" }
    return $full
}

$script:backedUp = @{}

function Backup-ScriptOnce {
    param([string]$Name, [string]$Path)
    if ($script:backedUp.ContainsKey($Name)) { return }
    [System.IO.File]::Copy($Path, "$Path.bak", $true)
    $script:backedUp[$Name] = $true
    Add-Log "One-shot backup written: $Name.bak"
}

function Purge-ScriptCache {
    param([string]$Name)
    $prefix = "$Name|"
    foreach ($k in @($script:civitaiCache.Keys)) {
        if ($k.StartsWith($prefix)) { $script:civitaiCache.Remove($k) }
    }
}

function Remove-EntryLines {
    param([string]$Path, [int]$LineStart, [int]$LineEnd)
    $text = Get-ScriptText $Path
    $lines = Split-ScriptLines $text
    if ($LineStart -lt 1 -or $LineEnd -lt $LineStart -or $LineEnd -gt $lines.Count) {
        throw "Line range $LineStart-$LineEnd is outside the file ($($lines.Count) lines)."
    }
    Backup-ScriptOnce ([System.IO.Path]::GetFileName($Path)) $Path
    $kept = New-Object System.Collections.Generic.List[string]
    for ($idx = 0; $idx -lt $lines.Count; $idx++) {
        if ($idx -ge ($LineStart - 1) -and $idx -le ($LineEnd - 1)) { continue }
        $kept.Add($lines[$idx])
    }
    [System.IO.File]::WriteAllText($Path, ($kept -join "`n"), $script:utf8NoBom)
}

function Toggle-EntryActive {
    # Comment out or uncomment the exact line block of a parsed model entry.
    # Multi-line blocks are toggled on every line so bash never sees a bare
    # continuation line. Returns the resulting active state.
    param([string]$Path, [int]$LineStart, [int]$LineEnd)
    $parsed = Get-ScriptModels $Path
    $entry = $null
    foreach ($m in $parsed.models) {
        if ([int]$m['lineStart'] -eq $LineStart -and [int]$m['lineEnd'] -eq $LineEnd) { $entry = $m; break }
    }
    if (-not $entry) { throw "No model entry found at lines $LineStart-$LineEnd of $([System.IO.Path]::GetFileName($Path))." }
    Backup-ScriptOnce ([System.IO.Path]::GetFileName($Path)) $Path
    $text = Get-ScriptText $Path
    $lines = Split-ScriptLines $text
    $wasActive = [bool]$entry['active']
    for ($idx = $LineStart - 1; $idx -le $LineEnd - 1; $idx++) {
        $line = $lines[$idx]
        if ($wasActive) {
            if ($line.Trim().Length -gt 0 -and -not $line.TrimStart().StartsWith('#')) {
                $lines[$idx] = '# ' + $line
            }
        }
        else {
            if ($line.TrimStart().StartsWith('#')) {
                $lines[$idx] = $line -replace '^(\s*)#+\s?', '$1'
            }
        }
    }
    [System.IO.File]::WriteAllText($Path, ($lines -join "`n"), $script:utf8NoBom)
    return (-not $wasActive)
}

function Set-EntryDir {
    # Rewrites the target dir of a parsed entry in place, preserving the call
    # form, comments and indentation. Multi-line download_hf_file blocks get
    # their destination line rebuilt as <newdir>/<filename>.
    param([string]$Path, [int]$LineStart, [int]$LineEnd, [string]$NewDir)
    if ([string]::IsNullOrWhiteSpace($NewDir) -or $NewDir -match '[\s#''"$]') {
        throw 'Target dir must not be empty and may not contain spaces, #, quotes or $.'
    }
    $parsed = Get-ScriptModels $Path
    $entry = $null
    foreach ($m in $parsed.models) {
        if ([int]$m['lineStart'] -eq $LineStart -and [int]$m['lineEnd'] -eq $LineEnd) { $entry = $m; break }
    }
    if (-not $entry) { throw "No model entry found at lines $LineStart-$LineEnd of $([System.IO.Path]::GetFileName($Path))." }
    Backup-ScriptOnce ([System.IO.Path]::GetFileName($Path)) $Path
    $text = Get-ScriptText $Path
    $lines = Split-ScriptLines $text
    $form = [string]$entry['callForm']

    if ($form -eq 'download_hf_file' -and $LineEnd -gt $LineStart) {
        # destination line is the last line of the block
        $idx = $LineEnd - 1
        $line = $lines[$idx]
        $prefix = ''
        if ($line -match '^(\s*#+\s?)') { $prefix = $Matches[1] }
        $content = if ($prefix) { $line.Substring($prefix.Length) } else { $line }
        $comment = ''
        $cm = [regex]::Match($content, '\s+(#.*)$')
        if ($cm.Success) { $comment = $cm.Groups[1].Value; $content = $content.Substring(0, $cm.Index).TrimEnd() }
        $im = [regex]::Match($content, '^\s*')
        $content = $im.Value + $NewDir + '/' + [string]$entry['filename']
        if ($comment) { $content = $content + ' ' + $comment }
        $lines[$idx] = $prefix + $content
    }
    else {
        $idx = $LineStart - 1
        $line = $lines[$idx]
        $prefix = ''
        if ($line -match '^(\s*#+\s?)') { $prefix = $Matches[1] }
        $content = if ($prefix) { $line.Substring($prefix.Length) } else { $line }
        $pattern = switch ($form) {
            'primary'          { '^(download_civitai_primary\s+\d+\s+)([^\s#]+)' }
            'download_hf'      { '^(download_hf\s+(?:hf://)?\S+\s+)([^\s#]+)' }
            'download_hf_file' { '^(download_hf_file\s+\S+\s+\S+\s+)([^\s#]+)' }
            'wget'             { '^(\s*wget\s+-P\s+)([^\s#]+)' }
            'hf_download'      { '^(.*?--local-dir\s+)([^\s#]+)' }
            default            { '^(.*?--out-dir\s+)([^\s#]+)' }
        }
        $m = [regex]::Match($content, $pattern)
        if (-not $m.Success) { throw "Could not locate the target dir token on line $LineStart." }
        $content = $content.Remove($m.Groups[2].Index, $m.Groups[2].Length).Insert($m.Groups[2].Index, $NewDir)
        $lines[$idx] = $prefix + $content
    }
    [System.IO.File]::WriteAllText($Path, ($lines -join "`n"), $script:utf8NoBom)
}

function Invoke-GitStep {
    param([string[]]$GitArgs)
    # Relax ErrorActionPreference: with Stop, PS 5.1 turns the first stderr
    # line of a redirected native command into a terminating error (git push
    # writes its progress to stderr).
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $result = & git -C $script:ScriptsDir @GitArgs 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
    $outLines = @($result | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -ne '' -and $_ -notmatch '^System\.Management\.Automation\.RemoteException$' })
    return @{ code = $code; lines = $outLines }
}

function Insert-EntryLines {
    param([string]$Path, [string[]]$NewLines)
    Backup-ScriptOnce ([System.IO.Path]::GetFileName($Path)) $Path
    $text = Get-ScriptText $Path
    $lines = Split-ScriptLines $text

    $parsed = Get-ScriptModels $Path
    $lastActive = $null
    foreach ($m in $parsed.models) {
        if ($m['active']) { $lastActive = $m }
    }
    $pos = $null
    if ($lastActive) {
        $pos = [int]$lastActive['lineEnd']   # insert right after the last active entry
    }
    elseif ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
        $pos = $lines.Count - 1              # before the trailing newline
    }
    else {
        $pos = $lines.Count
    }

    $block = New-Object System.Collections.Generic.List[string]
    $block.Add('')
    foreach ($l in $NewLines) { $block.Add($l) }

    $list = New-Object System.Collections.Generic.List[string]
    foreach ($l in $lines) { $list.Add($l) }
    $list.InsertRange($pos, $block)
    [System.IO.File]::WriteAllText($Path, ($list -join "`n"), $script:utf8NoBom)
    return $pos
}

function Get-DominantCivitaiForm {
    param([string]$Path)
    $parsed = Get-ScriptModels $Path
    $primary = 0; $flag = 0; $bare = 0
    foreach ($m in $parsed.models) {
        if ($m['source'] -ne 'civitai') { continue }
        switch ([string]$m['callForm']) {
            'primary' { $primary++ }
            'flag'    { $flag++ }
            'bare'    { $bare++ }
            default   { $flag++ }
        }
    }
    if ($primary -ge ($flag + $bare)) { return 'primary' }
    if ($flag -ge $bare) { return 'flag' }
    return 'bare'
}

# ---------------------------------------------------------------------------
# Civitai API
# ---------------------------------------------------------------------------
$script:civitaiCache = @{}

function Get-CivitaiHeaders {
    $headers = @{}
    if ($env:CIVITAI_TOKEN) { $headers['Authorization'] = "Bearer $($env:CIVITAI_TOKEN)" }
    return $headers
}

function Invoke-CivitaiApi {
    param([string]$Uri)
    return Invoke-RestMethod -Uri $Uri -Headers (Get-CivitaiHeaders) -TimeoutSec 30 -UseBasicParsing
}

function Update-CivitaiInfo {
    param([System.Collections.Generic.List[object]]$Models, [string]$ScriptName)

    $headers = Get-CivitaiHeaders
    $stats = @{ latest = 0; new = 0; unknown = 0; model = 0 }
    foreach ($m in $Models) {
        if ($m['source'] -ne 'civitai') { continue }
        if (-not $m['active']) { continue }
        try {
            if ($m['kind'] -eq 'civitai-version') {
                $vid = [string]$m['ids']['versionId']
                $ver = Invoke-CivitaiApi "https://civitai.com/api/v1/model-versions/$vid"
                $modelId = [string]$ver.modelId
                $verName = [string]$ver.name
                $modelName = ''
                if ($ver.model -and $ver.model.name) { $modelName = [string]$ver.model.name }
                if ($modelName) { $m['name'] = "$modelName - $verName" } else { $m['name'] = $verName }
                if ($ver.files -and $ver.files.Count -gt 0) {
                    if ($ver.files[0].sizeKB) { $m['fileSizeKB'] = [math]::Round([double]$ver.files[0].sizeKB) }
                    if ($ver.files[0].name) { $m['filename'] = [string]$ver.files[0].name }
                }
                $m['modelId'] = $modelId
                $m['url'] = "https://civitai.com/models/$modelId"
                Start-Sleep -Milliseconds 120
                $model = Invoke-CivitaiApi "https://civitai.com/api/v1/models/$modelId"
                $latest = $null
                if ($model.modelVersions -and $model.modelVersions.Count -gt 0) { $latest = $model.modelVersions[0] }
                if ($latest -and [long]$latest.id -eq [long]$vid) {
                    $m['versionStatus'] = 'latest'
                    $stats.latest++
                }
                elseif ($latest) {
                    $m['versionStatus'] = 'new'
                    $m['newVersion'] = @{
                        id   = [string]$latest.id
                        name = [string]$latest.name
                        url  = "https://civitai.com/models/${modelId}?modelVersionId=$($latest.id)"
                    }
                    $stats.new++
                }
                else {
                    $m['versionStatus'] = 'unknown'
                    $stats.unknown++
                }
            }
            elseif ($m['kind'] -eq 'civitai-model') {
                $mid = [string]$m['ids']['modelId']
                $model = Invoke-CivitaiApi "https://civitai.com/api/v1/models/$mid"
                $m['name'] = [string]$model.name
                $m['url'] = "https://civitai.com/models/$mid"
                $m['versionStatus'] = '-'
                if ($model.modelVersions -and $model.modelVersions.Count -gt 0) {
                    $m['latestVersion'] = [string]$model.modelVersions[0].name
                }
                $stats.model++
            }
        }
        catch {
            $m['versionStatus'] = 'unknown'
            $stats.unknown++
            Add-Log "Civitai check failed for line $($m['lineStart']) in ${ScriptName}: $($_.Exception.Message)"
        }

        $idPart = [string]$m['ids']['versionId'] + [string]$m['ids']['modelId']
        $cacheKey = "$ScriptName|$($m['lineStart'])|$idPart"
        $cached = @{}
        foreach ($field in @('name', 'fileSizeKB', 'filename', 'modelId', 'url', 'versionStatus', 'newVersion', 'latestVersion')) {
            if ($null -ne $m[$field]) { $cached[$field] = $m[$field] }
        }
        $script:civitaiCache[$cacheKey] = $cached
    }
    Add-Log ("Version check for {0}: {1} latest, {2} new, {3} unknown, {4} model info" -f $ScriptName, $stats.latest, $stats.new, $stats.unknown, $stats.model)
}

function Merge-CivitaiCache {
    param([string]$ScriptName, [System.Collections.Generic.List[object]]$Models)
    foreach ($m in $Models) {
        $idPart = [string]$m['ids']['versionId'] + [string]$m['ids']['modelId']
        $cacheKey = "$ScriptName|$($m['lineStart'])|$idPart"
        $cached = $script:civitaiCache[$cacheKey]
        if (-not $cached) { continue }
        foreach ($key in $cached.Keys) { $m[$key] = $cached[$key] }
    }
}

# ---------------------------------------------------------------------------
# URL resolution for the Add flow
# ---------------------------------------------------------------------------
function Resolve-CivitaiUrl {
    param([string]$Url)
    $m = [regex]::Match($Url, 'civitai\.com/models/(\d+)(?:[/?].*?modelVersionId=(\d+))?')
    if (-not $m.Success) {
        throw 'Not a Civitai model URL. Expected https://civitai.com/models/<id> or ...?modelVersionId=<id>.'
    }
    $mid = $m.Groups[1].Value
    $vid = $m.Groups[2].Value
    $autoPinned = $false
    if ([string]::IsNullOrWhiteSpace($vid)) {
        $model = Invoke-CivitaiApi "https://civitai.com/api/v1/models/$mid"
        if (-not $model.modelVersions -or $model.modelVersions.Count -eq 0) {
            throw "Civitai model $mid has no versions."
        }
        $vid = [string]$model.modelVersions[0].id
        $autoPinned = $true
    }
    $ver = Invoke-CivitaiApi "https://civitai.com/api/v1/model-versions/$vid"
    $modelName = ''
    if ($ver.model -and $ver.model.name) { $modelName = [string]$ver.model.name }
    $verName = [string]$ver.name
    $fileName = ''
    $sizeKB = $null
    if ($ver.files -and $ver.files.Count -gt 0) {
        $f = $null
        foreach ($cand in $ver.files) { if ($cand.primary) { $f = $cand; break } }
        if (-not $f) { $f = $ver.files[0] }
        if ($f.name) { $fileName = [string]$f.name }
        if ($f.sizeKB) { $sizeKB = [math]::Round([double]$f.sizeKB) }
    }
    $desc = ''
    if ($modelName -and $verName) { $desc = "$modelName - $verName" } elseif ($verName) { $desc = $verName } else { $desc = $modelName }
    return @{
        kind        = 'civitai'
        modelId     = $mid
        versionId   = $vid
        modelName   = $modelName
        versionName = $verName
        fileName    = $fileName
        sizeKB      = $sizeKB
        description = $desc
        autoPinned  = $autoPinned
        url         = "https://civitai.com/models/$mid"
    }
}

function Resolve-HfUrl {
    param([string]$Url)
    $clean = ($Url -split '[?#]')[0].Trim()
    $m = [regex]::Match($clean, '^https?://huggingface\.co/([\w.-]+)/([\w.-]+)(?:/(?:blob|resolve)/[^/\s]+/(.+))?/?$')
    if (-not $m.Success) {
        $m = [regex]::Match($clean, '^hf://([\w.-]+)/([\w.-]+)(?:/(.+))?$')
    }
    if (-not $m.Success) {
        throw 'Not a Hugging Face URL. Expected https://huggingface.co/<owner>/<repo>[/blob|/resolve/<branch>/<path>] or hf://<owner>/<repo>/<path>.'
    }
    $repo = "$($m.Groups[1].Value)/$($m.Groups[2].Value)"
    $path = [string]$m.Groups[3].Value
    if ($path) {
        $path = $path.TrimEnd('/')
        return @{ kind = 'hf'; repo = $repo; path = $path; fileName = [System.IO.Path]::GetFileName($path); files = $null }
    }
    $api = Invoke-RestMethod -Uri "https://huggingface.co/api/models/$repo" -TimeoutSec 30 -UseBasicParsing
    $files = @()
    if ($api.siblings) {
        foreach ($s in $api.siblings) {
            if ($s.rfilename) { $files += [string]$s.rfilename }
        }
    }
    return @{ kind = 'hf'; repo = $repo; path = ''; fileName = ''; files = $files }
}

function Resolve-ModelUrl {
    param([string]$Url, [string]$HfFile)
    if ([string]::IsNullOrWhiteSpace($Url)) { throw 'A model URL is required.' }
    if ($Url -match 'civitai\.com') { return Resolve-CivitaiUrl -Url $Url }
    if ($Url -match 'huggingface\.co|^hf://') {
        $r = Resolve-HfUrl -Url $Url
        if (-not $r.path -and -not [string]::IsNullOrWhiteSpace($HfFile)) {
            $r.path = $HfFile.Trim()
            $r.fileName = [System.IO.Path]::GetFileName($r.path)
        }
        return $r
    }
    throw 'Unrecognized URL. Use a civitai.com or huggingface.co (or hf://) link.'
}

# ---------------------------------------------------------------------------
# Web UI (single page)
# ---------------------------------------------------------------------------
$script:htmlTemplate = @'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Model Manager</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root{
    --border:#e3e6ea; --muted:#6b7280; --fg:#1f2328; --bg:#f6f7f9;
    --surface:#ffffff; --accent:#2563eb;
  }
  *{box-sizing:border-box}
  body{margin:0;font:14px/1.45 "Segoe UI",system-ui,sans-serif;color:var(--fg);background:var(--bg)}
  header{display:flex;align-items:center;gap:14px;padding:12px 18px;background:var(--surface);border-bottom:1px solid var(--border)}
  header h1{font-size:17px;margin:0;font-weight:600}
  header .hint{color:var(--muted);font-size:12.5px}
  header select{margin-left:auto;font:inherit;padding:5px 8px}
  .toolbar{display:flex;gap:10px;align-items:center;padding:10px 18px;border-bottom:1px solid var(--border);background:var(--surface)}
  .btn{font:inherit;padding:6px 14px;border:1px solid var(--border);border-radius:6px;background:var(--surface);cursor:pointer}
  .btn:hover{border-color:#c9ccd1;background:#f2f4f7}
  .btn.primary{background:var(--accent);border-color:var(--accent);color:#fff}
  .btn.primary:hover{background:#1d4ed8}
  .btn:disabled{opacity:.55;cursor:default}
  .btn-xs{font-size:12px;padding:3px 9px;border:1px solid var(--border);border-radius:5px;background:var(--surface);cursor:pointer;color:var(--fg)}
  .btn-xs:hover{border-color:#e05252;color:#c02626;background:#fff5f5}
  .warnings{padding:6px 18px;color:#9a6700;font-size:12.5px;background:#fff8e6;border-bottom:1px solid var(--border)}
  .warnings:empty{display:none}
  main{padding:14px 18px}
  table{width:100%;border-collapse:collapse;background:var(--surface);border:1px solid var(--border);border-radius:8px;font-size:13.5px}
  th{font-weight:600;color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.03em}
  th,td{padding:8px 10px;border-bottom:1px solid var(--border);vertical-align:top;text-align:left}
  tr:last-child td{border-bottom:none}
  tr.off td{opacity:.55}
  td.mono,.mono{font-family:Consolas,"Cascadia Mono",monospace;font-size:12.5px}
  .badge{display:inline-block;padding:2px 8px;border-radius:10px;font-size:11.5px;font-weight:600;white-space:nowrap}
  .b-civ{background:#dbeafe;color:#1d4ed8}
  .b-hf{background:#fef3c7;color:#92400e}
  .b-off{background:#e5e7eb;color:#4b5563;margin-left:6px}
  .b-latest{background:#dcfce7;color:#166534}
  .b-new{background:#ffedd5;color:#c2410c;cursor:pointer;text-decoration:none}
  .b-new:hover{text-decoration:underline}
  .b-unknown{background:#f3f4f6;color:#6b7280}
  .b-dash{color:var(--muted)}
  a{color:var(--accent);text-decoration:none}
  a:hover{text-decoration:underline}
  .empty{color:var(--muted);padding:26px;text-align:center}
  details.log{margin:10px 18px 20px;color:var(--muted);font-size:12px}
  details.log pre{white-space:pre-wrap;margin:6px 0 0;max-height:180px;overflow:auto;font-family:Consolas,monospace}
  .modal{position:fixed;inset:0;background:rgba(15,18,22,.45);display:flex;align-items:center;justify-content:center;z-index:10}
  .modal.hidden{display:none}
  .modal-card{background:var(--surface);border-radius:10px;padding:18px 20px;width:520px;max-width:94vw;max-height:90vh;overflow:auto;box-shadow:0 12px 40px rgba(0,0,0,.18)}
  .modal-card h3{margin:0 0 12px;font-size:15px}
  .modal-card label{display:block;margin:10px 0 4px;font-size:12.5px;color:var(--muted)}
  .modal-card input,.modal-card select{width:100%;font:inherit;padding:6px 8px;border:1px solid var(--border);border-radius:6px}
  .preview{margin:12px 0;padding:10px 12px;background:var(--bg);border:1px solid var(--border);border-radius:8px;font-size:13px}
  .preview:empty{display:none}
  .preview .pv-line{margin:2px 0}
  .preview .pv-label{color:var(--muted);font-size:11.5px;text-transform:uppercase;letter-spacing:.03em}
  .modal-actions{display:flex;gap:10px;justify-content:flex-end;margin-top:16px}
  .err{color:#c02626;font-size:12.5px;margin:10px 0 0}
</style>
</head>
<body>
<header>
  <h1>Model Manager</h1>
  <span class="hint" id="hint">loading…</span>
  <select id="scriptSel"></select>
</header>
<div class="toolbar">
  <button class="btn" id="btnCheck">Check new versions</button>
  <button class="btn" id="btnAdd">Add model</button>
  <button class="btn" id="btnSort"></button>
  <button class="btn" id="btnSave" style="margin-left:auto">Save to git</button>
</div>
<div class="warnings" id="warnings"></div>
<main><table id="tbl">
  <thead><tr><th>Source</th><th>Model / description</th><th>Target dir</th><th>Version</th><th>Link</th><th></th></tr></thead>
  <tbody id="tbody"></tbody>
</table></main>
<details class="log"><summary>Server log</summary><pre id="log"></pre></details>

<div class="modal hidden" id="modal">
  <div class="modal-card">
    <h3>Add model to <span id="addScript"></span></h3>
    <label>Source URL (Civitai or HuggingFace)</label>
    <input id="addUrl" placeholder="https://civitai.com/models/…  |  https://huggingface.co/…  |  hf://…">
    <button class="btn" id="btnResolve">Resolve</button>
    <div class="preview" id="resolveOut"></div>
    <label>Target dir</label>
    <input id="addDir" list="dirList" placeholder="./models/loras">
    <datalist id="dirList"></datalist>
    <div id="fileWrap" style="display:none">
      <label>File in repo</label>
      <select id="addFile"></select>
    </div>
    <label>Description</label>
    <input id="addDesc" placeholder="optional comment stored on the line">
    <div class="modal-actions">
      <button class="btn" id="btnCancel">Cancel</button>
      <button class="btn primary" id="btnInsert">Insert</button>
    </div>
    <p class="err" id="addError"></p>
  </div>
</div>

<script>
'use strict';
const TOKEN = '__TOKEN__';
const $ = s => document.querySelector(s);
let models = [];
let warnings = [];
let currentScript = null;
let resolveResult = null;
let chosenFile = null;

function esc(s){
  let t = String(s == null ? '' : s);
  t = t.split('&').join('&' + 'amp;');
  t = t.split('<').join('&' + 'lt;');
  t = t.split('>').join('&' + 'gt;');
  t = t.split('"').join('&' + 'quot;');
  t = t.split("'").join('&#39;');
  return t;
}

async function api(path, opts = {}){
  const init = {
    method: opts.method || 'GET',
    headers: {'X-Auth': TOKEN}
  };
  if (opts.body){
    init.headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(opts.body);
  }
  const res = await fetch(path, init);
  let data = {};
  try { data = await res.json(); } catch (e) {}
  if (!res.ok || data.error) throw new Error(data.error || ('HTTP ' + res.status));
  return data;
}

function fmtSize(kb){
  if (kb == null) return '';
  const mb = kb / 1024;
  return (mb >= 10 ? mb.toFixed(0) : mb.toFixed(1)) + ' MB';
}

function entryTitle(m){
  if (m.source === 'civitai'){
    if (m.name) return m.name;
    if (m.kind === 'civitai-model') return 'civitai model ' + ((m.ids && m.ids.modelId) || '');
    return 'civitai version ' + ((m.ids && m.ids.versionId) || '');
  }
  return m.description || m.filename || (m.repo ? m.repo + (m.path ? '/' + m.path : '') : '');
}

function badge(cls, text, href){
  const inner = esc(text);
  return href
    ? '<a class="badge ' + cls + '" href="' + esc(href) + '" target="_blank" rel="noopener">' + inner + '</a>'
    : '<span class="badge ' + cls + '">' + inner + '</span>';
}

function versionCell(m){
  if (m.source !== 'civitai' || !m.active) return '<span class="b-dash">—</span>';
  if (m.kind === 'civitai-model'){
    return m.latestVersion
      ? '<span class="mono" style="font-size:12px">latest: ' + esc(m.latestVersion) + '</span>'
      : '<span class="b-dash">—</span>';
  }
  switch (m.versionStatus){
    case 'latest': return badge('b-latest', 'latest');
    case 'new':    return badge('b-new', 'new: ' + (m.newVersion && m.newVersion.name || ''), m.newVersion && m.newVersion.url);
    case 'unknown':return badge('b-unknown', 'unknown');
    default:       return '<span class="b-dash">—</span>';
  }
}

let sortMode = 'dir';

function sortedModels(){
  const arr = models.slice();
  if (sortMode === 'dir'){
    arr.sort((a, b) => {
      const da = (a.dir || '').toLowerCase(), db = (b.dir || '').toLowerCase();
      if (da !== db) return da < db ? -1 : 1;
      return a.lineStart - b.lineStart;
    });
  }
  return arr;
}

function render(){
  const tbody = $('#tbody');
  if (!models.length){
    tbody.innerHTML = '<tr><td colspan="6"><div class="empty">No model download calls found in this script.</div></td></tr>';
  } else {
    tbody.innerHTML = sortedModels().map(m => {
      const src = m.source === 'civitai' ? badge('b-civ','Civitai') : badge('b-hf','HF');
      const off = m.active ? '' : badge('b-off','off');
      let line1 = esc(entryTitle(m));
      let line2 = '';
      if (m.source === 'civitai'){
        if (m.description && m.name) line2 = '<div style="color:var(--muted);font-size:12px">' + esc(m.description) + '</div>';
      } else {
        line2 = '<div class="mono" style="color:var(--muted);font-size:12px">' + esc((m.repo || '') + (m.path ? '/' + m.path : '')) + '</div>';
      }
      const link = m.url
        ? '<a href="' + esc(m.url) + '" target="_blank" rel="noopener">↗</a>'
        : '';
      const toggle = '<button class="btn-xs" data-action="toggle" data-ls="' + m.lineStart + '" data-le="' + m.lineEnd + '">' + (m.active ? 'Disable' : 'Enable') + '</button>';
      const del = '<button class="btn-xs" data-action="delete" data-ls="' + m.lineStart + '" data-le="' + m.lineEnd + '" style="margin-left:6px">Delete</button>';
      return '<tr' + (m.active ? '' : ' class="off"') + '>'
        + '<td>' + src + off + '</td>'
        + '<td><div>' + line1 + '</div>' + line2 + '</td>'
        + '<td class="mono dir-cell" data-ls="' + m.lineStart + '" data-le="' + m.lineEnd + '" title="Click to edit target dir" style="cursor:pointer;text-decoration:underline dotted transparent;text-underline-offset:3px">' + esc(m.dir || '') + '</td>'
        + '<td>' + versionCell(m) + '</td>'
        + '<td>' + link + '</td>'
        + '<td style="white-space:nowrap">' + toggle + del + '</td>'
        + '</tr>';
    }).join('');
  }
  fillDirDatalist();
  $('#warnings').innerHTML = warnings.map(w => '⚠ line ' + w.line + ': ' + esc(w.reason)).join('<br>');
  $('#hint').textContent = currentScript
    ? (models.length + ' model entr' + (models.length === 1 ? 'y' : 'ies') + (warnings.length ? ' · ' + warnings.length + ' parse warning' + (warnings.length === 1 ? '' : 's') : ''))
    : 'no script loaded';
}

function fillDirDatalist(){
  const dirs = [...new Set(models.map(m => m.dir).filter(Boolean))];
  $('#dirList').innerHTML = dirs.map(d => '<option value="' + esc(d) + '">').join('');
}

function startDirEdit(cell){
  const ls = +cell.dataset.ls, le = +cell.dataset.le;
  const m = models.find(x => x.lineStart === ls && x.lineEnd === le);
  if (!m || cell.querySelector('input')) return;
  const input = document.createElement('input');
  input.className = 'dir-edit';
  input.setAttribute('list', 'dirList');
  input.value = m.dir || '';
  input.style.width = '100%';
  input.style.font = 'inherit';
  input.style.padding = '2px 4px';
  cell.textContent = '';
  cell.appendChild(input);
  input.focus();
  input.select();
  const commit = async () => {
    const dir = input.value.trim();
    restoreCell(cell, m);
    if (!dir || dir === (m.dir || '')) return;
    try {
      const r = await api('/api/movedir', {method:'POST', body:{script: currentScript, lineStart: ls, lineEnd: le, dir: dir}});
      models = r.models || [];
      render();
    } catch (e){ showErr(e); render(); }
  };
  input.addEventListener('keydown', ev => {
    if (ev.key === 'Enter') { ev.preventDefault(); input.blur(); }
    if (ev.key === 'Escape') { ev.preventDefault(); input.value = m.dir || ''; input.blur(); }
  });
  input.addEventListener('blur', commit);
}

function restoreCell(cell, m){
  cell.textContent = m.dir || '';
}

async function loadModels(script){
  currentScript = script;
  const r = await api('/api/models?script=' + encodeURIComponent(script));
  models = r.models || [];
  warnings = r.parseWarnings || [];
  render();
}

async function init(){
  let S;
  try { S = await api('/api/state'); }
  catch (e){
    document.querySelector('main').innerHTML = '<div class="empty">Server unavailable: ' + esc(e.message) + '</div>';
    return;
  }
  const sel = $('#scriptSel');
  sel.innerHTML = (S.scripts || []).map(n => '<option value="' + esc(n) + '">' + esc(n) + '</option>').join('');
  $('#log').textContent = S.logText || '';
  if (!(S.scripts || []).length){
    $('#hint').textContent = 'no *.sh scripts found in ' + 'the scripts folder';
    return;
  }
  sel.addEventListener('change', () => loadModels(sel.value).catch(showErr));
  await loadModels(sel.value).catch(showErr);
  $('#btnCheck').click();   // automatic version check at startup
}

function refreshSortBtn(){
  $('#btnSort').textContent = sortMode === 'dir' ? 'Sort: target dir' : 'Sort: file order';
}
$('#btnSort').addEventListener('click', () => {
  sortMode = (sortMode === 'dir') ? 'file' : 'dir';
  refreshSortBtn();
  render();
});
refreshSortBtn();

function showErr(e){
  $('#hint').textContent = 'error: ' + e.message;
  $('#log').textContent += (($('#log').textContent ? '\n' : '') + e.message);
}

$('#btnCheck').addEventListener('click', async () => {
  if (!currentScript) return;
  const btn = $('#btnCheck');
  btn.disabled = true; const old = btn.textContent; btn.textContent = 'Checking…';
  try {
    const r = await api('/api/check-versions', {method:'POST', body:{script: currentScript}});
    models = r.models || [];
    render();
    if (r.logText) $('#log').textContent = r.logText;
    $('#hint').textContent = 'version check done';
  } catch (e){ showErr(e); }
  btn.disabled = false; btn.textContent = old;
});

$('#tbody').addEventListener('click', async ev => {
  const dirCell = ev.target.closest('td.dir-cell');
  if (dirCell){ startDirEdit(dirCell); return; }
  const btn = ev.target.closest('button.btn-xs');
  if (!btn) return;
  const ls = +btn.dataset.ls, le = +btn.dataset.le;
  const m = models.find(x => x.lineStart === ls && x.lineEnd === le);
  if (btn.dataset.action === 'toggle'){
    try {
      const r = await api('/api/toggle', {method:'POST', body:{script: currentScript, lineStart: ls, lineEnd: le}});
      models = r.models || [];
      render();
    } catch (e){ showErr(e); }
    return;
  }
  const name = m ? entryTitle(m) : ('lines ' + ls + '-' + le);
  if (!confirm('Confirm delete ' + name + ' from ' + currentScript + '?')) return;
  try {
    const r = await api('/api/delete', {method:'POST', body:{script: currentScript, lineStart: ls, lineEnd: le}});
    models = r.models || [];
    render();
  } catch (e){ showErr(e); }
});

$('#btnSave').addEventListener('click', async () => {
  if (!currentScript) return;
  const btn = $('#btnSave');
  btn.disabled = true; const old = btn.textContent; btn.textContent = 'Saving…';
  try {
    const r = await api('/api/save', {method:'POST', body:{script: currentScript}});
    document.querySelector('details.log').open = true;
    if (r.logText) $('#log').textContent = r.logText;
    $('#hint').textContent = r.ok ? 'saved to git' : 'git save failed — see server log';
  } catch (e){ showErr(e); }
  btn.disabled = false; btn.textContent = old;
});

function openAdd(){
  resolveResult = null; chosenFile = null;
  $('#addUrl').value = ''; $('#addDir').value = ''; $('#addDesc').value = '';
  $('#resolveOut').innerHTML = ''; $('#addError').textContent = '';
  $('#fileWrap').style.display = 'none';
  $('#addScript').textContent = currentScript || '';
  fillDirDatalist();
  $('#modal').classList.remove('hidden');
  $('#addUrl').focus();
}
$('#btnAdd').addEventListener('click', openAdd);
$('#btnCancel').addEventListener('click', () => $('#modal').classList.add('hidden'));

$('#btnResolve').addEventListener('click', async () => {
  const url = $('#addUrl').value.trim();
  $('#addError').textContent = '';
  if (!url){ $('#addError').textContent = 'Paste a Civitai or HuggingFace URL first.'; return; }
  const btn = $('#btnResolve');
  btn.disabled = true;
  try {
    const r = await api('/api/resolve', {method:'POST', body:{url: url}});
    resolveResult = r.result;
    chosenFile = resolveResult.path || null;
    let html = '';
    if (resolveResult.kind === 'civitai'){
      html += '<div class="pv-line"><span class="pv-label">Civitai model</span><br>' + esc(resolveResult.modelName || resolveResult.modelId) + '</div>';
      html += '<div class="pv-line"><span class="pv-label">Version</span><br>' + esc(resolveResult.versionName || resolveResult.versionId)
        + (resolveResult.autoPinned ? ' <span class="badge b-unknown">auto: newest</span>' : '') + '</div>';
      if (resolveResult.fileName){
        html += '<div class="pv-line"><span class="pv-label">File</span><br><span class="mono">' + esc(resolveResult.fileName) + '</span>'
          + (resolveResult.sizeKB ? ' · ' + fmtSize(resolveResult.sizeKB) : '') + '</div>';
      }
    } else {
      html += '<div class="pv-line"><span class="pv-label">HF repo</span><br><span class="mono">' + esc(resolveResult.repo) + '</span></div>';
      if (resolveResult.path){
        html += '<div class="pv-line"><span class="pv-label">File</span><br><span class="mono">' + esc(resolveResult.path) + '</span></div>';
        $('#fileWrap').style.display = 'none';
      } else if (resolveResult.files && resolveResult.files.length){
        const saf = resolveResult.files.find(f => /\.safetensors$/i.test(f));
        chosenFile = saf || resolveResult.files[0];
        $('#addFile').innerHTML = resolveResult.files.map(f =>
          '<option value="' + esc(f) + '"' + (f === chosenFile ? ' selected' : '') + '>' + esc(f) + '</option>').join('');
        $('#fileWrap').style.display = '';
      } else {
        $('#addError').textContent = 'Repo has no file list; paste a URL that includes the file path.';
      }
    }
    $('#resolveOut').innerHTML = html;
    if (resolveResult.description && !$('#addDesc').value) $('#addDesc').value = resolveResult.description;
  } catch (e){
    resolveResult = null; chosenFile = null;
    $('#resolveOut').innerHTML = '';
    $('#addError').textContent = e.message;
  }
  btn.disabled = false;
});

$('#addFile').addEventListener('change', () => { chosenFile = $('#addFile').value; });

$('#btnInsert').addEventListener('click', async () => {
  const dir = $('#addDir').value.trim();
  const desc = $('#addDesc').value.trim();
  $('#addError').textContent = '';
  if (!resolveResult){ $('#addError').textContent = 'Resolve the URL first.'; return; }
  if (!dir){ $('#addError').textContent = 'Target dir is required.'; return; }
  if (resolveResult.kind === 'hf' && !chosenFile){ $('#addError').textContent = 'Pick a file in the repo.'; return; }
  const btn = $('#btnInsert');
  btn.disabled = true;
  try {
    const r = await api('/api/add', {
      method:'POST',
      body:{ script: currentScript, url: $('#addUrl').value.trim(), dir: dir, file: chosenFile || '', description: desc }
    });
    $('#modal').classList.add('hidden');
    models = r.models || [];
    render();
    $('#hint').textContent = 'added ' + entryTitle(r.entry || {});
  } catch (e){ $('#addError').textContent = e.message; }
  btn.disabled = false;
});

init();
</script>
</body>
</html>
'@

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------
try { $host.UI.RawUI.WindowTitle = 'Model manager' } catch {}

Add-Log "Model manager UI: scripts in $script:ScriptsDir"

$script:token = [guid]::NewGuid().ToString('N')

$listener = $null
$tryPort = $Port
while ($null -eq $listener -and $tryPort -lt ($Port + 20)) {
    try {
        $l = New-Object System.Net.HttpListener
        $l.Prefixes.Add("http://localhost:$tryPort/")
        $l.Start()
        $listener = $l
    }
    catch {
        $tryPort++
    }
}
if (-not $listener) {
    throw "Could not bind a local HTTP port in range $Port..$($Port + 19). Close the other instance or free the ports."
}
$Port = $tryPort
Add-Log "Model manager UI: http://localhost:$Port/  (Ctrl+C to stop)"

if (-not $NoBrowser) {
    Start-Process "http://localhost:$Port/"
}

function Send-Json {
    param($Context, $Object, [int]$Status = 200)
    $json = $Object | ConvertTo-Json -Depth 12
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Context.Response.StatusCode = $Status
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Send-Html {
    param($Context, $Html)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Html)
    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = 'text/html; charset=utf-8'
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Read-JsonBody {
    param($Context)
    $reader = New-Object System.IO.StreamReader($Context.Request.InputStream, [System.Text.Encoding]::UTF8)
    $raw = $reader.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ConvertTo-HashtableDeep (ConvertFrom-Json $raw)
}

function ConvertTo-HashtableDeep {
    param($Value)
    if ($Value -is [System.Collections.IDictionary]) {
        $hash = @{}
        foreach ($key in $Value.Keys) { $hash[$key] = ConvertTo-HashtableDeep $Value[$key] }
        return $hash
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $hash = @{}
        foreach ($property in $Value.PSObject.Properties) { $hash[$property.Name] = ConvertTo-HashtableDeep $property.Value }
        return $hash
    }
    return $Value
}

while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    try {
        $req = $ctx.Request
        $path = $req.Url.AbsolutePath

        if ($path -eq '/' -and $req.HttpMethod -eq 'GET') {
            Send-Html $ctx ($script:htmlTemplate.Replace('__TOKEN__', $script:token))
            continue
        }

        if (-not $path.StartsWith('/api/')) {
            Send-Json $ctx @{ error = 'Not found' } 404
            continue
        }

        $origin = $req.Headers['Origin']
        $expectedOrigin = "http://localhost:$Port"
        if ($origin -and $origin -ne $expectedOrigin) {
            Send-Json $ctx @{ error = 'Cross-origin requests are not allowed.' } 403
            continue
        }
        if ($req.Headers['X-Auth'] -ne $script:token) {
            Send-Json $ctx @{ error = 'Unauthorized UI request.' } 403
            continue
        }

        $body = $null
        if ($req.HttpMethod -eq 'POST') { $body = Read-JsonBody $ctx }

        switch ($path) {
            '/api/state' {
                $scripts = @(Get-ChildItem -LiteralPath $script:ScriptsDir -Filter '*.sh' -File |
                    Sort-Object Name | ForEach-Object { $_.Name })
                Send-Json $ctx @{
                    scripts = $scripts
                    current = $null
                    logText = (Get-LogTailText)
                }
            }
            '/api/models' {
                $name = [string]$req.QueryString['script']
                $p = Resolve-ScriptPath $name
                $r = Get-ScriptModels $p
                Merge-CivitaiCache -ScriptName $name -Models $r.models
                Send-Json $ctx @{
                    models         = $r.models
                    parseWarnings  = $r.warnings
                }
            }
            '/api/check-versions' {
                $name = [string]$body['script']
                $p = Resolve-ScriptPath $name
                $r = Get-ScriptModels $p
                Update-CivitaiInfo -Models $r.models -ScriptName $name
                Send-Json $ctx @{
                    models  = $r.models
                    logText = (Get-LogTailText)
                }
            }
            '/api/delete' {
                $name = [string]$body['script']
                $p = Resolve-ScriptPath $name
                $ls = [int]$body['lineStart']
                $le = [int]$body['lineEnd']
                Remove-EntryLines -Path $p -LineStart $ls -LineEnd $le
                Purge-ScriptCache $name
                $r = Get-ScriptModels $p
                Add-Log "Deleted lines $ls-$le from $name"
                Send-Json $ctx @{ ok = $true; models = $r.models }
            }
            '/api/toggle' {
                $name = [string]$body['script']
                $p = Resolve-ScriptPath $name
                $ls = [int]$body['lineStart']
                $le = [int]$body['lineEnd']
                $newActive = Toggle-EntryActive -Path $p -LineStart $ls -LineEnd $le
                $r = Get-ScriptModels $p
                Merge-CivitaiCache -ScriptName $name -Models $r.models
                Add-Log ("Toggled entry at lines {0}-{1} in {2} to {3}" -f $ls, $le, $name, $(if ($newActive) { 'active' } else { 'inactive' }))
                Send-Json $ctx @{ ok = $true; active = $newActive; models = $r.models }
            }
            '/api/movedir' {
                $name = [string]$body['script']
                $p = Resolve-ScriptPath $name
                $ls = [int]$body['lineStart']
                $le = [int]$body['lineEnd']
                $dir = [string]$body['dir']
                Set-EntryDir -Path $p -LineStart $ls -LineEnd $le -NewDir $dir
                $r = Get-ScriptModels $p
                Merge-CivitaiCache -ScriptName $name -Models $r.models
                Add-Log "Changed target dir of lines $ls-$le in $name to '$dir'"
                Send-Json $ctx @{ ok = $true; models = $r.models }
            }
            '/api/save' {
                $name = [string]$body['script']
                $null = Resolve-ScriptPath $name
                $output = New-Object System.Collections.Generic.List[string]
                $ok = $false
                $repo = Invoke-GitStep -GitArgs @('rev-parse', '--is-inside-work-tree')
                foreach ($l in $repo.lines) { $output.Add($l) }
                if ($repo.code -ne 0) {
                    $output.Add("Not a git repository: $script:ScriptsDir")
                }
                else {
                    $add = Invoke-GitStep -GitArgs @('add', '--', $name)
                    foreach ($l in $add.lines) { $output.Add($l) }
                    $commit = Invoke-GitStep -GitArgs @('commit', '-m', "Update $name via model manager UI")
                    foreach ($l in $commit.lines) { $output.Add($l) }
                    if ($commit.code -ne 0 -and (@($commit.lines | Where-Object { $_ -match 'no changes added to commit|nothing to commit|nothing added to commit' })).Count -gt 0) {
                        $output.Add('Nothing to commit; skipping push.')
                        $ok = $true
                    }
                    elseif ($commit.code -ne 0) {
                        $output.Add("git commit failed with exit code $($commit.code).")
                    }
                    else {
                        $push = Invoke-GitStep -GitArgs @('push')
                        foreach ($l in $push.lines) { $output.Add($l) }
                        if ($push.code -ne 0 -and (@($push.lines | Where-Object { $_ -match 'no upstream' })).Count -gt 0) {
                            $output.Add('No upstream configured; pushing with --set-upstream origin HEAD.')
                            $push = Invoke-GitStep -GitArgs @('push', '-u', 'origin', 'HEAD')
                            foreach ($l in $push.lines) { $output.Add($l) }
                        }
                        if ($push.code -eq 0) {
                            $ok = $true
                            $output.Add("Pushed $name.")
                        }
                        else {
                            $output.Add("git push failed with exit code $($push.code).")
                        }
                    }
                }
                foreach ($l in $output) { Add-Log "git: $l" }
                Send-Json $ctx @{ ok = $ok; output = $output; logText = (Get-LogTailText) }
            }
            '/api/resolve' {
                $url = [string]$body['url']
                $result = Resolve-ModelUrl -Url $url -HfFile ''
                Send-Json $ctx @{ ok = $true; result = $result }
            }
            '/api/add' {
                $name = [string]$body['script']
                $p = Resolve-ScriptPath $name
                $url = [string]$body['url']
                $dir = ([string]$body['dir']).Trim()
                $desc = ([string]$body['description']).Trim()
                $hfFile = [string]$body['file']
                if ([string]::IsNullOrWhiteSpace($dir)) { throw 'Target dir is required.' }
                $resolved = Resolve-ModelUrl -Url $url -HfFile $hfFile

                if ($resolved.kind -eq 'civitai') {
                    $form = Get-DominantCivitaiForm $p
                    $vid = [string]$resolved.versionId
                    $suffix = ''
                    if ($desc) { $suffix = " # $desc" }
                    switch ($form) {
                        'flag' { $line = "civitai download --version $vid --out-dir $dir$suffix" }
                        'bare' { $line = "civitai download $vid --out-dir $dir$suffix" }
                        default { $line = "download_civitai_primary $vid $dir$suffix" }
                    }
                    $newLines = @($line)
                    $entry = [ordered]@{
                        source = 'civitai'; kind = 'civitai-version'
                        ids = @{ versionId = $vid }; dir = $dir; description = $desc
                        url = "https://civitai.com/models/$($resolved.modelId)"; name = ''
                    }
                }
                else {
                    $repo = [string]$resolved.repo
                    $hpath = [string]$resolved.path
                    if ([string]::IsNullOrWhiteSpace($hpath)) { throw 'No file path resolved for the HuggingFace URL.' }
                    $fileName = [string]$resolved.fileName
                    if ([string]::IsNullOrWhiteSpace($fileName)) { $fileName = [System.IO.Path]::GetFileName($hpath) }
                    $dest = $dir.TrimEnd('/') + '/' + $fileName
                    $newLines = @(
                        'download_hf_file \',
                        "  $repo \",
                        "  $hpath \",
                        "  $dest"
                    )
                    $entry = [ordered]@{
                        source = 'hf'; kind = 'hf-file'
                        ids = @{}; dir = $dir; description = $desc
                        url = "https://huggingface.co/$repo"; repo = $repo; path = $hpath; filename = $fileName
                    }
                }
                $pos = Insert-EntryLines -Path $p -NewLines $newLines
                Purge-ScriptCache $name
                $r = Get-ScriptModels $p
                Add-Log "Added $($resolved.kind) entry to $name at line $($pos + 2)"
                Send-Json $ctx @{ ok = $true; entry = $entry; models = $r.models }
            }
            default {
                Send-Json $ctx @{ error = 'Not found' } 404
            }
        }
    }
    catch {
        $message = $_.Exception.Message
        try { Send-Json $ctx @{ error = "$message"; logText = (Get-LogTailText) } 500 } catch {}
    }
}
