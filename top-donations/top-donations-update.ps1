# ============================================================
#  ТОП ДОНАТОВ ИЗ DONATIONALERTS
# ============================================================
# Что делает:
#   1. Берёт secretToken из top-donations-config.json.
#   2. Открывает страницу виджета lastdonations и читает последние донаты.
#   3. Считает сумму по каждому донатеру.
#   4. Записывает топ в top-donations-data.js.
#
# Официальный OAuth API не нужен: используется тот же secretToken,
# который DonationAlerts выдаёт для виджетов.
#
# Запуск один раз:
#   powershell -ExecutionPolicy Bypass -File top-donations-update.ps1 -Once
#
# Постоянное обновление (окно должно быть открыто):
#   powershell -ExecutionPolicy Bypass -File top-donations-update.ps1
#
# Проверка подсчёта без интернета:
#   powershell -ExecutionPolicy Bypass -File top-donations-update.ps1 -SelfTest
#
# На macOS используйте top-donations-update.py — PowerShell там не обязателен.
# ============================================================

param(
    [switch]$Once,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
    # На старых версиях PowerShell этот параметр может отсутствовать
}

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$configPath = Join-Path $scriptRoot 'top-donations-config.json'
$dataPath = Join-Path $scriptRoot 'top-donations-data.js'
$apiBase = 'https://www.donationalerts.com'
$userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) TopDonationsOverlay/1.0'

function Write-Step {
    param([string]$Text)
    Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Text)
}

function Get-DefaultConfig {
    [pscustomobject]@{
        secretToken = ''
        accessToken = ''
        topCount = 0
        periodDays = 0
        maxPages = 0
        refreshSeconds = 300
        displayCurrency = 'RUB'
        skipAnonymous = $false
    }
}

function Read-Config {
    if (!(Test-Path -LiteralPath $configPath)) {
        Get-DefaultConfig | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
        throw 'Создан top-donations-config.json. Впишите secretToken и запустите снова.'
    }

    $raw = Get-Content -Raw -LiteralPath $configPath -Encoding UTF8 | ConvertFrom-Json

    # Добавляем поля, которых нет в старом конфиге
    foreach ($prop in (Get-DefaultConfig).PSObject.Properties) {
        $current = $raw.PSObject.Properties[$prop.Name]
        if ($null -eq $current -or $null -eq $current.Value) {
            $raw | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
        }
    }

    $raw.topCount = [int]$raw.topCount
    # 0 = показывать всех донатеров (без обрезки), больше 0 = первые N мест
    if ($raw.topCount -lt 0) { $raw.topCount = 0 }
    if ($raw.topCount -gt 20) { $raw.topCount = 20 }

    $raw.periodDays = [int]$raw.periodDays
    if ($raw.periodDays -lt 0) { $raw.periodDays = 0 }

    $raw.maxPages = [int]$raw.maxPages
    if ($raw.maxPages -lt 0) { $raw.maxPages = 0 }

    $raw.refreshSeconds = [int]$raw.refreshSeconds
    if ($raw.refreshSeconds -lt 30) { $raw.refreshSeconds = 30 }

    return $raw
}

# Разбирает JavaScript-строку в кавычках: убирает экранирование \" \\ \/ \uXXXX.
function ConvertFrom-JsStringLiteral {
    param([string]$Text)

    $builder = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $char = $Text[$i]
        if ($char -ne '\') {
            [void]$builder.Append($char)
            continue
        }

        $i++
        if ($i -ge $Text.Length) { break }

        $next = $Text[$i]
        switch ($next) {
            '"' { [void]$builder.Append('"') }
            "'" { [void]$builder.Append("'") }
            '\' { [void]$builder.Append('\') }
            '/' { [void]$builder.Append('/') }
            'b' { [void]$builder.Append([char]8) }
            'f' { [void]$builder.Append([char]12) }
            'n' { [void]$builder.Append([char]10) }
            'r' { [void]$builder.Append([char]13) }
            't' { [void]$builder.Append([char]9) }
            'u' {
                if ($i + 4 -lt $Text.Length) {
                    $hex = $Text.Substring($i + 1, 4)
                    $i += 4
                    try {
                        [void]$builder.Append([char][Convert]::ToInt32($hex, 16))
                    } catch {}
                }
            }
            default { [void]$builder.Append($next) }
        }
    }

    return $builder.ToString()
}

# Страница lastdonations отдаёт последние донаты без OAuth.
# В HTML они лежат вызовами addEvent('...'); настройки — в handleGeneralWidgetSettings('...').
function Get-WidgetData {
    param(
        [string]$SecretToken,
        [int]$Limit = 100
    )

    if ([string]::IsNullOrWhiteSpace($SecretToken)) {
        throw 'В top-donations-config.json не заполнен secretToken.'
    }

    $url = "$apiBase/widget/lastdonations?alert_type=1,12&limit=$Limit&token=" + [uri]::EscapeDataString($SecretToken)
    Write-Step 'Загружаю последние донаты из виджета DonationAlerts...'
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 30 -Headers @{ 'User-Agent' = $userAgent }
    } catch {
        $message = $_.Exception.Message
        if ($message.Contains($SecretToken)) { $message = $message.Replace($SecretToken, '***') }
        throw "Не удалось загрузить страницу виджета DonationAlerts: $message"
    }
    $html = [string]$response.Content

    $events = @()
    $eventMatches = [regex]::Matches($html, "addEvent\('(?<json>(?:\\.|[^'])*)'\)")
    foreach ($match in $eventMatches) {
        try {
            $json = ConvertFrom-JsStringLiteral $match.Groups['json'].Value
            $event = $json | ConvertFrom-Json
            if ($null -ne $event) { $events += $event }
        } catch {
            Write-Warning 'Пропущено событие: не удалось разобрать данные.'
        }
    }

    $currency = ''
    $settingsMatch = [regex]::Match($html, "handleGeneralWidgetSettings\('(?<json>(?:\\.|[^'])*)'\)")
    if ($settingsMatch.Success) {
        try {
            $settingsJson = ConvertFrom-JsStringLiteral $settingsMatch.Groups['json'].Value
            $settings = $settingsJson | ConvertFrom-Json
            $currency = [string]$settings.main_currency
        } catch {}
    }

    if ($events.Count -eq 0 -and !$settingsMatch.Success) {
        throw 'Не удалось прочитать данные виджета. Проверьте secretToken.'
    }

    return [pscustomobject]@{
        Events = @($events)
        Currency = $currency
        Limit = $Limit
    }
}

function Convert-DonationDate {
    param($Donation)

    $timestampValue = if ($null -ne $Donation.created_at_ts) { $Donation.created_at_ts } else { $Donation.date_created_ts }
    if ($null -ne $timestampValue) {
        $timestamp = [int64]$timestampValue
        if ($timestamp -gt 100000000000) { $timestamp = [int64]($timestamp / 1000) }
        if ($timestamp -gt 0) {
            return [DateTimeOffset]::FromUnixTimeSeconds($timestamp).LocalDateTime
        }
    }

    $dateValue = [string]$Donation.created_at
    if ([string]::IsNullOrWhiteSpace($dateValue)) { $dateValue = [string]$Donation.date_created }

    if (![string]::IsNullOrWhiteSpace($dateValue)) {
        try {
            return [datetime]::ParseExact(
                $dateValue,
                'yyyy-MM-dd HH:mm:ss',
                [Globalization.CultureInfo]::InvariantCulture
            )
        } catch {}
    }

    return $null
}

function Filter-DonationsByPeriod {
    param(
        $Donations,
        [int]$PeriodDays
    )

    if ($PeriodDays -le 0) {
        return @($Donations)
    }

    $cutoff = (Get-Date).AddDays(-$PeriodDays)
    $result = @()
    foreach ($donation in @($Donations)) {
        $created = Convert-DonationDate $donation
        if ($null -eq $created -or $created -ge $cutoff) {
            $result += $donation
        }
    }

    return $result
}

# Суммирует донаты по нику. Для разных валют берёт amount_in_user_currency,
# если DonationAlerts его прислал (это сумма в валюте стримера).
function Get-TopDonors {
    param(
        $Donations,
        [int]$TopCount,
        [bool]$SkipAnonymous,
        [string]$Currency
    )

    $users = @{}
    $anonymousNames = @('anonymous', 'аноним', 'анонимный', 'гость')

    foreach ($donation in @($Donations)) {
        $name = ([string]$donation.username).Trim()
        $isAnonymous = [string]::IsNullOrWhiteSpace($name) -or ($anonymousNames -contains $name.ToLowerInvariant())

        if ($isAnonymous -and $SkipAnonymous) { continue }
        if ($isAnonymous) { $name = 'Аноним' }

        $alertType = [string]$donation.alert_type
        if (![string]::IsNullOrWhiteSpace($alertType) -and @('1', '12') -notcontains $alertType) {
            continue
        }

        $amount = 0.0
        # amount_main — сумма в основной валюте стримера (REST API).
        # amount_in_user_currency — то же самое в socket-событиях.
        if ($null -ne $donation.amount_main -and [double]$donation.amount_main -gt 0) {
            $amount = [double]$donation.amount_main
        } elseif ($null -ne $donation.amount_in_user_currency -and [double]$donation.amount_in_user_currency -gt 0) {
            $amount = [double]$donation.amount_in_user_currency
        } elseif ($null -ne $donation.amount) {
            $amount = [double]$donation.amount
        }
        if ($amount -le 0) { continue }

        $key = $name.ToLowerInvariant()
        if (!$users.ContainsKey($key)) {
            $users[$key] = [pscustomobject]@{
                username = $name
                amount = 0.0
                donations = 0
                currency = $Currency
            }
        }

        $users[$key].amount += $amount
        $users[$key].donations += 1
    }

    $limit = if ($TopCount -gt 0) { $TopCount } else { $users.Count }
    if ($users.Count -eq 0) { $limit = 0 }

    return @(
        $users.Values |
            Sort-Object -Property @{ Expression = 'amount'; Descending = $true }, @{ Expression = 'username'; Descending = $false } |
            Select-Object -First $limit
    )
}

function Write-TopFile {
    param(
        $Top,
        [string]$Currency,
        [string]$PeriodLabel
    )

    $rows = @()
    foreach ($item in @($Top)) {
        $rows += [ordered]@{
            username = [string]$item.username
            amount = [Math]::Round([double]$item.amount, 2)
            currency = $Currency
            donations = [int]$item.donations
        }
    }

    # ConvertTo-Json в PowerShell 5.1 для одного элемента может вернуть объект,
    # поэтому при необходимости добавляем квадратные скобки вручную.
    $json = ConvertTo-Json -InputObject $rows -Depth 4
    if ([string]::IsNullOrWhiteSpace($json)) { $json = '[]' }
    if (!$json.TrimStart().StartsWith('[')) { $json = '[' + $json + ']' }

    $timestamp = [DateTimeOffset]::Now.ToUnixTimeSeconds()

    $content = @"
// Этот файл создаётся автоматически (top-donations-update.ps1)
// Обновлено: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
window.TOP_DONATIONS = $json;
window.TOP_DONATIONS_CURRENCY = '$Currency';
window.TOP_DONATIONS_PERIOD = '$PeriodLabel';
window.TOP_DONATIONS_UPDATED = $timestamp;
window.TOP_DONATIONS_IS_DEMO = false;
"@

    Set-Content -LiteralPath $dataPath -Value $content -Encoding UTF8
    Write-Step "Готово. В топе мест: $(@($rows).Count), валюта: $Currency."
}

function Update-TopDonations {
    $config = Read-Config

    $secret = ([string]$config.secretToken).Trim()
    if ([string]::IsNullOrWhiteSpace($secret)) {
        throw 'В top-donations-config.json не заполнен secretToken.'
    }

    $widget = Get-WidgetData -SecretToken $secret -Limit 100
    $currency = [string]$widget.Currency
    if ([string]::IsNullOrWhiteSpace($currency)) { $currency = [string]$config.displayCurrency }
    $currency = ($currency -replace '[^A-Za-z]', '').ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($currency)) { $currency = 'RUB' }

    $donations = @(Filter-DonationsByPeriod -Donations $widget.Events -PeriodDays ([int]$config.periodDays))
    Write-Step "Загружено донатов: $($donations.Count)."

    $top = @(Get-TopDonors -Donations $donations -TopCount ([int]$config.topCount) -SkipAnonymous ([bool]$config.skipAnonymous) -Currency $currency)

    $periodLabel = if ([int]$config.periodDays -gt 0) {
        "за $($config.periodDays) дн."
    } elseif (@($widget.Events).Count -ge [int]$widget.Limit) {
        'по последним донатам'
    } else {
        'за всё время'
    }

    Write-TopFile -Top $top -Currency $currency -PeriodLabel $periodLabel
}

# ============================================================
#  ЗАПУСК
# ============================================================

if ($SelfTest) {
    $sample = @(
        [pscustomobject]@{ username = 'Ivan'; amount = 100; amount_in_user_currency = 100 },
        [pscustomobject]@{ username = 'ivan'; amount = 50; amount_in_user_currency = 50 },
        [pscustomobject]@{ username = 'Masha'; amount = 100; amount_main = 300 },
        [pscustomobject]@{ username = 'Anonymous'; amount = 999; amount_in_user_currency = 999 },
        [pscustomobject]@{ username = 'Oleg'; amount = 0; amount_in_user_currency = 0 }
    )

    $top = @(Get-TopDonors -Donations $sample -TopCount 3 -SkipAnonymous $true -Currency 'RUB')
    $top | Format-Table username, amount, donations -AutoSize
    return
}

if ($Once) {
    Update-TopDonations
    exit 0
}

while ($true) {
    try {
        Update-TopDonations
    } catch {
        Write-Host "Ошибка: $($_.Exception.Message)" -ForegroundColor Red
    }

    $seconds = 300
    try {
        $seconds = [int](Read-Config).refreshSeconds
    } catch {}
    if ($seconds -lt 30) { $seconds = 30 }

    Write-Host "Следующее обновление через $seconds сек. Окно не закрывайте."
    Start-Sleep -Seconds $seconds
}
