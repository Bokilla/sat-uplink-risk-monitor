#Readme: Vor Verwendung müssen eigene API-Credentials in api-credentials hinterlegt werden.

# Hiermit wird ein Debug-Mode aktiviert, der die Ausgabe der SRF-Meteo-Payload in eine Datei erlaubt. Dies ist hilfreich, um die Struktur der Payload zu analysieren und die richtigen Feldnamen für die Wetterwerte zu ermitteln.
$script:EnableWeatherDump = $false

$script:EnableRfMonitoring = $false
$script:UseRfSimulationData = $false
$script:RfSimulationData = $null
$script:RfDataSource = $null
$script:GrafanaUrl = "https://nms.media.int/grafana"
$script:GrafanaDatasourceUid = "000000001"
$script:UplinkInfrastructure = @{
    Satellite = "Eutelsat Hot Bird 13B"
    Transponder = "T123"
    UplinkFrequencyMHz = 14250.6600
    Zurich = @{
        AntennaSizeM = 10.0
        TxPowerDbm = -23
    }
    Lugano = @{
        AntennaSizeM = 7.5
    }
}
$script:RfHistory = @{
    Zurich = @{
        Margin = @()
        Beacon = @()
    }
    Comano = @{
        Margin = @()
        Beacon = @()
    }
}

function Get-SrfMeteoCredentialFilePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    # Die Zugangsdaten liegen nicht im Script selbst, sondern in einem separaten
    # Unterordner neben dem Script. Dadurch bleiben ClientID und Secret außerhalb
    # des Codes und werden nicht im Repository mitgeliefert.
    $credentialDirectory = Join-Path $PSScriptRoot "api-credentials"
    $filePath = Join-Path $credentialDirectory $FileName

    # Wenn die Datei fehlt, bricht das Script mit einer klaren Fehlermeldung ab.
    if (-not (Test-Path -Path $filePath)) {
        throw "Credential-Datei nicht gefunden: $filePath"
    }

    return $filePath
}

function Get-SrfMeteoCredentials {

    # Pro Session werden die Credentials einmal aus den externen Textdateien gelesen
    # und anschließend im Script-Kontext gecacht. Dadurch muss der Zugriff nicht bei
    # jeder Anfrage erneut aus den Dateien gelesen werden.
    if ($script:srfMeteoCredentialsLoaded -and $script:srfMeteoCredentials) {
        return $script:srfMeteoCredentials
    }

    # Die beiden benötigten Schlüssel liegen in den Dateien clientId.txt und
    # clientSecret.txt im Ordner api-credentials. Die Dateien mit -new.txt werden
    # bewusst ignoriert, da sie vorerst nicht verwendet werden sollen.
    $clientIdPath = Get-SrfMeteoCredentialFilePath -FileName "clientId.txt"
    $clientSecretPath = Get-SrfMeteoCredentialFilePath -FileName "clientSecret.txt"

    # Get-Content -Raw liest den kompletten Inhalt ein, und Trim() entfernt
    # Leerzeichen/Zeilenumbrüche am Anfang und Ende.
    $clientId = (Get-Content -Path $clientIdPath -Raw).Trim()
    $clientSecret = (Get-Content -Path $clientSecretPath -Raw).Trim()

    if ([string]::IsNullOrWhiteSpace($clientId) -or [string]::IsNullOrWhiteSpace($clientSecret)) {
        throw "Die SRF-Meteo-Credentials in 'api-credentials' sind leer oder unvollständig."
    }

    # Die beiden Werte werden in einem Hashtable als Session-Cache abgelegt, damit
    # nachfolgende Aufrufe sofort wiederverwendet werden, ohne die Dateien erneut zu lesen.
    $script:srfMeteoCredentials = @{
        ClientId = $clientId
        ClientSecret = $clientSecret
    }
    $script:srfMeteoCredentialsLoaded = $true

    return $script:srfMeteoCredentials
}

function Get-SrfMeteoAccessToken {

    if (
        $script:srfMeteoAccessToken -and
        $script:srfMeteoAccessTokenExpires -and
        (Get-Date) -lt $script:srfMeteoAccessTokenExpires
    ) {
        Write-Verbose "SRF Meteo: vorhandenes Access-Token wird verwendet."
        return $script:srfMeteoAccessToken
    }

    Write-Verbose "SRF Meteo: neues Access-Token wird angefordert."

    $credentials = Get-SrfMeteoCredentials
    $clientId = $credentials.ClientId
    $clientSecret = $credentials.ClientSecret

    $secureSecret = ConvertTo-SecureString $clientSecret -AsPlainText -Force
    $clientCredential = New-Object System.Management.Automation.PSCredential($clientId, $secureSecret)
    $token = Invoke-RestMethod `
        -Method Post `
        -Uri "https://api.srgssr.ch/oauth/v1/accesstoken?grant_type=client_credentials" `
        -Authentication Basic `
        -Credential $clientCredential

    if (-not $token -or [string]::IsNullOrWhiteSpace($token.access_token)) {
        throw "SRF Meteo OAuth-Antwort enthielt kein gültiges Access-Token."
    }

    $script:srfMeteoAccessToken = $token.access_token

    if ($token.PSObject.Properties['expires_in']) {
        $expiresInSeconds = [int]$token.expires_in

        # Sicherheitsreserve: Das Token wird bereits 60 Sekunden vor Ablauf als
        # abgelaufen betrachtet, damit ein kurz vor dem Ablauf gültiges Token nicht
        # noch für den nächsten Request verwendet wird, der möglicherweise bereits
        # abgelaufen ist.
        $buffer = 60

        if ($expiresInSeconds -gt $buffer) {
            $script:srfMeteoAccessTokenExpires = (Get-Date).AddSeconds($expiresInSeconds - $buffer)
        }
        else {
            $script:srfMeteoAccessTokenExpires = (Get-Date).AddSeconds($expiresInSeconds)
        }
    }
    else {
        $script:srfMeteoAccessTokenExpires = (Get-Date).AddMinutes(55)
    }

    Write-Verbose "SRF Meteo: neues Access-Token erfolgreich gespeichert."
    return $script:srfMeteoAccessToken
}

function Get-SrfWeatherDescription {
    param(
        [int]$SymbolCode
    )

    switch ($SymbolCode) {
        1   { "Sonnig" }
        10  { "Ziemlich sonnig" }
        2   { "Leicht bewölkt" }
        3   { "Teils sonnig" }
        4   { "Regenschauer" }
        5   { "Regenschauer mit Gewitter" }
        6   { "Schneeschauer" }
        8   { "Schneeregenschauer" }
        17  { "Nebel" }
        19  { "Bedeckt" }
        20  { "Regnerisch" }
        21  { "Schneefall" }
        22  { "Schneeregen" }
        25  { "Regenschauer" }

        -1  { "Klar" }
        -10 { "Klare Abschnitte" }
        -2  { "Nebelbänke" }
        -4  { "Regenschauer" }
        -5  { "Regenschauer mit Gewitter" }
        -6  { "Schneeschauer" }
        -8  { "Schneeregenschauer" }
        -17 { "Nebel" }
        -19 { "Bedeckt" }
        -20 { "Regnerisch" }
        -21 { "Schneefall" }
        -22 { "Schneeregen" }
        -25 { "Regenschauer" }

        default { "Unbekannte Wetterlage" }
    }
}

function Get-SrfWeatherCodeSummary {
    param(
        [int]$SymbolCode
    )

    $description = Get-SrfWeatherDescription -SymbolCode $SymbolCode
    if ($SymbolCode -in @(-5, 5)) {
        return "$description (Code $SymbolCode, Gewitter)"
    }

    return "$description (Code $SymbolCode)"
}

function Save-SrfWeatherPayloadDump {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Payload,

        [Parameter(Mandatory = $true)]
        [string]$LocationName
    )

    $dumpDirectory = Join-Path $PSScriptRoot "api-dump"

    if (-not (Test-Path $dumpDirectory)) {
        New-Item -Path $dumpDirectory -ItemType Directory -Force | Out-Null
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

    $safeLocationName =
        $LocationName -replace '[^a-zA-Z0-9]','-'

    $fileName =
        "dump-$safeLocationName-$timestamp.json"

    $filePath =
        Join-Path $dumpDirectory $fileName

    $Payload |
        ConvertTo-Json -Depth 100 |
        Set-Content -Path $filePath -Encoding UTF8

    return $filePath
}

function Get-WeatherMetricValue {
    param(
        [object]$ValueObject,
        [string[]]$CandidateNames,
        [string]$Default = "n.v."
    )

    if ($null -eq $ValueObject) {
        return $Default
    }

    foreach ($candidate in $CandidateNames) {
        $property = $ValueObject.PSObject.Properties[$candidate]

        if ($null -ne $property) {
            $value = $property.Value

            if ($null -ne $value) {
                return $value
            }
        }
    }

    return $Default
}

function Get-WeatherMetricText {
    param(
        [object]$Value,
        [string]$Unit = "",
        [bool]$RoundToInteger = $true
    )

    if ($null -eq $Value) {
        return "n.v."
    }

    if ($Value -is [string]) {
        if ($Value -match '^\s*$') {
            return "n.v."
        }

        return "$Value$Unit"
    }

    if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal] -or $Value -is [int] -or $Value -is [long]) {
        $number = [double]$Value
        $roundedNumber = [int]$number
        $difference = $number - $roundedNumber

        if ($RoundToInteger -and ($difference -lt 0.0001) -and ($difference -gt -0.0001)) {
            return "{0}{1}" -f $roundedNumber, $Unit
        }

        return "{0:0.0}{1}" -f $number, $Unit
    }

    return "$Value$Unit"
}

function Get-GrafanaPrometheusValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GrafanaUrl,

        [Parameter(Mandatory = $true)]
        [string]$DatasourceUid,

        [Parameter(Mandatory = $true)]
        [string]$Query
    )

    if ([string]::IsNullOrWhiteSpace($GrafanaUrl) -or [string]::IsNullOrWhiteSpace($DatasourceUid)) {
        return "n.v."
    }

    try {
        $baseUrl = $GrafanaUrl.TrimEnd('/')
        $encodedQuery = [System.Uri]::EscapeDataString($Query)
        $uri = "$baseUrl/api/datasources/proxy/uid/$DatasourceUid/api/v1/query?query=$encodedQuery"

        $response = Invoke-RestMethod -Uri $uri -Method Get -ErrorAction Stop

        if ($null -eq $response -or $null -eq $response.data -or $null -eq $response.data.result -or $response.data.result.Count -eq 0) {
            return "n.v."
        }

        $value = $response.data.result[0].value[1]
        if ($null -eq $value) {
            return "n.v."
        }

        try {
            return [double]$value
        }
        catch {
            return "n.v."
        }
    }
    catch {
        return "n.v."
    }
}

function Test-GrafanaConnection {
    Write-Host ""
    Write-Host "Grafana-Verbindungstest" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor DarkGray
    Write-Host "LanguageMode: $($ExecutionContext.SessionState.LanguageMode)"
    Write-Host "Grafana URL: $script:GrafanaUrl"
    Write-Host "Datasource UID: $script:GrafanaDatasourceUid"

    $queries = @("up", "sat_uplink_t123_zur13")
    $lastError = "Keine Daten für die Testqueries erhalten."

    foreach ($query in $queries) {
        try {
            $baseUrl = $script:GrafanaUrl.TrimEnd('/')
            # Fehlerauslösende Originalzeile unter Constrained Language Mode:
            # [System.Uri]::EscapeDataString($query)
            # PromQL-Zeichen werden hier ohne nicht freigegebene .NET-Typen kodiert.
            $encodedQuery = $query.Replace('%', '%25').Replace(' ', '%20').Replace('/', '%2F').Replace('(', '%28').Replace(')', '%29').Replace('+', '%2B').Replace('?', '%3F').Replace('&', '%26').Replace('=', '%3D').Replace('#', '%23')
            $uri = "$baseUrl/api/datasources/proxy/uid/$script:GrafanaDatasourceUid/api/v1/query?query=$encodedQuery"
            $response = Invoke-RestMethod -Uri $uri -Method Get -ErrorAction Stop
            $results = @($response.data.result)

            if ($results.Count -eq 0) {
                $lastError = "Query '$query' lieferte keine Daten."
                continue
            }

            $value = $results[0].value[1]
            try {
                $numericValue = [double]$value
            }
            catch {
                $lastError = "Query '$query' lieferte keinen numerischen Wert."
                continue
            }

            Write-Host "Status: OK" -ForegroundColor Green
            Write-Host "Antwortwert: $numericValue" -ForegroundColor Green
            return
        }
        catch {
            $lastError = $_.Exception.Message
        }
    }

    Write-Host "Status: Fehlgeschlagen" -ForegroundColor Red
    Write-Host "Fehler: $lastError" -ForegroundColor Red
}

function Test-RfMetricQuery {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Query
    )

    $baseUrl = $script:GrafanaUrl.TrimEnd('/')
    $encodedQuery = $Query.Replace('%', '%25').Replace(' ', '%20').Replace('/', '%2F').Replace('(', '%28').Replace(')', '%29').Replace('+', '%2B').Replace('?', '%3F').Replace('&', '%26').Replace('=', '%3D').Replace('#', '%23')
    $uri = "$baseUrl/api/datasources/proxy/uid/$script:GrafanaDatasourceUid/api/v1/query?query=$encodedQuery"

    Write-Host ""
    Write-Host "RF-Query-Debug" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor DarkGray
    Write-Host "URL: $uri"
    Write-Host "Query: $Query"

    try {
        $response = Invoke-RestMethod -Uri $uri -Method Get -ErrorAction Stop
        $results = @($response.data.result)

        Write-Host "Result Count: $($results.Count)"
        if ($results.Count -eq 0) {
            Write-Host "Resultset leer" -ForegroundColor Yellow
        }

        Write-Host "JSON Antwort:" -ForegroundColor Yellow
        $response | ConvertTo-Json -Depth 20
    }
    catch {
        Write-Host "Fehler: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Set-DefaultRfSimulationData {
    $script:RfSimulationData = @{
        Zurich = @{
            Active = 0
            Path = 1
            IRDMargin = 8.8
            BeaconLevel = -62.0
            Azimuth = 174.0
            Elevation = 35.2
            AntennaSizeM = 10.0
            TxPowerDbm = -23
        }
        Lugano = @{
            Active = 0
            Path = 0
            IRDMargin = 8.6
            BeaconLevel = -65.0
            Azimuth = 174.4
            Elevation = 37.3
            AntennaSizeM = 7.5
        }
    }

    $script:RfDataSource = "SimulationDefault"
    $script:UseRfSimulationData = $true
    Write-Host "RF-Testdaten wurden geladen." -ForegroundColor Yellow
}

function Set-CustomRfSimulationData {
    $zurich = @{}
    $lugano = @{}

    $zurich.IRDMargin = [double](Read-Host "Zürich - IRD Margin (dB)")
    $zurich.BeaconLevel = [double](Read-Host "Zürich - Beacon Level (dBm)")
    $zurich.Azimuth = [double](Read-Host "Zürich - Azimuth (°)")
    $zurich.Elevation = [double](Read-Host "Zürich - Elevation (°)")
    $zurich.AntennaSizeM = [double](Read-Host "Zürich - Antennendurchmesser (m)")
    $zurich.TxPowerDbm = [double](Read-Host "Zürich - TX Power (dBm)")
    $zurich.Active = [int](Read-Host "Zürich - Aktiv (0 = aktiv, 1 = inaktiv)")
    $zurich.Path = [int](Read-Host "Zürich - Pfad (0 = B, 1 = A)")

    $lugano.IRDMargin = [double](Read-Host "Comano / Lugano - IRD Margin (dB)")
    $lugano.BeaconLevel = [double](Read-Host "Comano / Lugano - Beacon Level (dBm)")
    $lugano.Azimuth = [double](Read-Host "Comano / Lugano - Azimuth (°)")
    $lugano.Elevation = [double](Read-Host "Comano / Lugano - Elevation (°)")
    $lugano.AntennaSizeM = [double](Read-Host "Comano / Lugano - Antennendurchmesser (m)")
    $lugano.Active = [int](Read-Host "Comano / Lugano - Aktiv (0/1)")
    $lugano.Path = [int](Read-Host "Comano / Lugano - Pfad (0 = B, 1 = A)")

    $script:RfSimulationData = @{
        Zurich = $zurich
        Lugano = $lugano
    }

    $script:RfDataSource = "SimulationCustom"
    $script:UseRfSimulationData = $true
    Write-Host "Benutzerdefinierte RF-Testdaten gespeichert." -ForegroundColor Yellow
}

function Clear-RfSimulationData {
    $script:UseRfSimulationData = $false
    $script:RfSimulationData = $null
    $script:RfDataSource = $null
    Write-Host "RF-Simulation deaktiviert." -ForegroundColor DarkYellow
}

function Set-RfMonitoringState {
    $script:EnableRfMonitoring = -not $script:EnableRfMonitoring

    if ($script:EnableRfMonitoring) {
        Write-Host "RF-Monitoring aktiviert." -ForegroundColor Green
    }
    else {
        Write-Host "RF-Monitoring deaktiviert." -ForegroundColor DarkYellow
    }
}

function Get-UplinkActiveState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SiteName,

        [Parameter(Mandatory = $true)]
        [object]$RawValue
    )

    if ($null -eq $RawValue -or "$RawValue" -eq "n.v.") {
        return "n.v."
    }

    # Zürich verwendet entgegen der üblichen Erwartung: 0 = aktiv, 1 = inaktiv.
    if ($SiteName -eq "Zurich") {
        if ("$RawValue" -eq "0") { return "Aktiv" }
        if ("$RawValue" -eq "1") { return "Inaktiv" }
    }
    elseif ($SiteName -eq "Comano" -or $SiteName -eq "Lugano") {
        if ("$RawValue" -eq "1") { return "Aktiv" }
        if ("$RawValue" -eq "0") { return "Inaktiv" }
    }

    return "n.v."
}

function Get-UplinkRfMetrics {
    param(
        [string]$GrafanaUrl = $script:GrafanaUrl,
        [string]$DatasourceUid = $script:GrafanaDatasourceUid
    )

    if (
        $script:UseRfSimulationData -and
        $script:RfSimulationData
    ) {
        return $script:RfSimulationData
    }

    return @{
        Zurich = @{
            Active = Get-GrafanaPrometheusValue -GrafanaUrl $GrafanaUrl -DatasourceUid $DatasourceUid -Query "sat_uplink_t123_zur13"
            Path = Get-GrafanaPrometheusValue -GrafanaUrl $GrafanaUrl -DatasourceUid $DatasourceUid -Query "sat_uplink_t123_zur13_s3switch"
            IRDMargin = Get-GrafanaPrometheusValue -GrafanaUrl $GrafanaUrl -DatasourceUid $DatasourceUid -Query "sat_uplink_t123_zur13_ird_margin / 10"
            BeaconLevel = Get-GrafanaPrometheusValue -GrafanaUrl $GrafanaUrl -DatasourceUid $DatasourceUid -Query "sat_uplink_t123_zur13_odm_beaconlevel / 100"
            Azimuth = Get-GrafanaPrometheusValue -GrafanaUrl $GrafanaUrl -DatasourceUid $DatasourceUid -Query "sat_uplink_t123_zur13_odm_azimuth / 1000"
            Elevation = Get-GrafanaPrometheusValue -GrafanaUrl $GrafanaUrl -DatasourceUid $DatasourceUid -Query "sat_uplink_t123_zur13_odm_elevation / 1000"
        }
        Lugano = @{
            Active = Get-GrafanaPrometheusValue -GrafanaUrl $GrafanaUrl -DatasourceUid $DatasourceUid -Query "sat_uplink_t123_lug1"
            Path = Get-GrafanaPrometheusValue -GrafanaUrl $GrafanaUrl -DatasourceUid $DatasourceUid -Query "sat_uplink_t123_lug1_s3switch"
            IRDMargin = Get-GrafanaPrometheusValue -GrafanaUrl $GrafanaUrl -DatasourceUid $DatasourceUid -Query "sat_uplink_t123_lug1_ird_margin / 10"
            BeaconLevel = Get-GrafanaPrometheusValue -GrafanaUrl $GrafanaUrl -DatasourceUid $DatasourceUid -Query "sat_uplink_t123_lug1_odm_beaconlevel / 100"
            Azimuth = Get-GrafanaPrometheusValue -GrafanaUrl $GrafanaUrl -DatasourceUid $DatasourceUid -Query "sat_uplink_t123_lug1_odm_azimuth / 1000"
            Elevation = Get-GrafanaPrometheusValue -GrafanaUrl $GrafanaUrl -DatasourceUid $DatasourceUid -Query "sat_uplink_t123_lug1_odm_elevation / 1000"
        }
    }
}

function Get-LinkHealthScore {
    param(
        [Parameter(Mandatory = $true)]
        [object]$IRDMargin,

        [Parameter(Mandatory = $true)]
        [object]$BeaconLevel
    )

    if (
        $null -eq $IRDMargin -or
        $null -eq $BeaconLevel -or
        "$IRDMargin" -eq "n.v." -or
        "$BeaconLevel" -eq "n.v."
    ) {
        return "n.v."
    }

    try {
        $marginScore = ([double]$IRDMargin / 10) * 100
        $beaconScore = (([double]$BeaconLevel + 85) / 25) * 100
    }
    catch {
        return "n.v."
    }

    if ($marginScore -lt 0) { $marginScore = 0 }
    if ($marginScore -gt 100) { $marginScore = 100 }
    if ($beaconScore -lt 0) { $beaconScore = 0 }
    if ($beaconScore -gt 100) { $beaconScore = 100 }

    $healthScore = ($marginScore * 0.7) + ($beaconScore * 0.3)
    return [int]($healthScore + 0.5)
}

function Get-LinkHealthText {
    param(
        [Parameter(Mandatory = $true)]
        [int]$HealthScore
    )

    if ($HealthScore -ge 90) { return "Exzellent" }
    if ($HealthScore -ge 75) { return "Gut" }
    if ($HealthScore -ge 60) { return "Beobachten" }
    if ($HealthScore -ge 40) { return "Kritisch" }
    return "Akut gefährdet"
}

function Get-OverallUplinkRiskScore {
    param(
        [Parameter(Mandatory = $true)]
        [object]$LinkHealthScore,

        [Parameter(Mandatory = $true)]
        [object]$WeatherRiskScore
    )

    if (
        $null -eq $LinkHealthScore -or
        $null -eq $WeatherRiskScore -or
        "$LinkHealthScore" -eq "n.v." -or
        "$WeatherRiskScore" -eq "n.v."
    ) {
        return "n.v."
    }

    try {
        $overallRisk = 100 - (([double]$LinkHealthScore * 0.70) + ((100 - [double]$WeatherRiskScore) * 0.30))
    }
    catch {
        return "n.v."
    }

    if ($overallRisk -lt 0) { $overallRisk = 0 }
    if ($overallRisk -gt 100) { $overallRisk = 100 }

    return [int]($overallRisk + 0.5)
}

function Get-OverallUplinkRiskText {
    param(
        [Parameter(Mandatory = $true)]
        [int]$OverallRiskScore
    )

    if ($OverallRiskScore -le 15) { return "Sehr gering" }
    if ($OverallRiskScore -le 30) { return "Gering" }
    if ($OverallRiskScore -le 50) { return "Mittel" }
    if ($OverallRiskScore -le 70) { return "Hoch" }
    return "Sehr hoch"
}

function Get-RiskText {
    param([Parameter(Mandatory = $true)] [int]$RiskScore)
    return Get-OverallUplinkRiskText -OverallRiskScore $RiskScore
}

function Get-UplinkSiteComparison {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ZurichOverallRisk,
        [Parameter(Mandatory = $true)]
        [object]$ComanoOverallRisk
    )

    if ("$ZurichOverallRisk" -eq "n.v." -or "$ComanoOverallRisk" -eq "n.v.") { return "n.v." }
        $difference = [double]$ZurichOverallRisk - [double]$ComanoOverallRisk
    if ($difference -lt 0) { $difference = -$difference }
    return [int]($difference + 0.5)
}

function Get-SiteAdvantage {
    param(
        [Parameter(Mandatory = $true)] [object]$ZurichOverallRisk,
        [Parameter(Mandatory = $true)] [object]$ComanoOverallRisk
    )

    if ("$ZurichOverallRisk" -eq "n.v." -or "$ComanoOverallRisk" -eq "n.v.") {
        return @{ Site = "n.v."; Rating = "n.v." }
    }

    $difference = Get-UplinkSiteComparison -ZurichOverallRisk $ZurichOverallRisk -ComanoOverallRisk $ComanoOverallRisk
    if ($ZurichOverallRisk -lt $ComanoOverallRisk) { $site = "Zürich" }
    elseif ($ComanoOverallRisk -lt $ZurichOverallRisk) { $site = "Comano" }
    else { $site = "Gleichwertig" }

    if ($difference -le 4) { $rating = "Gleichwertig" }
    elseif ($difference -le 14) { $rating = "Leichter Vorteil" }
    elseif ($difference -le 29) { $rating = "Klarer Vorteil" }
    else { $rating = "Deutlicher Vorteil" }
    return @{ Site = $site; Rating = $rating }
}

function Add-RfHistoryValue {
    param(
        [Parameter(Mandatory = $true)] [string]$SiteName,
        [Parameter(Mandatory = $true)] [object]$Metrics
    )

    foreach ($metricName in @('Margin', 'Beacon')) {
        $value = if ($metricName -eq 'Margin') { $Metrics.IRDMargin } else { $Metrics.BeaconLevel }
        if ($null -ne $value -and "$value" -ne 'n.v.') {
            try { $script:RfHistory[$SiteName][$metricName] += [double]$value } catch { }
        }
        while ($script:RfHistory[$SiteName][$metricName].Count -gt 20) {
            $script:RfHistory[$SiteName][$metricName] = @($script:RfHistory[$SiteName][$metricName] | Select-Object -Skip 1)
        }
    }
}

function Get-RfTrend {
    param(
        [Parameter(Mandatory = $true)] [object[]]$History,
        [Parameter(Mandatory = $true)] [ValidateSet('Margin', 'Beacon')] [string]$Metric
    )

    $values = @($History | Where-Object { "$($_)" -ne 'n.v.' } | Select-Object -Last 20)
    if ($values.Count -lt 5) { return 'Nicht genügend Historie' }
    $recent = [double]$values[-1]
    $baselineCount = $values.Count
    if ($baselineCount -gt 10) { $baselineCount = 10 }
    $baselineValues = @($values | Select-Object -Last $baselineCount)
    $baseline = ($baselineValues | Measure-Object -Average).Average
    $delta = $recent - $baseline
    if ($delta -ge 0.5) { return 'Steigend' }
    if ($delta -ge -0.2) { return 'Stabil' }
    if ($delta -ge -0.8) { return 'Leicht fallend' }
    if ($delta -ge -1.5) { return 'Fallend' }
    return 'Stark fallend'
}

function Get-MarginTrend {
    param([Parameter(Mandatory = $true)] [object[]]$History)
    return Get-RfTrend -History $History -Metric Margin
}

function Get-BeaconTrend {
    param([Parameter(Mandatory = $true)] [object[]]$History)
    return Get-RfTrend -History $History -Metric Beacon
}

function Get-RfTrendDelta {
    param(
        [Parameter(Mandatory = $true)] [object[]]$History
    )

    $values = @($History | Where-Object { "$($_)" -ne 'n.v.' } | Select-Object -Last 20)
    if ($values.Count -lt 5) { return 'n.v.' }
    $baselineCount = $values.Count
    if ($baselineCount -gt 10) { $baselineCount = 10 }
    $baselineValues = @($values | Select-Object -Last $baselineCount)
    $baseline = ($baselineValues | Measure-Object -Average).Average
    return ([double]$values[-1] - [double]$baseline)
}

function Get-PredictedLinkHealth {
    param(
        [Parameter(Mandatory = $true)] [object]$CurrentLinkHealth,
        [Parameter(Mandatory = $true)] [string]$MarginTrend,
        [Parameter(Mandatory = $true)] [string]$BeaconTrend
    )

    if ("$CurrentLinkHealth" -eq 'n.v.') { return 'n.v.' }
    if ($MarginTrend -eq 'Nicht genügend Historie' -or $BeaconTrend -eq 'Nicht genügend Historie') { return 'Nicht genügend Historie' }
    $adjustments = @{ 'Steigend' = 5; 'Stabil' = 0; 'Leicht fallend' = -5; 'Fallend' = -10; 'Stark fallend' = -20 }
    $predicted = [double]$CurrentLinkHealth + $adjustments[$MarginTrend] + $adjustments[$BeaconTrend]
    if ($predicted -lt 0) { $predicted = 0 }
    if ($predicted -gt 100) { $predicted = 100 }
    return [int]($predicted + 0.5)
}

function Get-PredictedFailureProbability {
    param(
        [Parameter(Mandatory = $true)] [object]$CurrentOverallRisk,
        [Parameter(Mandatory = $true)] [string]$MarginTrend,
        [Parameter(Mandatory = $true)] [string]$BeaconTrend
    )

    if ("$CurrentOverallRisk" -eq 'n.v.') { return 'n.v.' }
    if ($MarginTrend -eq 'Nicht genügend Historie' -or $BeaconTrend -eq 'Nicht genügend Historie') { return 'Nicht genügend Historie' }
    $adjustments = @{ 'Steigend' = -5; 'Stabil' = 0; 'Leicht fallend' = 10; 'Fallend' = 20; 'Stark fallend' = 35 }
    $predicted = [double]$CurrentOverallRisk + $adjustments[$MarginTrend] + $adjustments[$BeaconTrend]
    if ($predicted -lt 0) { $predicted = 0 }
    if ($predicted -gt 100) { $predicted = 100 }
    return [int]($predicted + 0.5)
}

function Get-SwitchoverRecommendation {
    param(
        [Parameter(Mandatory = $true)] [string]$ActiveSite,
        [Parameter(Mandatory = $true)] [object]$ZurichOverallRisk,
        [Parameter(Mandatory = $true)] [object]$ComanoOverallRisk,
        [Parameter(Mandatory = $true)] [object]$SiteAdvantage,
        [Parameter(Mandatory = $true)] [string]$MarginTrend,
        [Parameter(Mandatory = $true)] [string]$BeaconTrend,
        [Parameter(Mandatory = $true)] [object]$PredictedFailureProbability,
        [Parameter(Mandatory = $true)] [object]$FutureRisk
    )

    if ("$ZurichOverallRisk" -in @('n.v.', 'Nicht genügend Historie') -or "$ComanoOverallRisk" -in @('n.v.', 'Nicht genügend Historie') -or "$PredictedFailureProbability" -in @('n.v.', 'Nicht genügend Historie', 'Noch keine Prognose verfügbar') -or "$FutureRisk" -in @('n.v.', 'Nicht genügend Historie', 'Noch keine Prognose verfügbar') -or ($ActiveSite -ne 'Zürich' -and $ActiveSite -ne 'Comano')) { return 'Keine Aktion erforderlich' }
    $activeRisk = if ($ActiveSite -eq 'Zürich') { [double]$ZurichOverallRisk } else { [double]$ComanoOverallRisk }
    $otherRisk = if ($ActiveSite -eq 'Zürich') { [double]$ComanoOverallRisk } else { [double]$ZurichOverallRisk }
    $riskAdvantage = $activeRisk - $otherRisk

    $riskSignal = [double]$PredictedFailureProbability
    if ([double]$FutureRisk -gt $riskSignal) { $riskSignal = [double]$FutureRisk }
    if ($riskSignal -gt 85 -and $riskAdvantage -ge 20) { return 'Umschaltung dringend empfohlen' }
    if ($riskSignal -gt 70 -and $riskAdvantage -ge 15) { return 'Umschaltung empfohlen' }
    if ($riskSignal -gt 50 -and $riskAdvantage -ge 10) { return 'Umschaltung vorbereiten' }
    return 'Keine Aktion erforderlich'
}

function Get-FailureProbability {
    param(
        [Parameter(Mandatory = $true)] [object]$LinkHealth,
        [Parameter(Mandatory = $true)] [object]$WeatherRisk,
        [Parameter(Mandatory = $true)] [string]$MarginTrend,
        [Parameter(Mandatory = $true)] [string]$BeaconTrend
    )

    if ("$LinkHealth" -eq 'n.v.' -or "$WeatherRisk" -eq 'n.v.') { return 'n.v.' }
    $probability = ((100 - [double]$LinkHealth) * 0.7) + ([double]$WeatherRisk * 0.3)
    $trendAdjustments = @{ 'Steigend' = -5; 'Stabil' = 0; 'Leicht fallend' = 5; 'Fallend' = 10; 'Stark fallend' = 20 }
    $probability += $trendAdjustments[$MarginTrend] + $trendAdjustments[$BeaconTrend]
    if ($probability -lt 0) { $probability = 0 }
    if ($probability -gt 100) { $probability = 100 }
    return [int]($probability + 0.5)
}

function Get-FailureProbabilityText {
    param([Parameter(Mandatory = $true)] [int]$FailureProbability)
    if ($FailureProbability -le 10) { return 'Vernachlässigbar' }
    if ($FailureProbability -le 30) { return 'Gering' }
    if ($FailureProbability -le 50) { return 'Mittel' }
    if ($FailureProbability -le 70) { return 'Hoch' }
    return 'Kritisch'
}

function Format-RfMetricText {
    param(
        [object]$Value,
        [string]$Unit = "",
        [int]$Decimals = 2
    )

    if ($null -eq $Value -or $Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) {
        return "n.v."
    }

    if ($Value -is [string]) {
        if ($Value -eq "n.v.") {
            return "n.v."
        }

        return "$Value$Unit"
    }

    $number = [double]$Value
    $format = "0."
    if ($Decimals -gt 0) {
        $format += ("0" * $Decimals)
    }

    return ("{0:$format}{1}" -f $number, $Unit)
}

function Get-WindDirectionText {
    param(
        [object]$Degrees
    )

    if ($null -eq $Degrees) {
        return "n.v."
    }

    $value = [double]$Degrees
    $directionNames = @(
        'N', 'NNE', 'NE', 'ENE',
        'E', 'ESE', 'SE', 'SSE',
        'S', 'SSW', 'SW', 'WSW',
        'W', 'WNW', 'NW', 'NNW'
    )

    $sectorSize = 360 / $directionNames.Count
    $index = [int]((($value % 360) + 360) / $sectorSize) % $directionNames.Count
    $direction = $directionNames[$index]

    return "$direction $value°"
}

function Get-ThunderstormRiskPercent {
    param(
        [object]$Forecast
    )

    if ($null -eq $Forecast) {
        return 0
    }

    $rainProb = [double](Get-WeatherMetricValue -ValueObject $Forecast -CandidateNames @('PROBPCP_PERCENT') -Default 0)
    $humidity = [double](Get-WeatherMetricValue -ValueObject $Forecast -CandidateNames @('RELHUM_PERCENT') -Default 0)
    $temperature = [double](Get-WeatherMetricValue -ValueObject $Forecast -CandidateNames @('TTT_C') -Default 0)
    $symbolCode = [int](Get-WeatherMetricValue -ValueObject $Forecast -CandidateNames @('symbol_code') -Default 0)

    $score = 0

    $score += ($rainProb * 0.4)
    $score += ($humidity * 0.2)

    $tempScore = (($temperature - 15) / 10) * 20
    if ($tempScore -lt 0) { $tempScore = 0 }
    if ($tempScore -gt 20) { $tempScore = 20 }

    $score += $tempScore

    if ($symbolCode -eq 5 -or $symbolCode -eq -5) {
        $score += 20
    }

    if ($score -gt 100) { $score = 100 }
    if ($score -lt 0) { $score = 0 }

    return [int]$score
}

function Get-WeatherRiskScore {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Forecast
    )

    if ($null -eq $Forecast) {
        return 0
    }

    try {
        $rainAmount = [double](Get-WeatherMetricValue -ValueObject $Forecast -CandidateNames @('RRR_MM') -Default 0)
        $rainProbability = [double](Get-WeatherMetricValue -ValueObject $Forecast -CandidateNames @('PROBPCP_PERCENT') -Default 0)
        $windGust = [double](Get-WeatherMetricValue -ValueObject $Forecast -CandidateNames @('FX_KMH') -Default 0)
        $humidity = [double](Get-WeatherMetricValue -ValueObject $Forecast -CandidateNames @('RELHUM_PERCENT') -Default 0)
        $thunderstormRisk = [double](Get-ThunderstormRiskPercent -Forecast $Forecast)
    }
    catch {
        return 0
    }

    if ($rainAmount -le 0) { $rainAmountScore = 0 }
    elseif ($rainAmount -le 1) { $rainAmountScore = $rainAmount * 20 }
    elseif ($rainAmount -le 3) { $rainAmountScore = 20 + (($rainAmount - 1) / 2 * 30) }
    elseif ($rainAmount -le 5) { $rainAmountScore = 50 + (($rainAmount - 3) / 2 * 25) }
    elseif ($rainAmount -le 10) { $rainAmountScore = 75 + (($rainAmount - 5) / 5 * 25) }
    else { $rainAmountScore = 100 }

    if ($windGust -le 0) { $windGustScore = 0 }
    elseif ($windGust -le 20) { $windGustScore = $windGust }
    elseif ($windGust -le 40) { $windGustScore = 20 + (($windGust - 20) / 20 * 30) }
    elseif ($windGust -le 60) { $windGustScore = 50 + (($windGust - 40) / 20 * 25) }
    elseif ($windGust -le 80) { $windGustScore = 75 + (($windGust - 60) / 20 * 25) }
    else { $windGustScore = 100 }

    if ($rainProbability -lt 0) { $rainProbability = 0 }
    if ($rainProbability -gt 100) { $rainProbability = 100 }
    if ($thunderstormRisk -lt 0) { $thunderstormRisk = 0 }
    if ($thunderstormRisk -gt 100) { $thunderstormRisk = 100 }
    if ($humidity -lt 0) { $humidity = 0 }
    if ($humidity -gt 100) { $humidity = 100 }

    $weatherRisk =
        ($rainAmountScore * 0.40) +
        ($rainProbability * 0.20) +
        ($thunderstormRisk * 0.20) +
        ($windGustScore * 0.10) +
        ($humidity * 0.10)

    if ($weatherRisk -lt 0) { $weatherRisk = 0 }
    if ($weatherRisk -gt 100) { $weatherRisk = 100 }

    return [int]($weatherRisk + 0.5)
}

function Get-WeatherRiskText {
    param(
        [Parameter(Mandatory = $true)]
        [int]$WeatherRiskScore
    )

    if ($WeatherRiskScore -le 20) { return "Sehr gering" }
    if ($WeatherRiskScore -le 40) { return "Gering" }
    if ($WeatherRiskScore -le 60) { return "Mittel" }
    if ($WeatherRiskScore -le 80) { return "Hoch" }
    return "Sehr hoch"
}

function Get-RiskDrivers {
    param([Parameter(Mandatory = $true)] [object]$Forecast)

    $rainAmount = [double](Get-WeatherMetricValue -ValueObject $Forecast -CandidateNames @('RRR_MM') -Default 0)
    $rainProbability = [double](Get-WeatherMetricValue -ValueObject $Forecast -CandidateNames @('PROBPCP_PERCENT') -Default 0)
    $windGust = [double](Get-WeatherMetricValue -ValueObject $Forecast -CandidateNames @('FX_KMH') -Default 0)
    $humidity = [double](Get-WeatherMetricValue -ValueObject $Forecast -CandidateNames @('RELHUM_PERCENT') -Default 0)
    $thunderstorm = Get-ThunderstormRiskPercent -Forecast $Forecast
    return @{
        Thunderstorm = $thunderstorm
        RainAmount = $rainAmount
        RainProbability = $rainProbability
        WindGust = $windGust
        Humidity = $humidity
    }
}

function Get-FutureWeatherRiskScore {
    param(
        [Parameter(Mandatory = $true)] [object]$CurrentLinkHealth,
        [Parameter(Mandatory = $true)] [object]$Forecast
    )

    if ("$CurrentLinkHealth" -eq 'n.v.' -or $null -eq $Forecast) { return 'n.v.' }
    $futureWeatherRisk = Get-WeatherRiskScore -Forecast $Forecast
    return Get-OverallUplinkRiskScore -LinkHealthScore $CurrentLinkHealth -WeatherRiskScore $futureWeatherRisk
}

function Get-RiskColor {
    param([Parameter(Mandatory = $true)] [string]$Text)
    if ($Text -in @('Sehr gering', 'Exzellent', 'Gut', 'Steigend')) { return 'Green' }
    if ($Text -in @('Gering', 'Beobachten', 'Leicht fallend')) { return 'Yellow' }
    if ($Text -in @('Mittel', 'Fallend')) { return 'DarkYellow' }
    if ($Text -in @('Hoch', 'Kritisch', 'Akut gefährdet', 'Stark fallend')) { return 'Red' }
    if ($Text -in @('Sehr hoch', 'Umschaltung empfohlen', 'Umschaltung dringend empfohlen')) { return 'DarkRed' }
    return 'White'
}

function Get-ScoreColor {
    param(
        [Parameter(Mandatory = $true)] [object]$Score,
        [Parameter(Mandatory = $true)] [ValidateSet('LinkHealth', 'Risk')] [string]$ScoreType
    )

    if ("$Score" -eq 'n.v.') { return 'White' }
    $numericScore = [double]$Score
    if ($ScoreType -eq 'LinkHealth') {
        if ($numericScore -ge 75) { return 'Green' }
        if ($numericScore -ge 60) { return 'Yellow' }
        if ($numericScore -ge 40) { return 'Red' }
        return 'DarkRed'
    }

    if ($numericScore -le 15) { return 'Green' }
    if ($numericScore -le 30) { return 'Yellow' }
    if ($numericScore -le 50) { return 'DarkYellow' }
    if ($numericScore -le 70) { return 'Red' }
    return 'DarkRed'
}

function Show-OperationalView {
    $activeLocation = 'Authentifizierung'
    try {
        $accessToken = Get-SrfMeteoAccessToken
        $headers = @{ Authorization = "Bearer $accessToken" }
        $locations = @(
            @{ Name = 'Fernsehstrasse Zürich'; Latitude = '47.4114'; Longitude = '8.5478' }
            @{ Name = 'Lugano (SRF-Standort)'; Latitude = '46.0050'; Longitude = '8.9510' }
        )
        $weatherData = @()
        if ($null -eq $script:srfMeteoGeolocationIds) { $script:srfMeteoGeolocationIds = @{} }

        foreach ($location in $locations) {
            $activeLocation = $location.Name
            $geolocationId = $script:srfMeteoGeolocationIds[$location.Name]
            if ([string]::IsNullOrWhiteSpace($geolocationId)) {
                $geolocationUrl = "https://api.srgssr.ch/srf-meteo/v2/geolocations?latitude=$($location.Latitude)&longitude=$($location.Longitude)"
                $geolocation = @(Invoke-RestMethod -Uri $geolocationUrl -Headers $headers) | Select-Object -First 1
                $geolocationId = [string]$geolocation.id
                if (-not [string]::IsNullOrWhiteSpace($geolocationId)) { $script:srfMeteoGeolocationIds[$location.Name] = $geolocationId }
            }
            if ([string]::IsNullOrWhiteSpace($geolocationId)) { throw "Keine gültige Geolocation für $($location.Name)." }

            $weather = Invoke-RestMethod -Uri "https://api.srgssr.ch/srf-meteo/v2/forecastpoint/$geolocationId" -Headers $headers
            $now = Get-Date
            $current = $weather.hours | Where-Object { (Get-Date $_.date_time) -ge $now } | Select-Object -First 1
            $forecasts = @($weather.three_hours | Where-Object { (Get-Date $_.date_time) -gt $now } | Select-Object -First 3)
            $weatherData += ,@{ Current = $current; Forecasts = $forecasts }
        }

        $zurichWeather = $weatherData[0]
        $comanoWeather = $weatherData[1]
        $zurichWeatherRisk = Get-WeatherRiskScore -Forecast $zurichWeather.Current
        $comanoWeatherRisk = Get-WeatherRiskScore -Forecast $comanoWeather.Current

        $rfAvailable = $script:UseRfSimulationData -and $script:RfSimulationData -or $script:EnableRfMonitoring
        if (-not $rfAvailable) {
            Write-Host ''
            Write-Host '================================================' -ForegroundColor DarkGray
            Write-Host 'SAT-UPLINK BETRIEBSSTATUS' -ForegroundColor Cyan
            Write-Host '================================================' -ForegroundColor DarkGray
            Write-Host 'Keine RF-Daten verfügbar.' -ForegroundColor DarkYellow
            Write-Host 'RF-Monitoring deaktiviert.' -ForegroundColor DarkYellow
            Write-Host '================================================' -ForegroundColor DarkGray
            return
        }

        $rfMetrics = Get-UplinkRfMetrics -GrafanaUrl $script:GrafanaUrl -DatasourceUid $script:GrafanaDatasourceUid
        Add-RfHistoryValue -SiteName 'Zurich' -Metrics $rfMetrics.Zurich
        Add-RfHistoryValue -SiteName 'Comano' -Metrics $rfMetrics.Lugano
        $zurichLinkHealth = Get-LinkHealthScore -IRDMargin $rfMetrics.Zurich.IRDMargin -BeaconLevel $rfMetrics.Zurich.BeaconLevel
        $comanoLinkHealth = Get-LinkHealthScore -IRDMargin $rfMetrics.Lugano.IRDMargin -BeaconLevel $rfMetrics.Lugano.BeaconLevel
        $zurichOverallRisk = Get-OverallUplinkRiskScore -LinkHealthScore $zurichLinkHealth -WeatherRiskScore $zurichWeatherRisk
        $comanoOverallRisk = Get-OverallUplinkRiskScore -LinkHealthScore $comanoLinkHealth -WeatherRiskScore $comanoWeatherRisk
        $zurichActive = Get-UplinkActiveState -SiteName 'Zurich' -RawValue $rfMetrics.Zurich.Active
        $comanoActive = Get-UplinkActiveState -SiteName 'Comano' -RawValue $rfMetrics.Lugano.Active
        $activeSite = if ($zurichActive -eq 'Aktiv') { 'Zürich' } elseif ($comanoActive -eq 'Aktiv') { 'Comano' } else { 'n.v.' }
        $siteAdvantage = Get-SiteAdvantage -ZurichOverallRisk $zurichOverallRisk -ComanoOverallRisk $comanoOverallRisk
        $zurichMarginTrend = Get-MarginTrend -History $script:RfHistory.Zurich.Margin
        $zurichBeaconTrend = Get-BeaconTrend -History $script:RfHistory.Zurich.Beacon
        $comanoMarginTrend = Get-MarginTrend -History $script:RfHistory.Comano.Margin
        $comanoBeaconTrend = Get-BeaconTrend -History $script:RfHistory.Comano.Beacon
        if ($activeSite -eq 'Zürich') {
            $activeLinkHealth = $zurichLinkHealth; $activeOverallRisk = $zurichOverallRisk; $activeWeatherRisk = $zurichWeatherRisk
            $activeMarginTrend = $zurichMarginTrend; $activeBeaconTrend = $zurichBeaconTrend; $activeForecasts = $zurichWeather.Forecasts
        }
        elseif ($activeSite -eq 'Comano') {
            $activeLinkHealth = $comanoLinkHealth; $activeOverallRisk = $comanoOverallRisk; $activeWeatherRisk = $comanoWeatherRisk
            $activeMarginTrend = $comanoMarginTrend; $activeBeaconTrend = $comanoBeaconTrend; $activeForecasts = $comanoWeather.Forecasts
        }
        else {
            $activeLinkHealth = 'n.v.'; $activeOverallRisk = 'n.v.'; $activeWeatherRisk = 'n.v.'
            $activeMarginTrend = 'Nicht genügend Historie'; $activeBeaconTrend = 'Nicht genügend Historie'; $activeForecasts = @()
        }
        $currentFailure = Get-FailureProbability -LinkHealth $activeLinkHealth -WeatherRisk $activeWeatherRisk -MarginTrend $activeMarginTrend -BeaconTrend $activeBeaconTrend
        $futureRiskValues = @()
        foreach ($forecast in @($activeForecasts)) {
            $futureRiskValues += Get-FutureWeatherRiskScore -CurrentLinkHealth $activeLinkHealth -Forecast $forecast
        }
        $futureRisk = if ($futureRiskValues.Count -gt 0) { $futureRiskValues[0] } else { 'Noch keine Prognose verfügbar' }
        $predictedFailure = Get-PredictedFailureProbability -CurrentOverallRisk $activeOverallRisk -MarginTrend $activeMarginTrend -BeaconTrend $activeBeaconTrend
        $recommendation = Get-SwitchoverRecommendation -ActiveSite $activeSite -ZurichOverallRisk $zurichOverallRisk -ComanoOverallRisk $comanoOverallRisk -SiteAdvantage $siteAdvantage -MarginTrend $activeMarginTrend -BeaconTrend $activeBeaconTrend -PredictedFailureProbability $predictedFailure -FutureRisk $futureRisk

        Write-Host ''
        Write-Host '================================================' -ForegroundColor DarkGray
        Write-Host 'SAT-UPLINK BETRIEBSSTATUS' -ForegroundColor Cyan
        Write-Host '================================================' -ForegroundColor DarkGray
        Write-Host ("Aktiver Uplink: {0}" -f $activeSite.ToUpper()) -ForegroundColor Green
        Write-Host '------------------------------------------------' -ForegroundColor DarkGray
        $activeLinkHealthText = if ("$activeLinkHealth" -eq 'n.v.') { 'n.v.' } else { Get-LinkHealthText -HealthScore $activeLinkHealth }
        $activeOverallRiskText = if ("$activeOverallRisk" -eq 'n.v.') { 'n.v.' } else { Get-OverallUplinkRiskText -OverallRiskScore $activeOverallRisk }
        $activeWeatherRiskText = if ("$activeWeatherRisk" -eq 'n.v.') { 'n.v.' } else { Get-WeatherRiskText -WeatherRiskScore $activeWeatherRisk }
        Write-Host ("Link Health: {0}% ({1})" -f $activeLinkHealth, $activeLinkHealthText) -ForegroundColor (Get-ScoreColor -Score $activeLinkHealth -ScoreType LinkHealth)
        Write-Host '------------------------------------------------' -ForegroundColor DarkGray
        Write-Host ("Weather Risk: {0}% ({1})" -f $activeWeatherRisk, $activeWeatherRiskText) -ForegroundColor (Get-ScoreColor -Score $activeWeatherRisk -ScoreType Risk)
        Write-Host '------------------------------------------------' -ForegroundColor DarkGray
        Write-Host ("Overall Uplink Risk: {0}% ({1})" -f $activeOverallRisk, $activeOverallRiskText) -ForegroundColor (Get-ScoreColor -Score $activeOverallRisk -ScoreType Risk)
        Write-Host '------------------------------------------------' -ForegroundColor DarkGray
        Write-Host 'Standortvergleich' -ForegroundColor Cyan
        Write-Host ("Zürich: {0}%" -f $zurichOverallRisk)
        Write-Host ("Comano: {0}%" -f $comanoOverallRisk)
        Write-Host ("Differenz: {0}%" -f (Get-UplinkSiteComparison -ZurichOverallRisk $zurichOverallRisk -ComanoOverallRisk $comanoOverallRisk))
        Write-Host '------------------------------------------------' -ForegroundColor DarkGray
        Write-Host 'Standortvorteil' -ForegroundColor Cyan
        Write-Host $siteAdvantage.Site
        Write-Host ("Bewertung: {0}" -f $siteAdvantage.Rating)
        Write-Host '------------------------------------------------' -ForegroundColor DarkGray
        Write-Host 'Ausfallwahrscheinlichkeit' -ForegroundColor Cyan
        Write-Host ("Aktuell: {0}%" -f $currentFailure) -ForegroundColor (Get-ScoreColor -Score $currentFailure -ScoreType Risk)
        if ($futureRiskValues.Count -eq 0) {
            Write-Host 'Keine Future-Risk-Prognose verfügbar.' -ForegroundColor DarkYellow
        }
        else {
            for ($futureIndex = 0; $futureIndex -lt $futureRiskValues.Count; $futureIndex++) {
                $futureLabel = "+$((($futureIndex + 1) * 3))h"
                Write-Host ("{0}: {1}%" -f $futureLabel, $futureRiskValues[$futureIndex]) -ForegroundColor (Get-ScoreColor -Score $futureRiskValues[$futureIndex] -ScoreType Risk)
            }
        }
        Write-Host '------------------------------------------------' -ForegroundColor DarkGray
        Write-Host 'Umschaltempfehlung' -ForegroundColor Cyan
        Write-Host $recommendation -ForegroundColor (Get-RiskColor -Text $recommendation)
        Write-Host '================================================' -ForegroundColor DarkGray
        Write-Host 'Detailansicht: Menüpunkt 1' -ForegroundColor DarkGray
    }
    catch {
        Write-Host "Betriebsansicht konnte für $activeLocation nicht geladen werden: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Show-Weather {
    $activeLocation = "Authentifizierung"
    try {
        $accessToken = Get-SrfMeteoAccessToken
        $headers = @{ Authorization = "Bearer $accessToken" }
        $locations = @(
            @{ Name = "Fernsehstrasse Zürich"; Latitude = "47.4114"; Longitude = "8.5478" }
            @{ Name = "Lugano (SRF-Standort)"; Latitude = "46.0050"; Longitude = "8.9510" }
        )
        $weatherData = @()
        if ($null -eq $script:srfMeteoGeolocationIds) {
            $script:srfMeteoGeolocationIds = @{}
        }

        foreach ($location in $locations) {
            $activeLocation = $location.Name
            $geolocationId = $script:srfMeteoGeolocationIds[$location.Name]

            if ([string]::IsNullOrWhiteSpace($geolocationId)) {
                $geolocationUrl = "https://api.srgssr.ch/srf-meteo/v2/geolocations?latitude=$($location.Latitude)&longitude=$($location.Longitude)"
                $geolocationResults = @(Invoke-RestMethod -Uri $geolocationUrl -Headers $headers)
                $geolocation = $geolocationResults | Select-Object -First 1
                $geolocationId = [string]$geolocation.id

                if (-not [string]::IsNullOrWhiteSpace($geolocationId)) {
                    $script:srfMeteoGeolocationIds[$location.Name] = $geolocationId
                }
            }

            if ([string]::IsNullOrWhiteSpace($geolocationId)) {
                throw "SRF Meteo hat keine gültige Geolocation für $($location.Name) geliefert."
            }

            $forecastUrl = "https://api.srgssr.ch/srf-meteo/v2/forecastpoint/$geolocationId"
            $weather = Invoke-RestMethod -Uri $forecastUrl -Headers $headers

            if ($script:EnableWeatherDump) {
                $dumpPath = Save-SrfWeatherPayloadDump `
                    -Payload $weather `
                    -LocationName $location.Name

                Write-Host "SRF Payload gespeichert: $dumpPath" -ForegroundColor DarkGray
            }

            $now = Get-Date
            $currentForecast = $weather.hours |
                Where-Object { (Get-Date $_.date_time) -ge $now } |
                Select-Object -First 1

            if ($null -eq $currentForecast) {
                throw "SRF Meteo hat keine stündlichen Wetterdaten für $($location.Name) geliefert."
            }

            $forecasts = @($weather.three_hours |
                Where-Object { (Get-Date $_.date_time) -gt $now } |
                Select-Object -First 3)

            $weatherData += ,@{
                Name = $location.Name
                Current = $currentForecast
                Forecasts = $forecasts
            }
        }

        $firstLocation = $weatherData[0]
        $secondLocation = $weatherData[1]
        $firstCurrent = $firstLocation.Current
        $secondCurrent = $secondLocation.Current
        $now = Get-Date

        Write-Host ""
        Write-Host "Wettervergleich für den aktiven Sat-Uplink" -ForegroundColor Cyan
        Write-Host $now -ForegroundColor Cyan
        Write-Host "============================================" -ForegroundColor DarkGray
        Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "Messwert", $firstLocation.Name, $secondLocation.Name) -ForegroundColor Yellow
        Write-Host ("{0,-34}-+-{1,-28}-+-{2,-28}" -f ("-" * 34), ("-" * 28), ("-" * 28)) -ForegroundColor DarkGray
        Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "Temperatur", "$([int]$firstCurrent.TTT_C) °C", "$([int]$secondCurrent.TTT_C) °C")
        Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "Gefühlte Temperatur", (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $firstCurrent -CandidateNames @('TTTFEEL_C')) -Unit " °C" -RoundToInteger $false), (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $secondCurrent -CandidateNames @('TTTFEEL_C')) -Unit " °C" -RoundToInteger $false))
        Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "Niederschlagswahrscheinlichkeit", (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $firstCurrent -CandidateNames @('PROBPCP_PERCENT')) -Unit "%" -RoundToInteger $true), (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $secondCurrent -CandidateNames @('PROBPCP_PERCENT')) -Unit "%" -RoundToInteger $true))
        Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "Niederschlagsmenge", (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $firstCurrent -CandidateNames @('RRR_MM')) -Unit " mm" -RoundToInteger $false), (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $secondCurrent -CandidateNames @('RRR_MM')) -Unit " mm" -RoundToInteger $false))
        Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "Wind", (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $firstCurrent -CandidateNames @('FF_KMH')) -Unit " km/h" -RoundToInteger $true), (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $secondCurrent -CandidateNames @('FF_KMH')) -Unit " km/h" -RoundToInteger $true))
        Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "Windrichtung", (Get-WindDirectionText -Degrees (Get-WeatherMetricValue -ValueObject $firstCurrent -CandidateNames @('DD_DEG'))), (Get-WindDirectionText -Degrees (Get-WeatherMetricValue -ValueObject $secondCurrent -CandidateNames @('DD_DEG'))))
        Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "Windböen", (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $firstCurrent -CandidateNames @('FX_KMH')) -Unit " km/h" -RoundToInteger $true), (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $secondCurrent -CandidateNames @('FX_KMH')) -Unit " km/h" -RoundToInteger $true))
        Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "Luftfeuchtigkeit", (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $firstCurrent -CandidateNames @('RELHUM_PERCENT')) -Unit "%" -RoundToInteger $true), (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $secondCurrent -CandidateNames @('RELHUM_PERCENT')) -Unit "%" -RoundToInteger $true))
        Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "Taupunkt", (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $firstCurrent -CandidateNames @('DEWPOINT_C')) -Unit " °C" -RoundToInteger $false), (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $secondCurrent -CandidateNames @('DEWPOINT_C')) -Unit " °C" -RoundToInteger $false))
        Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "Schneefall", (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $firstCurrent -CandidateNames @('FRESHSNOW_MM')) -Unit " mm" -RoundToInteger $false), (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $secondCurrent -CandidateNames @('FRESHSNOW_MM')) -Unit " mm" -RoundToInteger $false))
        Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "Luftdruck", (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $firstCurrent -CandidateNames @('PRESSURE_HPA')) -Unit " hPa" -RoundToInteger $false), (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $secondCurrent -CandidateNames @('PRESSURE_HPA')) -Unit " hPa" -RoundToInteger $false))
        Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "Sonneneinstrahlung", (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $firstCurrent -CandidateNames @('IRRADIANCE_WM2')) -Unit " W/m²" -RoundToInteger $false), (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $secondCurrent -CandidateNames @('IRRADIANCE_WM2')) -Unit " W/m²" -RoundToInteger $false))
        Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "Wetterlage", (Get-SrfWeatherCodeSummary ([int]$firstCurrent.symbol_code)), (Get-SrfWeatherCodeSummary ([int]$secondCurrent.symbol_code)))
        Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "Gewitterrisiko", ("{0}%" -f (Get-ThunderstormRiskPercent -Forecast $firstCurrent)), ("{0}%" -f (Get-ThunderstormRiskPercent -Forecast $secondCurrent)))
        $firstWeatherRisk = Get-WeatherRiskScore -Forecast $firstCurrent
        $secondWeatherRisk = Get-WeatherRiskScore -Forecast $secondCurrent
        Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "Weather Risk", ("{0}%" -f $firstWeatherRisk), ("{0}%" -f $secondWeatherRisk))
        Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "Weather Bewertung", (Get-WeatherRiskText -WeatherRiskScore $firstWeatherRisk), (Get-WeatherRiskText -WeatherRiskScore $secondWeatherRisk)) -ForegroundColor (Get-RiskColor -Text (Get-WeatherRiskText -WeatherRiskScore $firstWeatherRisk))

        Write-Host ""
        Write-Host "RF-Monitoring" -ForegroundColor Cyan
        Write-Host "============================================" -ForegroundColor DarkGray

        $useRfSimulation = $script:UseRfSimulationData -and $script:RfSimulationData
        $useRfGrafana = (-not $script:UseRfSimulationData) -and $script:EnableRfMonitoring

        if (
            $useRfSimulation -or
            $useRfGrafana
        ) {
            $rfMetrics = Get-UplinkRfMetrics -GrafanaUrl $script:GrafanaUrl -DatasourceUid $script:GrafanaDatasourceUid
            Add-RfHistoryValue -SiteName 'Zurich' -Metrics $rfMetrics.Zurich
            Add-RfHistoryValue -SiteName 'Comano' -Metrics $rfMetrics.Lugano

            if ($script:UseRfSimulationData -and $script:RfDataSource -eq "SimulationDefault") {
                Write-Host "RF-Quelle: Simulation (Standardwerte)" -ForegroundColor Yellow
            }
            elseif ($script:UseRfSimulationData -and $script:RfDataSource -eq "SimulationCustom") {
                Write-Host "RF-Quelle: Simulation (Benutzereingabe)" -ForegroundColor Yellow
            }
            elseif ($script:EnableRfMonitoring) {
                Write-Host "RF-Quelle: Grafana Proxy API" -ForegroundColor Green
            }

            $zurichActive = Get-UplinkActiveState -SiteName "Zurich" -RawValue $rfMetrics.Zurich.Active
            $luganoActive = Get-UplinkActiveState -SiteName "Comano" -RawValue $rfMetrics.Lugano.Active

            $activeLocation = "n.v."
            if ($zurichActive -eq "Aktiv") {
                $activeLocation = "Zürich"
            }
            elseif ($luganoActive -eq "Aktiv") {
                $activeLocation = "Comano"
            }

            $zurichActiveDisplay = if ($zurichActive -eq "Aktiv") { "Ja" } elseif ($zurichActive -eq "Inaktiv") { "Nein" } else { "n.v." }
            $luganoActiveDisplay = if ($luganoActive -eq "Aktiv") { "Ja" } elseif ($luganoActive -eq "Inaktiv") { "Nein" } else { "n.v." }
            $zurichPath = if ("$($rfMetrics.Zurich.Path)" -eq "1") { "Pfad A" } elseif ("$($rfMetrics.Zurich.Path)" -eq "0") { "Pfad B" } else { "n.v." }
            $luganoPath = if ("$($rfMetrics.Lugano.Path)" -eq "1") { "Pfad A" } elseif ("$($rfMetrics.Lugano.Path)" -eq "0") { "Pfad B" } else { "n.v." }

            Write-Host ""
            Write-Host "Uplink-Status" -ForegroundColor Cyan
            Write-Host ("AKTIVER UPLINK: {0}" -f $activeLocation) -ForegroundColor Green
            Write-Host ("{0,-24} {1}" -f "Aktiver Standort:", $activeLocation) -ForegroundColor White
            Write-Host ("{0,-24} {1,-10} | {2,-10}" -f "", "Zürich", "Comano") -ForegroundColor Yellow
            Write-Host ("{0,-24} {1,-10} | {2,-10}" -f "Aktiv", $zurichActiveDisplay, $luganoActiveDisplay) -ForegroundColor Green
            Write-Host ("{0,-24} {1,-10} | {2,-10}" -f "Pfad", $zurichPath, $luganoPath)
            Write-Host ""

            Write-Host ("{0,-24} | {1,-10} | {2,-10}" -f "Messwert", "Zürich", "Lugano") -ForegroundColor Yellow
            Write-Host ("{0,-24}-+-{1,-10}-+-{2,-10}" -f ("-" * 24), ("-" * 10), ("-" * 10)) -ForegroundColor DarkGray

            Write-Host ("{0,-24} | {1,-10} | {2,-10}" -f "IRD Margin", (Format-RfMetricText -Value $rfMetrics.Zurich.IRDMargin -Unit " dB" -Decimals 1), (Format-RfMetricText -Value $rfMetrics.Lugano.IRDMargin -Unit " dB" -Decimals 1))
            Write-Host ("{0,-24} | {1,-10} | {2,-10}" -f "Beacon Level", (Format-RfMetricText -Value $rfMetrics.Zurich.BeaconLevel -Unit " dBm" -Decimals 2), (Format-RfMetricText -Value $rfMetrics.Lugano.BeaconLevel -Unit " dBm" -Decimals 2))
            Write-Host ("{0,-24} | {1,-10} | {2,-10}" -f "Azimuth", (Format-RfMetricText -Value $rfMetrics.Zurich.Azimuth -Unit "°" -Decimals 3), (Format-RfMetricText -Value $rfMetrics.Lugano.Azimuth -Unit "°" -Decimals 3))
            Write-Host ("{0,-24} | {1,-10} | {2,-10}" -f "Elevation", (Format-RfMetricText -Value $rfMetrics.Zurich.Elevation -Unit "°" -Decimals 3), (Format-RfMetricText -Value $rfMetrics.Lugano.Elevation -Unit "°" -Decimals 3))

            $zurichLinkHealth = Get-LinkHealthScore -IRDMargin $rfMetrics.Zurich.IRDMargin -BeaconLevel $rfMetrics.Zurich.BeaconLevel
            $luganoLinkHealth = Get-LinkHealthScore -IRDMargin $rfMetrics.Lugano.IRDMargin -BeaconLevel $rfMetrics.Lugano.BeaconLevel
            $zurichLinkHealthText = if ("$zurichLinkHealth" -eq "n.v.") { "n.v." } else { Get-LinkHealthText -HealthScore $zurichLinkHealth }
            $luganoLinkHealthText = if ("$luganoLinkHealth" -eq "n.v.") { "n.v." } else { Get-LinkHealthText -HealthScore $luganoLinkHealth }

            Write-Host ""
            Write-Host "Link Health" -ForegroundColor Cyan
            Write-Host ("{0,-24} | {1,-10} | {2,-10}" -f "Standort", "Zürich", "Comano") -ForegroundColor Yellow
            Write-Host ("{0,-24} | {1,-10} | {2,-10}" -f "Score", ("{0} %" -f $zurichLinkHealth), ("{0} %" -f $luganoLinkHealth))
            Write-Host ("{0,-24} | {1,-10} | {2,-10}" -f "Bewertung", $zurichLinkHealthText, $luganoLinkHealthText) -ForegroundColor (Get-RiskColor -Text $zurichLinkHealthText)

            $zurichOverallRisk = Get-OverallUplinkRiskScore -LinkHealthScore $zurichLinkHealth -WeatherRiskScore $firstWeatherRisk
            $luganoOverallRisk = Get-OverallUplinkRiskScore -LinkHealthScore $luganoLinkHealth -WeatherRiskScore $secondWeatherRisk
            $zurichOverallRiskText = if ("$zurichOverallRisk" -eq "n.v.") { "n.v." } else { Get-OverallUplinkRiskText -OverallRiskScore $zurichOverallRisk }
            $luganoOverallRiskText = if ("$luganoOverallRisk" -eq "n.v.") { "n.v." } else { Get-OverallUplinkRiskText -OverallRiskScore $luganoOverallRisk }

            Write-Host ""
            Write-Host "Overall Uplink Risk" -ForegroundColor Cyan
            Write-Host ("{0,-24} | {1,-10} | {2,-10}" -f "Standort", "Zürich", "Comano") -ForegroundColor Yellow
            Write-Host ("{0,-24} | {1,-10} | {2,-10}" -f "Score", ("{0} %" -f $zurichOverallRisk), ("{0} %" -f $luganoOverallRisk))
            Write-Host ("{0,-24} | {1,-10} | {2,-10}" -f "Bewertung", $zurichOverallRiskText, $luganoOverallRiskText) -ForegroundColor (Get-RiskColor -Text $zurichOverallRiskText)

            $activeOverallRisk = "n.v."
            $activeOverallRiskText = "n.v."
            if ($activeLocation -eq "Zürich") {
                $activeOverallRisk = $zurichOverallRisk
                $activeOverallRiskText = $zurichOverallRiskText
            }
            elseif ($activeLocation -eq "Comano") {
                $activeOverallRisk = $luganoOverallRisk
                $activeOverallRiskText = $luganoOverallRiskText
            }
            Write-Host ("{0,-24} {1}" -f "Aktiver Uplink Risk:", ("{0} %" -f $activeOverallRisk)) -ForegroundColor White
            Write-Host ("{0,-24} {1}" -f "Bewertung:", $activeOverallRiskText) -ForegroundColor (Get-RiskColor -Text $activeOverallRiskText)

            $siteAdvantage = Get-SiteAdvantage -ZurichOverallRisk $zurichOverallRisk -ComanoOverallRisk $luganoOverallRisk
            $riskDifference = Get-UplinkSiteComparison -ZurichOverallRisk $zurichOverallRisk -ComanoOverallRisk $luganoOverallRisk
            $zurichMarginTrend = Get-MarginTrend -History $script:RfHistory.Zurich.Margin
            $zurichBeaconTrend = Get-BeaconTrend -History $script:RfHistory.Zurich.Beacon
            $comanoMarginTrend = Get-MarginTrend -History $script:RfHistory.Comano.Margin
            $comanoBeaconTrend = Get-BeaconTrend -History $script:RfHistory.Comano.Beacon
            $zurichMarginDelta = Get-RfTrendDelta -History $script:RfHistory.Zurich.Margin
            $zurichBeaconDelta = Get-RfTrendDelta -History $script:RfHistory.Zurich.Beacon
            $comanoMarginDelta = Get-RfTrendDelta -History $script:RfHistory.Comano.Margin
            $comanoBeaconDelta = Get-RfTrendDelta -History $script:RfHistory.Comano.Beacon
            $zurichDrivers = Get-RiskDrivers -Forecast $firstCurrent
            $comanoDrivers = Get-RiskDrivers -Forecast $secondCurrent
            if ($activeLocation -eq 'Zürich') {
                $activeMarginTrend = $zurichMarginTrend
                $activeBeaconTrend = $zurichBeaconTrend
                $activeLinkHealth = $zurichLinkHealth
                $activeWeatherRisk = $firstWeatherRisk
            }
            elseif ($activeLocation -eq 'Comano') {
                $activeMarginTrend = $comanoMarginTrend
                $activeBeaconTrend = $comanoBeaconTrend
                $activeLinkHealth = $luganoLinkHealth
                $activeWeatherRisk = $secondWeatherRisk
            }
            else {
                $activeMarginTrend = 'Stabil'
                $activeBeaconTrend = 'Stabil'
                $activeLinkHealth = 'n.v.'
                $activeWeatherRisk = 'n.v.'
            }
            $zurichPredictedLinkHealth = Get-PredictedLinkHealth -CurrentLinkHealth $zurichLinkHealth -MarginTrend $zurichMarginTrend -BeaconTrend $zurichBeaconTrend
            $luganoPredictedLinkHealth = Get-PredictedLinkHealth -CurrentLinkHealth $luganoLinkHealth -MarginTrend $comanoMarginTrend -BeaconTrend $comanoBeaconTrend
            $activePredictedFailure = Get-PredictedFailureProbability -CurrentOverallRisk $activeOverallRisk -MarginTrend $activeMarginTrend -BeaconTrend $activeBeaconTrend
            $zurichFutureRisks = @($firstLocation.Forecasts | ForEach-Object { Get-FutureWeatherRiskScore -CurrentLinkHealth $zurichLinkHealth -Forecast $_ })
            $comanoFutureRisks = @($secondLocation.Forecasts | ForEach-Object { Get-FutureWeatherRiskScore -CurrentLinkHealth $luganoLinkHealth -Forecast $_ })
            $activeFutureRisks = if ($activeLocation -eq 'Zürich') { $zurichFutureRisks } else { $comanoFutureRisks }
            $futureRiskSignal = if ($activeFutureRisks.Count -gt 0) { $activeFutureRisks[0] } else { 'Noch keine Prognose verfügbar' }
            $recommendation = Get-SwitchoverRecommendation -ActiveSite $activeLocation -ZurichOverallRisk $zurichOverallRisk -ComanoOverallRisk $luganoOverallRisk -SiteAdvantage $siteAdvantage -MarginTrend $activeMarginTrend -BeaconTrend $activeBeaconTrend -PredictedFailureProbability $activePredictedFailure -FutureRisk $futureRiskSignal
            $failureProbability = Get-FailureProbability -LinkHealth $activeLinkHealth -WeatherRisk $activeWeatherRisk -MarginTrend $activeMarginTrend -BeaconTrend $activeBeaconTrend
            $failureText = if ("$failureProbability" -eq 'n.v.') { 'n.v.' } else { Get-FailureProbabilityText -FailureProbability $failureProbability }

            Write-Host ""
            Write-Host "ENTSCHEIDUNGSUNTERSTÜTZUNG" -ForegroundColor Cyan
            Write-Host "================================================" -ForegroundColor DarkGray
            Write-Host "Standortvergleich" -ForegroundColor Cyan
            Write-Host ("Zürich Risk:  {0} %" -f $zurichOverallRisk)
            Write-Host ("Comano Risk:  {0} %" -f $luganoOverallRisk)
            Write-Host ("Differenz:    {0} %" -f $riskDifference)
            Write-Host ""
            Write-Host "Standortvorteil:" -ForegroundColor Cyan
            Write-Host ("{0} ({1})" -f $siteAdvantage.Site, $siteAdvantage.Rating)
            Write-Host ""
            Write-Host "RF-Trend" -ForegroundColor Cyan
            Write-Host ("{0,-18} {1}" -f "Zürich Margin:", $zurichMarginTrend) -ForegroundColor (Get-RiskColor -Text $zurichMarginTrend)
            Write-Host ("{0,-18} {1}" -f "Zürich Beacon:", $zurichBeaconTrend) -ForegroundColor (Get-RiskColor -Text $zurichBeaconTrend)
            Write-Host ("{0,-18} {1}" -f "Comano Margin:", $comanoMarginTrend) -ForegroundColor (Get-RiskColor -Text $comanoMarginTrend)
            Write-Host ("{0,-18} {1}" -f "Comano Beacon:", $comanoBeaconTrend) -ForegroundColor (Get-RiskColor -Text $comanoBeaconTrend)
            Write-Host ("{0,-18} {1:+0.0;-0.0;0.0} dB" -f "Zürich Margin Δ:", $zurichMarginDelta)
            Write-Host ("{0,-18} {1:+0.0;-0.0;0.0} dBm" -f "Zürich Beacon Δ:", $zurichBeaconDelta)
            Write-Host ("{0,-18} {1:+0.0;-0.0;0.0} dB" -f "Comano Margin Δ:", $comanoMarginDelta)
            Write-Host ("{0,-18} {1:+0.0;-0.0;0.0} dBm" -f "Comano Beacon Δ:", $comanoBeaconDelta)
            Write-Host ""
            Write-Host "Risikotreiber" -ForegroundColor Cyan
            Write-Host ("{0,-20} | {1,-10} | {2,-10}" -f "Wetter", "Zürich", "Comano") -ForegroundColor Yellow
            Write-Host ("{0,-20} | {1,-10} | {2,-10}" -f "Gewitter", ("{0}%" -f $zurichDrivers.Thunderstorm), ("{0}%" -f $comanoDrivers.Thunderstorm))
            Write-Host ("{0,-20} | {1,-10} | {2,-10}" -f "Niederschlag", ("{0} mm" -f $zurichDrivers.RainAmount), ("{0} mm" -f $comanoDrivers.RainAmount))
            Write-Host ("{0,-20} | {1,-10} | {2,-10}" -f "Windböen", ("{0} km/h" -f $zurichDrivers.WindGust), ("{0} km/h" -f $comanoDrivers.WindGust))
            Write-Host ("{0,-20} | {1,-10} | {2,-10}" -f "Feuchtigkeit", ("{0}%" -f $zurichDrivers.Humidity), ("{0}%" -f $comanoDrivers.Humidity))
            Write-Host ("{0,-20} | {1,-10} | {2,-10}" -f "IRD Margin", ("{0} dB" -f $rfMetrics.Zurich.IRDMargin), ("{0} dB" -f $rfMetrics.Lugano.IRDMargin))
            Write-Host ("{0,-20} | {1,-10} | {2,-10}" -f "Beacon", ("{0} dBm" -f $rfMetrics.Zurich.BeaconLevel), ("{0} dBm" -f $rfMetrics.Lugano.BeaconLevel))
            Write-Host ""
            Write-Host "PROGNOSE" -ForegroundColor Cyan
            Write-Host "================================================" -ForegroundColor DarkGray
            Write-Host "Link Health Prognose" -ForegroundColor Cyan
            Write-Host ("Zürich: {0}" -f $(if ("$zurichPredictedLinkHealth" -eq 'Nicht genügend Historie') { 'Nicht genügend Historie' } else { "$zurichPredictedLinkHealth %" }))
            Write-Host ("Comano: {0}" -f $(if ("$luganoPredictedLinkHealth" -eq 'Nicht genügend Historie') { 'Nicht genügend Historie' } else { "$luganoPredictedLinkHealth %" }))
            Write-Host ""
            Write-Host "Future Risk" -ForegroundColor Cyan
            $futureLabels = @('+3h', '+6h', '+9h')
            $forecastCount = $zurichFutureRisks.Count
            if ($forecastCount -gt $comanoFutureRisks.Count) { $forecastCount = $comanoFutureRisks.Count }
            if ($forecastCount -gt 3) { $forecastCount = 3 }
            if ($forecastCount -eq 0) {
                Write-Host 'Noch keine Prognose verfügbar' -ForegroundColor DarkYellow
            }
            for ($futureIndex = 0; $futureIndex -lt $forecastCount; $futureIndex++) {
                $zurichFutureRisk = $zurichFutureRisks[$futureIndex]
                $comanoFutureRisk = $comanoFutureRisks[$futureIndex]
                $zurichDelta = [int]$zurichFutureRisk - [int]$zurichOverallRisk
                $comanoDelta = [int]$comanoFutureRisk - [int]$luganoOverallRisk
                Write-Host ("{0,-5} Zürich: {1}% ({2:+0;-0;0}) | Comano: {3}% ({4:+0;-0;0})" -f $futureLabels[$futureIndex], $zurichFutureRisk, $zurichDelta, $comanoFutureRisk, $comanoDelta)
            }
            Write-Host ""
            Write-Host "Ausfallwahrscheinlichkeit" -ForegroundColor Cyan
            Write-Host ("Aktuell: {0} % ({1})" -f $failureProbability, $failureText)
            if ($activeFutureRisks.Count -eq 0) {
                Write-Host 'Noch keine Prognose verfügbar' -ForegroundColor DarkYellow
            }
            else {
                for ($futureIndex = 0; $futureIndex -lt $activeFutureRisks.Count; $futureIndex++) {
                    $futureFailure = Get-PredictedFailureProbability -CurrentOverallRisk $activeFutureRisks[$futureIndex] -MarginTrend $activeMarginTrend -BeaconTrend $activeBeaconTrend
                    if ("$futureFailure" -eq 'Nicht genügend Historie') {
                        Write-Host ("{0}: Noch keine Prognose verfügbar" -f $futureLabels[$futureIndex]) -ForegroundColor DarkYellow
                    }
                    else {
                        Write-Host ("{0}: {1} % ({2})" -f $futureLabels[$futureIndex], $futureFailure, (Get-FailureProbabilityText -FailureProbability $futureFailure)) -ForegroundColor (Get-ScoreColor -Score $futureFailure -ScoreType Risk)
                    }
                }
            }
            Write-Host ""
            Write-Host "Umschaltempfehlung" -ForegroundColor Cyan
            Write-Host ("Aktuell: {0}" -f $recommendation) -ForegroundColor (Get-RiskColor -Text $recommendation)
            if ($activeFutureRisks.Count -eq 0) {
                Write-Host 'Future: Noch keine Prognose verfügbar' -ForegroundColor DarkYellow
            }
            else {
                for ($futureIndex = 0; $futureIndex -lt $activeFutureRisks.Count; $futureIndex++) {
                    $futureRecommendation = Get-SwitchoverRecommendation -ActiveSite $activeLocation -ZurichOverallRisk $zurichOverallRisk -ComanoOverallRisk $luganoOverallRisk -SiteAdvantage $siteAdvantage -MarginTrend $activeMarginTrend -BeaconTrend $activeBeaconTrend -PredictedFailureProbability (Get-PredictedFailureProbability -CurrentOverallRisk $activeFutureRisks[$futureIndex] -MarginTrend $activeMarginTrend -BeaconTrend $activeBeaconTrend) -FutureRisk $activeFutureRisks[$futureIndex]
                    Write-Host ("{0}: {1}" -f $futureLabels[$futureIndex], $futureRecommendation) -ForegroundColor (Get-RiskColor -Text $futureRecommendation)
                }
            }
            Write-Host "================================================" -ForegroundColor DarkGray

        }
        else {
            Write-Host "Keine RF-Daten verfügbar." -ForegroundColor DarkYellow
            Write-Host "RF-Monitoring deaktiviert." -ForegroundColor DarkYellow
            Write-Host "Keine Simulation aktiv." -ForegroundColor DarkYellow
        }

        Write-Host ""
        Write-Host "Infrastruktur" -ForegroundColor Cyan
        Write-Host ("{0,-24} {1}" -f "Satellit:", $script:UplinkInfrastructure.Satellite) -ForegroundColor White
        Write-Host ("{0,-24} {1}" -f "Transponder:", $script:UplinkInfrastructure.Transponder) -ForegroundColor White
        Write-Host ("{0,-24} {1}" -f "Uplink-Frequenz:", ("{0} MHz" -f $script:UplinkInfrastructure.UplinkFrequencyMHz)) -ForegroundColor White
        Write-Host ""
        Write-Host "Zürich:" -ForegroundColor Cyan
        Write-Host ("{0,-24} {1}" -f "Antennendurchmesser:", ("{0} m" -f $script:UplinkInfrastructure.Zurich.AntennaSizeM)) -ForegroundColor White
        Write-Host ("{0,-24} {1}" -f "TX Power:", ("{0} dBm" -f $script:UplinkInfrastructure.Zurich.TxPowerDbm)) -ForegroundColor White
        Write-Host ""
        Write-Host "Comano:" -ForegroundColor Cyan
        Write-Host ("{0,-24} {1}" -f "Antennendurchmesser:", ("{0} m" -f $script:UplinkInfrastructure.Lugano.AntennaSizeM)) -ForegroundColor White

        Write-Host ""
        Write-Host "Vorhersagevergleich" -ForegroundColor Cyan
        Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "Zeit / Messwert", $firstLocation.Name, $secondLocation.Name) -ForegroundColor Yellow
        Write-Host ("{0,-34}-+-{1,-28}-+-{2,-28}" -f ("-" * 34), ("-" * 28), ("-" * 28)) -ForegroundColor DarkGray

        $firstForecasts = @($firstLocation.Forecasts)
        $secondForecasts = @($secondLocation.Forecasts)
        $forecastCount = $firstForecasts.Count
        if ($secondForecasts.Count -lt $forecastCount) {
            $forecastCount = $secondForecasts.Count
        }

        for ($index = 0; $index -lt $forecastCount; $index++) {
            $firstForecast = $firstForecasts[$index]
            $secondForecast = $secondForecasts[$index]
            $hour = (Get-Date $firstForecast.date_time).ToString("HH:mm")

            Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "$hour Temperatur", "$([int]$firstForecast.TTT_C) °C", "$([int]$secondForecast.TTT_C) °C")
            Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "$hour Gefühlte Temperatur", (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $firstForecast -CandidateNames @('TTTFEEL_C')) -Unit " °C" -RoundToInteger $false), (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $secondForecast -CandidateNames @('TTTFEEL_C')) -Unit " °C" -RoundToInteger $false))
            Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "$hour Regenwahrscheinlichkeit", (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $firstForecast -CandidateNames @('PROBPCP_PERCENT')) -Unit "%" -RoundToInteger $true), (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $secondForecast -CandidateNames @('PROBPCP_PERCENT')) -Unit "%" -RoundToInteger $true))
            Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "$hour Niederschlagsmenge", (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $firstForecast -CandidateNames @('RRR_MM')) -Unit " mm" -RoundToInteger $false), (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $secondForecast -CandidateNames @('RRR_MM')) -Unit " mm" -RoundToInteger $false))
            Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "$hour Wind", (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $firstForecast -CandidateNames @('FF_KMH')) -Unit " km/h" -RoundToInteger $true), (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $secondForecast -CandidateNames @('FF_KMH')) -Unit " km/h" -RoundToInteger $true))
            Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "$hour Windrichtung", (Get-WindDirectionText -Degrees (Get-WeatherMetricValue -ValueObject $firstForecast -CandidateNames @('DD_DEG'))), (Get-WindDirectionText -Degrees (Get-WeatherMetricValue -ValueObject $secondForecast -CandidateNames @('DD_DEG'))))
            Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "$hour Windböen", (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $firstForecast -CandidateNames @('FX_KMH')) -Unit " km/h" -RoundToInteger $true), (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $secondForecast -CandidateNames @('FX_KMH')) -Unit " km/h" -RoundToInteger $true))
            Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "$hour Luftfeuchtigkeit", (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $firstForecast -CandidateNames @('RELHUM_PERCENT')) -Unit "%" -RoundToInteger $true), (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $secondForecast -CandidateNames @('RELHUM_PERCENT')) -Unit "%" -RoundToInteger $true))
            Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "$hour Taupunkt", (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $firstForecast -CandidateNames @('DEWPOINT_C')) -Unit " °C" -RoundToInteger $false), (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $secondForecast -CandidateNames @('DEWPOINT_C')) -Unit " °C" -RoundToInteger $false))
            Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "$hour Schneefall", (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $firstForecast -CandidateNames @('FRESHSNOW_MM')) -Unit " mm" -RoundToInteger $false), (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $secondForecast -CandidateNames @('FRESHSNOW_MM')) -Unit " mm" -RoundToInteger $false))
            Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "$hour Luftdruck", (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $firstForecast -CandidateNames @('PRESSURE_HPA')) -Unit " hPa" -RoundToInteger $false), (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $secondForecast -CandidateNames @('PRESSURE_HPA')) -Unit " hPa" -RoundToInteger $false))
            Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "$hour Sonneneinstrahlung", (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $firstForecast -CandidateNames @('IRRADIANCE_WM2')) -Unit " W/m²" -RoundToInteger $false), (Get-WeatherMetricText -Value (Get-WeatherMetricValue -ValueObject $secondForecast -CandidateNames @('IRRADIANCE_WM2')) -Unit " W/m²" -RoundToInteger $false))
            Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "$hour Wetterlage", (Get-SrfWeatherCodeSummary ([int]$firstForecast.symbol_code)), (Get-SrfWeatherCodeSummary ([int]$secondForecast.symbol_code)))
            Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "$hour Gewitterrisiko", ("{0}%" -f (Get-ThunderstormRiskPercent -Forecast $firstForecast)), ("{0}%" -f (Get-ThunderstormRiskPercent -Forecast $secondForecast)))
            $firstForecastWeatherRisk = Get-WeatherRiskScore -Forecast $firstForecast
            $secondForecastWeatherRisk = Get-WeatherRiskScore -Forecast $secondForecast
            Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "$hour Weather Risk", ("{0}%" -f $firstForecastWeatherRisk), ("{0}%" -f $secondForecastWeatherRisk))
            Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "$hour Weather Bewertung", (Get-WeatherRiskText -WeatherRiskScore $firstForecastWeatherRisk), (Get-WeatherRiskText -WeatherRiskScore $secondForecastWeatherRisk))
            Write-Host ("{0,-34} | {1,-28} | {2,-28}" -f "", "", "")
        }


    }
    catch {
        Write-Host "Wetterdaten für $activeLocation konnten nicht abgerufen werden: $($_.Exception.Message)" -ForegroundColor Red
    }
}

do {

    Clear-Host

    Write-Host "====================================" -ForegroundColor DarkYellow
    Write-Host "   Sat-Uplink Wetter Monitor" -ForegroundColor DarkGreen
    Write-Host "====================================" -ForegroundColor DarkYellow
    Write-Host ""
    Write-Host "1 - lokales Wetter"
    Write-Host "2 - RF-Testdaten laden"
    Write-Host "3 - RF-Testdaten manuell eingeben"
    Write-Host "4 - RF-Testdaten löschen"
    Write-Host "5 - Grafana-Verbindung testen"
    $rfMonitoringState = "Inaktiv"
    if ($script:EnableRfMonitoring) {
        $rfMonitoringState = "Aktiv"
    }
    Write-Host ("6 - RF-Monitoring umschalten (aktuell: {0})" -f $rfMonitoringState)
    Write-Host "7 - RF-Query testen"
    Write-Host "8 - Betriebsansicht"
    Write-Host "Q - Beenden"
    Write-Host ""

    $choice = Read-Host "Auswahl"

    switch ($choice.ToUpper()) {

        "1" {
            Show-Weather
        }

        "2" {
            Set-DefaultRfSimulationData
        }

        "3" {
            Set-CustomRfSimulationData
        }

        "4" {
            Clear-RfSimulationData
        }

        "5" {
            Test-GrafanaConnection
        }

        "6" {
            Set-RfMonitoringState
        }

        "7" {
            Test-RfMetricQuery -Query "sat_uplink_t123_zur13"
            Test-RfMetricQuery -Query "sat_uplink_t123_zur13_ird_margin"
            Test-RfMetricQuery -Query "sat_uplink_t123_zur13_odm_beaconlevel"
        }

        "8" {
            Show-OperationalView
        }

        "Q" {
            Write-Host "Programm wird beendet..."
        }

        default {
            Write-Host ""
            Write-Host "Ungültige Auswahl." -ForegroundColor Red
        }
    }

    if ($choice.ToUpper() -ne "Q") {
        Write-Host ""
        Read-Host "Enter drücken für Hauptmenü"
        
    }

} while ($choice.ToUpper() -ne "Q")