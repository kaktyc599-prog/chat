# ============================================================
#  Мгновенное обновление топа донатов (Windows)
#
#  Подключается к каналу DonationAlerts по WebSocket и ждёт
#  событие "donation". Как только донат пришёл — сразу
#  запускает top-donations-update.ps1 -Once, то есть
#  перезаписывает top-donations-data.js свежим топом.
#
#  Запуск:
#    start-top-donations.bat
#  или
#    powershell -NoProfile -ExecutionPolicy Bypass -File top-donations-listen.ps1
#
#  Окно закрывать нельзя: пока оно открыто — реакция мгновенная.
#  Если соединение оборвётся, скрипт переподключится сам.
# ============================================================

param(
    # Страховочное обновление по таймеру, секунды (0 = брать из конфига).
    [int]$FallbackSeconds = 0
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($root)) {
    $root = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$configPath = Join-Path $root 'top-donations-config.json'
$updaterPath = Join-Path $root 'top-donations-update.ps1'
$socketUrl = 'wss://socket4.donationalerts.com:443/socket.io/?EIO=3&transport=websocket'

function Write-Log {
    param(
        [string]$Text,
        [string]$Color = 'Gray'
    )
    Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Text) -ForegroundColor $Color
}

function Read-Settings {
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "Не найден top-donations-config.json рядом со скриптом: $configPath"
    }

    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $token = ([string]$config.secretToken).Trim()
    if ([string]::IsNullOrWhiteSpace($token)) {
        throw 'В top-donations-config.json не заполнен secretToken.'
    }

    $fallback = $FallbackSeconds
    if ($fallback -le 0) {
        $fallback = 300
        if ($null -ne $config.refreshSeconds) { $fallback = [int]$config.refreshSeconds }
    }
    if ($fallback -lt 60) { $fallback = 60 }

    return [pscustomobject]@{
        Token           = $token
        FallbackSeconds = $fallback
    }
}

# Запускает разовое обновление топа в отдельном процессе,
# чтобы ошибка апдейтера не роняла слушатель.
function Invoke-Update {
    param([string]$Reason)

    Write-Log $Reason 'Cyan'
    try {
        & powershell -NoProfile -ExecutionPolicy Bypass -File $updaterPath -Once 2>&1 |
            ForEach-Object { Write-Host ('    ' + [string]$_) }
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Апдейтер завершился с кодом $LASTEXITCODE" 'Yellow'
        }
    } catch {
        Write-Log ('Не удалось обновить топ: ' + $_.Exception.Message) 'Yellow'
    }
}

function Send-Text {
    param(
        [System.Net.WebSockets.ClientWebSocket]$Socket,
        [string]$Text
    )

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $segment = New-Object 'System.ArraySegment[byte]' -ArgumentList @(,$bytes)
    $Socket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
}

# Достаёт имя события из пакета Socket.IO вида 42["donation","{...}"]
function Get-EventName {
    param([string]$Message)

    if (-not $Message.StartsWith('42')) { return $null }
    $match = [regex]::Match($Message, '^42\["([^"]+)"')
    if ($match.Success) { return $match.Groups[1].Value }
    return $null
}

function Get-DonationSummary {
    param([string]$Message)

    try {
        $payloadJson = $Message.Substring(2)
        $parts = ConvertFrom-Json -InputObject $payloadJson
        if (@($parts).Count -lt 2) { return $null }

        $payload = $parts[1]
        if ($payload -is [string]) { $payload = ConvertFrom-Json -InputObject $payload }
        if ($null -eq $payload) { return $null }

        $name = [string]$payload.username
        if ([string]::IsNullOrWhiteSpace($name)) { $name = 'Аноним' }
        $amount = $payload.amount
        if ($null -eq $amount) { $amount = $payload.amount_in_user_currency }
        $currency = [string]$payload.currency
        if ([string]::IsNullOrWhiteSpace($currency)) { $currency = 'RUB' }

        return [pscustomobject]@{
            Name     = $name
            Amount   = $amount
            Currency = $currency
        }
    } catch {
        return $null
    }
}

# Одно подключение: живёт до обрыва или ошибки, потом вызывающий переподключится
function Connect-AndListen {
    param([pscustomobject]$Settings)

    $socket = New-Object System.Net.WebSockets.ClientWebSocket
    $socket.Options.SetRequestHeader('Origin', 'https://www.donationalerts.com')

    $timeout = New-Object System.Threading.CancellationTokenSource
    $timeout.CancelAfter([TimeSpan]::FromSeconds(20))
    try {
        $socket.ConnectAsync([Uri]$socketUrl, $timeout.Token).GetAwaiter().GetResult() | Out-Null
    } finally {
        $timeout.Dispose()
    }

    Write-Log 'Соединение с DonationAlerts установлено.' 'Green'

    $buffer = New-Object byte[] 65536
    $builder = New-Object Text.StringBuilder
    $authorized = $false
    $lastUpdate = (Get-Date).AddDays(-1)

    while ($socket.State -eq 'Open') {
        $segment = New-Object 'System.ArraySegment[byte]' -ArgumentList @(,$buffer)
        $task = $socket.ReceiveAsync($segment, [Threading.CancellationToken]::None)

        # Сервер присылает ping каждые 25 секунд. Если 90 секунд тишины —
        # считаем соединение мёртвым и переподключаемся.
        if (-not $task.Wait(90000)) {
            Write-Log 'Сервер молчит 90 секунд, переподключаюсь.' 'Yellow'
            break
        }

        $result = $task.Result
        if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
            Write-Log 'Сервер закрыл соединение.' 'Yellow'
            break
        }

        [void]$builder.Append([Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count))
        if (-not $result.EndOfMessage) { continue }

        $message = $builder.ToString()
        $builder.Clear() | Out-Null

        # Engine.IO: 2 — ping от сервера, отвечаем 3 — pong
        if ($message -eq '2') {
            Send-Text -Socket $socket -Text '3'
            continue
        }

        # Engine.IO: 0 — открытие транспорта, подключаемся к namespace
        if ($message.StartsWith('0')) {
            Send-Text -Socket $socket -Text '40'
            continue
        }

        # Socket.IO: 40 — namespace подключён, авторизуемся токеном виджета
        if ($message.StartsWith('40')) {
            $auth = '42["add-user",{"token":"' + $Settings.Token + '"}]'
            Send-Text -Socket $socket -Text $auth
            $authorized = $true
            Write-Log 'Авторизация отправлена, жду донаты.' 'Green'

            if (((Get-Date) - $lastUpdate).TotalSeconds -ge $Settings.FallbackSeconds) {
                Invoke-Update -Reason 'Страховочное обновление при подключении.'
                $lastUpdate = Get-Date
            }
            continue
        }

        # Socket.IO: 41 — namespace отключён
        if ($message.StartsWith('41')) {
            Write-Log 'Канал отключил сессию, переподключаюсь.' 'Yellow'
            break
        }

        $eventName = Get-EventName -Message $message
        if ($eventName -eq 'donation') {
            $info = Get-DonationSummary -Message $message
            if ($info) {
                Write-Log ("Новый донат: {0} — {1} {2}. Обновляю топ." -f $info.Name, $info.Amount, $info.Currency) 'Green'
            } else {
                Write-Log 'Новый донат (данные не разобраны). Обновляю топ.' 'Green'
            }
            Invoke-Update -Reason 'Обновление после доната.'
            $lastUpdate = Get-Date
            continue
        }

        # Страховка: если событий давно не было, обновляем по таймеру
        if (((Get-Date) - $lastUpdate).TotalSeconds -ge $Settings.FallbackSeconds) {
            Invoke-Update -Reason 'Плановая проверка по таймеру.'
            $lastUpdate = Get-Date
        }
    }

    if (-not $authorized) {
        Write-Log 'Авторизация не подтверждена — возможно, токен неверный.' 'Red'
    }
}

# ============================================================
#  ЗАПУСК
# ============================================================

Write-Log 'Слушатель донатов запущен. Окно не закрывайте во время стрима.'

$attempt = 0
while ($true) {
    try {
        $settings = Read-Settings
        Write-Log ("Страховочная проверка каждые {0} сек., донаты ловятся мгновенно." -f $settings.FallbackSeconds)
        Connect-AndListen -Settings $settings
        $attempt = 0
        Write-Log 'Переподключение через 3 сек.' 'Yellow'
        Start-Sleep -Seconds 3
    } catch {
        $attempt++
        $delay = [Math]::Min(30, 3 * $attempt)
        $reason = $_.Exception.Message
        if ($settings -and $settings.Token) {
            if ($reason.Contains($settings.Token)) { $reason = $reason.Replace($settings.Token, '***') }
        }
        Write-Log ("Ошибка соединения: {0}. Повтор через {1} сек." -f $reason, $delay) 'Red'
        Start-Sleep -Seconds $delay
    }
}
