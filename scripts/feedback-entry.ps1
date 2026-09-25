param(
    [ValidateSet('inject', 'validate')]
    [string]$Mode = 'inject',
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$FeedbackBaseUrl = 'https://dnd3r-feedback-public-dnd3r-feedback-d4gwz9pp1575ec082.webapps.tcloudbase.com/'
)

$ErrorActionPreference = 'Stop'

$Marker = 'dnd3r-feedback-entry'
$ButtonLabel = '&#x53cd;&#x9988;&#x672c;&#x9875;&#x52d8;&#x8bef;'
$TextEncoding936 = [Text.Encoding]::GetEncoding(936)
$FeedbackExcludedPageRefs = @('译者名录1.1.htm')

function Get-TextEncoding([byte[]]$Bytes) {
    if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 239 -and $Bytes[1] -eq 187 -and $Bytes[2] -eq 191) {
        return [Text.UTF8Encoding]::new($true)
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 255 -and $Bytes[1] -eq 254) {
        return [Text.UnicodeEncoding]::new($false, $true)
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 254 -and $Bytes[1] -eq 255) {
        return [Text.UnicodeEncoding]::new($true, $true)
    }
    return $TextEncoding936
}

function Read-TextFile([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $encoding = Get-TextEncoding $bytes
    return [pscustomobject]@{
        Text = $encoding.GetString($bytes)
        Encoding = $encoding
    }
}

function Write-TextFile([string]$Path, [string]$Text, [Text.Encoding]$Encoding) {
    [IO.File]::WriteAllBytes($Path, $Encoding.GetBytes($Text))
}

function Normalize-PageRef([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    return ($Value.Trim() -replace '\\', '/') -replace '^\./', ''
}

function Get-ParamValue([string]$ObjectText, [string]$Name) {
    $escapedName = [Regex]::Escape($Name)
    $pattern = '(?is)<param\s+name\s*=\s*["'']' + $escapedName + '["'']\s+value\s*=\s*["''](?<value>.*?)["'']\s*/?>'
    $match = [Regex]::Match($ObjectText, $pattern)
    if ($match.Success) { return [Net.WebUtility]::HtmlDecode($match.Groups['value'].Value).Trim() }
    return ''
}

function Get-ContentsIndex([string]$ContentsPath) {
    $contents = (Read-TextFile $ContentsPath).Text
    $tokenPattern = '(?is)(?<ul><ul\b[^>]*>|</ul\s*>)|(?<object><object\b[^>]*>.*?</object\s*>)'
    $matches = [Regex]::Matches($contents, $tokenPattern)
    $stack = [Collections.Generic.List[string]]::new()
    $pendingName = ''
    $index = @{}

    foreach ($match in $matches) {
        if ($match.Groups['ul'].Success) {
            $token = $match.Groups['ul'].Value.TrimStart()
            if ($token.StartsWith('</')) {
                if ($stack.Count -gt 0) { $stack.RemoveAt($stack.Count - 1) }
            } elseif ($pendingName) {
                $stack.Add($pendingName)
                $pendingName = ''
            }
            continue
        }

        $objectText = $match.Groups['object'].Value
        $name = Get-ParamValue $objectText 'Name'
        $local = Normalize-PageRef (Get-ParamValue $objectText 'Local')
        if ($local -and $local -match '\.(?:html?|xhtml)(?:#.*)?$' -and -not $index.ContainsKey($local)) {
            $index[$local] = [pscustomobject]@{
                Name = $name
                Parents = @($stack)
            }
        }
        $pendingName = $name
    }

    return $index
}

function Get-PageFiles([string]$Root) {
    return @(Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object {
        $_.Extension.ToLowerInvariant() -in @('.htm', '.html') -and $_.FullName -notmatch '[\\/]\.git[\\/]'
    })
}

function Get-PageRef([string]$FullPath, [string]$Root) {
    $rootFull = ([IO.Path]::GetFullPath($Root)).TrimEnd('\') + '\'
    $fullPath = [IO.Path]::GetFullPath($FullPath)
    if (-not $fullPath.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Page is outside repository root: $FullPath"
    }
    $relative = $fullPath.Substring($rootFull.Length)
    return Normalize-PageRef $relative
}

function Test-FeedbackExcluded([string]$PageRef) {
    return $PageRef -in $FeedbackExcludedPageRefs
}

function Assert-NoFeedbackEntry($File, [string]$PageRef) {
    $read = Read-TextFile $File.FullName
    if ($read.Text.Contains($Marker)) {
        throw "Feedback-excluded page contains a feedback entry: $PageRef"
    }
}

function Get-SourceContext([string]$PageRef, $Index) {
    $segments = @($PageRef -split '/')
    $fallbackBook = if ($segments.Count -ge 2) { $segments[1] } elseif ($segments.Count -eq 1) { $segments[0] } else { '' }
    $fallbackChapter = if ($segments.Count -ge 3) { $segments[2] } else { '' }
    $fallbackTitle = [IO.Path]::GetFileNameWithoutExtension($segments[-1])
    $entry = if ($Index.ContainsKey($PageRef)) { $Index[$PageRef] } else { $null }
    $parents = if ($entry) { @($entry.Parents | Where-Object { $_ }) } else { @() }
    $chapter = if ($parents.Count -gt 0) { ($parents | Select-Object -Last 3) -join ' / ' } else { $fallbackChapter }
    $title = if ($entry -and $entry.Name) { $entry.Name } else { $fallbackTitle }
    return [pscustomobject]@{
        Book = $fallbackBook
        Chapter = $chapter
        Title = $title
    }
}

function Encode-QueryValue([string]$Value) {
    return [Uri]::EscapeDataString($Value)
}

function New-FeedbackUrl([string]$PageRef, $Context) {
    $base = $FeedbackBaseUrl.TrimEnd('/') + '/'
    $query = 'page_ref=' + (Encode-QueryValue $PageRef) +
        '&book=' + (Encode-QueryValue $Context.Book) +
        '&chapter=' + (Encode-QueryValue $Context.Chapter) +
        '&title=' + (Encode-QueryValue $Context.Title)
    return $base + '?' + $query
}

function New-FeedbackMarkup([string]$Url) {
    $safeUrl = [Net.WebUtility]::HtmlEncode($Url)
    return @"
<!-- DND3R-FEEDBACK-BEGIN -->
<div class="dnd3r-feedback-entry" role="navigation" aria-label="&#x9875;&#x9762;&#x53cd;&#x9988;&#x5165;&#x53e3;" style="clear:both;margin:2.5em auto 1.5em;text-align:center;">
  <a href="$safeUrl" target="_blank" rel="noopener noreferrer" style="display:inline-block;padding:0.55em 1.25em;border:1px solid #5c7356;border-radius:999px;background:#f4efe6;color:#3f4f3b;text-decoration:none;font-family:'Microsoft YaHei','Noto Sans SC',sans-serif;font-size:0.95em;line-height:1.4;">$ButtonLabel</a>
</div>
<!-- DND3R-FEEDBACK-END -->
"@
}

function Inject-FeedbackEntry($File, [string]$PageRef, $Index) {
    $read = Read-TextFile $File.FullName
    $context = Get-SourceContext $PageRef $Index
    $url = New-FeedbackUrl $PageRef $context
    if ($read.Text.Contains($Marker)) {
        $blockPattern = '(?is)<!--\s*DND3R-FEEDBACK-BEGIN\s*-->.*?<!--\s*DND3R-FEEDBACK-END\s*-->'
        $blockMatch = [Regex]::Match($read.Text, $blockPattern)
        if ($blockMatch.Success) {
            $markup = New-FeedbackMarkup $url
            $updated = $read.Text.Remove($blockMatch.Index, $blockMatch.Length).Insert($blockMatch.Index, $markup)
            Write-TextFile $File.FullName $updated $read.Encoding
            return 'updated'
        }
        return 'already'
    }
    $markup = New-FeedbackMarkup $url
    $closeMatches = [Regex]::Matches($read.Text, '</body\s*>', [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($closeMatches.Count -gt 0) {
        $close = $closeMatches[$closeMatches.Count - 1]
        $updated = $read.Text.Insert($close.Index, "`r`n$markup`r`n")
    } else {
        $updated = $read.Text + "`r`n$markup`r`n"
    }
    Write-TextFile $File.FullName $updated $read.Encoding
    return 'injected'
}

function Get-FeedbackHref([string]$Text) {
    $match = [Regex]::Match($Text, '(?is)<div\s+class=["'']dnd3r-feedback-entry["''].*?<a\s+href=["''](?<href>.*?)["'']')
    if ($match.Success) { return [Net.WebUtility]::HtmlDecode($match.Groups['href'].Value) }
    return ''
}

function Validate-FeedbackEntry($File, [string]$PageRef, $Index) {
    $read = Read-TextFile $File.FullName
    $matches = [Regex]::Matches($read.Text, [Regex]::Escape($Marker))
    $context = Get-SourceContext $PageRef $Index
    $expectedUrl = New-FeedbackUrl $PageRef $context
    $href = Get-FeedbackHref $read.Text
    $issues = [Collections.Generic.List[string]]::new()
    if ($matches.Count -ne 1) { $issues.Add("marker_count=$($matches.Count)") }
    if (-not $href) { $issues.Add('missing_href') }
    if ($href -ne $expectedUrl) { $issues.Add('href_mismatch') }
    try {
        $uri = [Uri]$href
        if ($uri.Scheme -ne 'https' -or $uri.Host -ne ([Uri]$FeedbackBaseUrl).Host) { $issues.Add('unexpected_host') }
        $params = @{}
        foreach ($pair in $uri.Query.TrimStart('?').Split('&')) {
            $parts = $pair.Split('=', 2)
            if ($parts.Count -eq 2) {
                $params[$parts[0]] = [Uri]::UnescapeDataString($parts[1].Replace('+', ' '))
            }
        }
        if ($params['page_ref'] -ne $PageRef) { $issues.Add('page_ref_mismatch') }
        if ([string]::IsNullOrWhiteSpace($params['book']) -or [string]::IsNullOrWhiteSpace($params['title'])) { $issues.Add('missing_context') }
    } catch {
        $issues.Add('invalid_url:' + $_.Exception.GetType().FullName + ':' + $_.Exception.Message)
    }
    return [pscustomobject]@{
        File = $File.FullName
        PageRef = $PageRef
        Href = $href
        Issues = @($issues)
        IsValid = ($issues.Count -eq 0)
    }
}

$contentsPath = Join-Path $RepoRoot 'Contents.hhc'
$index = Get-ContentsIndex $contentsPath
$pages = Get-PageFiles $RepoRoot
if ($pages.Count -eq 0) { throw "No HTML pages found under $RepoRoot" }

if ($Mode -eq 'inject') {
    $counts = @{ injected = 0; updated = 0; already = 0 }
    $excluded = 0
    foreach ($file in $pages) {
        $pageRef = Get-PageRef $file.FullName $RepoRoot
        if (Test-FeedbackExcluded $pageRef) {
            Assert-NoFeedbackEntry $file $pageRef
            $excluded++
            continue
        }
        $result = Inject-FeedbackEntry $file $pageRef $index
        $counts[$result]++
    }
    [pscustomobject]@{
        Mode = $Mode
        Pages = $pages.Count
        Excluded = $excluded
        ContentsIndexEntries = $index.Count
        Injected = $counts.injected
        Updated = $counts.updated
        AlreadyInjected = $counts.already
    } | Format-List
} else {
    $excluded = 0
    $results = foreach ($file in $pages) {
        $pageRef = Get-PageRef $file.FullName $RepoRoot
        if (Test-FeedbackExcluded $pageRef) {
            Assert-NoFeedbackEntry $file $pageRef
            $excluded++
            continue
        }
        Validate-FeedbackEntry $file $pageRef $index
    }
    $invalid = @($results | Where-Object { -not $_.IsValid })
    $reportPath = Join-Path $RepoRoot 'feedback-entry-validation.json'
    $results | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $reportPath -Encoding UTF8
    [pscustomobject]@{
        Mode = $Mode
        Pages = $pages.Count
        Excluded = $excluded
        Valid = $results.Count - $invalid.Count
        Invalid = $invalid.Count
        ContentsIndexEntries = $index.Count
        Report = $reportPath
    } | Format-List
    if ($invalid.Count -gt 0) {
        $invalid | Select-Object -First 20 File,PageRef,Issues | Format-List
        exit 2
    }
}
