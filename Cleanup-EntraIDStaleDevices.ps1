#Requires -Modules @{ ModuleName="Microsoft.Graph.Authentication"; ModuleVersion="2.0.0" }
#Requires -Modules @{ ModuleName="Microsoft.Graph.Identity.DirectoryManagement"; ModuleVersion="2.0.0" }
#Requires -Modules @{ ModuleName="Microsoft.Graph.Users.Actions"; ModuleVersion="2.0.0" }
#Requires -Modules @{ ModuleName="Microsoft.Graph.DeviceManagement.Enrollment"; ModuleVersion="2.0.0" }

<#
.SYNOPSIS
    Deletes stale Entra ID devices without BitLocker keys and sends reports via Azure Communication Services
.DESCRIPTION
    This runbook identifies and deletes devices that:
    - Haven't synced in X days (configurable)
    - Are NOT registered in Autopilot
    - Do NOT have BitLocker recovery keys escrowed
    Logs are sent to Log Analytics and email reports via Azure Communication Services
#>

param(
    [Parameter(Mandatory=$false)]
    [int]$StaleDays = 180,
    
    [Parameter(Mandatory=$false)]
    [string]$RecipientEmail = "admin@yourdomain.com",
    
    [Parameter(Mandatory=$false)]
    [bool]$WhatIf = $true
)

# Variables - Configure these in Azure Automation Variables or update here
$WorkspaceId = Get-AutomationVariable -Name 'LogAnalyticsWorkspaceId'
$WorkspaceKey = Get-AutomationVariable -Name 'LogAnalyticsWorkspaceKey'
$AcsConnectionString = Get-AutomationVariable -Name 'AcsConnectionString'
$SenderEmail = Get-AutomationVariable -Name 'SenderEmail'

# Log Analytics Function
function Send-LogAnalyticsData {
    param(
        [string]$WorkspaceId,
        [string]$WorkspaceKey,
        [string]$LogType,
        [object]$LogData
    )
    
    $json = $LogData | ConvertTo-Json -Depth 10
    $body = [System.Text.Encoding]::UTF8.GetBytes($json)
    
    $method = "POST"
    $contentType = "application/json"
    $resource = "/api/logs"
    $rfc1123date = [DateTime]::UtcNow.ToString("r")
    $contentLength = $body.Length
    
    $xHeaders = "x-ms-date:" + $rfc1123date
    $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource
    
    $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($WorkspaceKey)
    $sha256 = New-Object System.Security.Cryptography.HMACSHA256
    $sha256.Key = $keyBytes
    $calculatedHash = $sha256.ComputeHash($bytesToHash)
    $encodedHash = [Convert]::ToBase64String($calculatedHash)
    $authorization = 'SharedKey {0}:{1}' -f $WorkspaceId,$encodedHash
    
    $uri = "https://" + $WorkspaceId + ".ods.opinsights.azure.com" + $resource + "?api-version=2016-04-01"
    
    $headers = @{
        "Authorization" = $authorization
        "Log-Type" = $LogType
        "x-ms-date" = $rfc1123date
    }
    
    try {
        $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $body -UseBasicParsing
        return $response.StatusCode
    }
    catch {
        Write-Error "Failed to send data to Log Analytics: $_"
        return $null
    }
}

# Email Function using Azure Communication Services REST API
function Send-AcsEmail {
    param(
        [string]$ConnectionString,
        [string]$From,
        [string]$To,
        [string]$Subject,
        [string]$HtmlContent
    )
    
    try {
        # Parse connection string
        $connStringParts = @{}
        ($ConnectionString -split ';') | ForEach-Object {
            if ($_ -match '(.+?)=(.+)') {
                $connStringParts[$matches[1]] = $matches[2]
            }
        }
        
        $endpoint = $connStringParts['endpoint'].TrimEnd('/')
        $accessKey = $connStringParts['accesskey']
        
        if (-not $endpoint -or -not $accessKey) {
            throw "Invalid connection string format"
        }
        
        Write-Output "Using ACS endpoint: $endpoint"
        
        # Prepare email message
        $emailMessage = @{
            senderAddress = $From
            content = @{
                subject = $Subject
                html = $HtmlContent
            }
            recipients = @{
                to = @(
                    @{
                        address = $To
                        displayName = $To
                    }
                )
            }
        }
        
        $body = $emailMessage | ConvertTo-Json -Depth 10 -Compress
        
        # API details
        $apiVersion = "2023-03-31"
        $uri = "$endpoint/emails:send?api-version=$apiVersion"
        
        # Generate HMAC signature for authentication
        $verb = "POST"
        $utcNow = [DateTime]::UtcNow.ToString("r")
        $contentHash = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($body))
        $contentHashBase64 = [Convert]::ToBase64String($contentHash)
        
        $pathAndQuery = "/emails:send?api-version=$apiVersion"
        $stringToSign = "$verb`n$pathAndQuery`n$utcNow;$($endpoint.Replace('https://', ''));$contentHashBase64"
        
        $hmac = New-Object System.Security.Cryptography.HMACSHA256
        $hmac.Key = [Convert]::FromBase64String($accessKey)
        $signature = [Convert]::ToBase64String($hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($stringToSign)))
        
        # Prepare headers
        $headers = @{
            "x-ms-date" = $utcNow
            "x-ms-content-sha256" = $contentHashBase64
            "Authorization" = "HMAC-SHA256 SignedHeaders=x-ms-date;host;x-ms-content-sha256&Signature=$signature"
            "Content-Type" = "application/json"
        }
        
        Write-Output "Sending email to: $To"
        
        # Make API call
        $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body -ContentType "application/json"
        
        Write-Output "Email sent successfully via Azure Communication Services"
        Write-Output "Message ID: $($response.id)"
        Write-Output "Status: $($response.status)"
        
        return $true
    }
    catch {
        Write-Error "Failed to send email via ACS: $_"
        if ($_.Exception.Response) {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $responseBody = $reader.ReadToEnd()
            Write-Error "Response: $responseBody"
        }
        return $false
    }
}

# Main Script
try {
    Write-Output "Starting Stale Device Cleanup Process..."
    Write-Output "Configuration: StaleDays=$StaleDays, WhatIf=$WhatIf"
    
    # Connect to Microsoft Graph using Managed Identity
    Connect-MgGraph -Identity -NoWelcome
    
    # Get all Autopilot registered devices for reference
    Write-Output "Retrieving Autopilot registered devices..."
    $autopilotDevices = @{}
    $autopilotCheckFailed = $false
    
    try {
        $autopilotRegistrations = Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -All
        Write-Output "Found $($autopilotRegistrations.Count) Autopilot registered devices"
        
        # Create a hashtable for quick lookup by Azure AD Device ID
        foreach ($ap in $autopilotRegistrations) {
            if ($ap.AzureActiveDirectoryDeviceId) {
                $autopilotDevices[$ap.AzureActiveDirectoryDeviceId] = @{
                    SerialNumber = $ap.SerialNumber
                    Model = $ap.Model
                }
            }
        }
    }
    catch {
        Write-Error "CRITICAL: Failed to retrieve Autopilot devices: $($_.Exception.Message)"
        Write-Error "Cannot safely proceed with deletions without Autopilot data."
        $autopilotCheckFailed = $true
    }
    
    # Calculate stale date threshold
    $staleDate = (Get-Date).AddDays(-$StaleDays)
    $staleDateISO = $staleDate.ToString("yyyy-MM-ddTHH:mm:ssZ")
    Write-Output "Identifying devices not synced since: $staleDate"
    
    # Get stale devices using Filter to only return devices in scope
    # Only includes devices WITH a sign-in date that's older than threshold
    Write-Output "Retrieving stale Entra ID devices using filter..."
    $filter = "approximateLastSignInDateTime le $staleDateISO"
    
    $staleDevices = Get-MgDevice -Filter $filter -All -Property Id,DisplayName,ApproximateLastSignInDateTime,OperatingSystem,TrustType,DeviceId
    
    Write-Output "Stale devices identified: $($staleDevices.Count)"
    
    # Check if critical services failed - abort if so
    if ($autopilotCheckFailed) {
        Write-Error "ABORTING: Cannot proceed without Autopilot data to prevent accidental deletion of Autopilot devices."
        throw "Critical service check failed: Autopilot retrieval"
    }
    
    # Process each stale device
    $devicesToDelete = @()
    $devicesSkipped = @()
    $deletionResults = @()
    $bitlockerCheckFailed = $false
    
    foreach ($device in $staleDevices) {
        $deviceInfo = @{
            DeviceId = $device.Id
            DisplayName = $device.DisplayName
            DeviceObjectId = $device.DeviceId
            LastSync = $device.ApproximateLastSignInDateTime
            OperatingSystem = $device.OperatingSystem
            TrustType = $device.TrustType
        }
        
        # Check if device is Autopilot registered
        if ($autopilotDevices.ContainsKey($device.DeviceId)) {
            $autopilotInfo = $autopilotDevices[$device.DeviceId]
            Write-Output "SKIPPED: $($device.DisplayName) - Registered in Autopilot (SN: $($autopilotInfo.SerialNumber))"
            $deviceInfo.Action = "Skipped"
            $deviceInfo.Reason = "Autopilot registered device"
            $deviceInfo.AutopilotSerialNumber = $autopilotInfo.SerialNumber
            $deviceInfo.AutopilotModel = $autopilotInfo.Model
            $devicesSkipped += $deviceInfo
            continue
        }
        
        # Check for BitLocker keys
        try {
            Write-Verbose "Checking BitLocker keys for device: $($device.DisplayName) (DeviceId: $($device.DeviceId))"
            
            $bitlockerKeys = $null
            
            try {
                $bitlockerKeys = Get-MgInformationProtectionBitlockerRecoveryKey -Filter "deviceId eq '$($device.DeviceId)'" -ErrorAction Stop
            }
            catch {
                Write-Error "BitLocker key check failed for $($device.DisplayName): $($_.Exception.Message)"
                
                # Check for specific critical errors
                if ($_.Exception.Message -like "*Forbidden*" -or $_.Exception.Message -like "*403*") {
                    Write-Error "CRITICAL: Permission denied checking BitLocker keys. Cannot proceed safely."
                    $bitlockerCheckFailed = $true
                    break
                }
                elseif ($_.Exception.Message -like "*Unauthorized*" -or $_.Exception.Message -like "*401*") {
                    Write-Error "CRITICAL: Authentication failed. Cannot proceed safely."
                    $bitlockerCheckFailed = $true
                    break
                }
                elseif ($_.Exception.Message -like "*NotFound*" -or $_.Exception.Message -like "*404*") {
                    # 404 is okay - means no BitLocker keys
                    Write-Output "No BitLocker keys found for $($device.DisplayName)"
                    $bitlockerKeys = @()
                }
                else {
                    # Other errors - skip this device but continue
                    Write-Warning "Skipping device due to BitLocker check error: $($_.Exception.Message)"
                    $deviceInfo.Action = "Error"
                    $deviceInfo.Reason = "BitLocker check failed"
                    $deviceInfo.Error = $_.Exception.Message
                    $devicesSkipped += $deviceInfo
                    continue
                }
            }
            
            # Process based on BitLocker key presence
            if ($bitlockerKeys -and $bitlockerKeys.Count -gt 0) {
                Write-Output "SKIPPED: $($device.DisplayName) - Has $($bitlockerKeys.Count) BitLocker key(s) escrowed"
                $deviceInfo.Action = "Skipped"
                $deviceInfo.Reason = "BitLocker keys present"
                $deviceInfo.BitLockerKeyCount = $bitlockerKeys.Count
                $devicesSkipped += $deviceInfo
            }
            else {
                Write-Output "CANDIDATE: $($device.DisplayName) - No BitLocker keys found"
                $deviceInfo.Action = "Candidate for deletion"
                $deviceInfo.Reason = "No BitLocker keys"
                $deviceInfo.BitLockerKeyCount = 0
                $devicesToDelete += $deviceInfo
                
                # Delete the device if not in WhatIf mode
                if (-not $WhatIf) {
                    try {
                        Remove-MgDevice -DeviceId $device.Id -ErrorAction Stop
                        Write-Output "DELETED: $($device.DisplayName)"
                        $deviceInfo.Action = "Deleted"
                        $deviceInfo.Status = "Success"
                    }
                    catch {
                        Write-Error "Failed to delete $($device.DisplayName): $($_.Exception.Message)"
                        $deviceInfo.Action = "Delete Failed"
                        $deviceInfo.Status = "Failed"
                        $deviceInfo.Error = $_.Exception.Message
                    }
                }
                else {
                    $deviceInfo.Action = "Would Delete (WhatIf)"
                    $deviceInfo.Status = "WhatIf Mode"
                }
                
                $deletionResults += $deviceInfo
            }
        }
        catch {
            Write-Error "Unexpected error processing device $($device.DisplayName): $($_.Exception.Message)"
            $deviceInfo.Action = "Error"
            $deviceInfo.Reason = "Unexpected processing error"
            $deviceInfo.Error = $_.Exception.Message
            $devicesSkipped += $deviceInfo
        }
    }
    
    # Check if BitLocker check failed during processing
    if ($bitlockerCheckFailed) {
        Write-Error "ABORTING: BitLocker key checks failed. Cannot safely proceed with deletions."
        throw "Critical service check failed: BitLocker key retrieval"
    }
    
    # Prepare summary
    $summary = @{
        RunDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        StaleDaysThreshold = $StaleDays
        WhatIfMode = $WhatIf
        StaleDevices = $staleDevices.Count
        AutopilotDevicesSkipped = ($devicesSkipped | Where-Object {$_.Reason -eq "Autopilot registered device"}).Count
        DevicesWithBitLocker = ($devicesSkipped | Where-Object {$_.Reason -eq "BitLocker keys present"}).Count
        DevicesDeleted = ($deletionResults | Where-Object {$_.Action -eq "Deleted"}).Count
        DevicesCandidates = $devicesToDelete.Count
        DeleteFailures = ($deletionResults | Where-Object {$_.Action -eq "Delete Failed"}).Count
        BitLockerCheckErrors = ($devicesSkipped | Where-Object {$_.Action -like "Error*"}).Count
    }
    
    Write-Output "`nSummary:"
    Write-Output "Stale Devices: $($summary.StaleDevices)"
    Write-Output "Autopilot Devices (Skipped): $($summary.AutopilotDevicesSkipped)"
    Write-Output "Devices with BitLocker (Skipped): $($summary.DevicesWithBitLocker)"
    Write-Output "Devices Deleted: $($summary.DevicesDeleted)"
    Write-Output "Delete Failures: $($summary.DeleteFailures)"
    Write-Output "BitLocker Check Errors: $($summary.BitLockerCheckErrors)"
    
    # Send to Log Analytics
    if ($WorkspaceId -and $WorkspaceKey) {
        Write-Output "`nSending logs to Log Analytics..."
        
        # Send summary
        Send-LogAnalyticsData -WorkspaceId $WorkspaceId -WorkspaceKey $WorkspaceKey `
            -LogType "EntraDeviceCleanup_Summary" -LogData $summary
        
        # Send deletion details
        if ($deletionResults.Count -gt 0) {
            Send-LogAnalyticsData -WorkspaceId $WorkspaceId -WorkspaceKey $WorkspaceKey `
                -LogType "EntraDeviceCleanup_Deletions" -LogData $deletionResults
        }
        
        # Send skipped devices
        if ($devicesSkipped.Count -gt 0) {
            Send-LogAnalyticsData -WorkspaceId $WorkspaceId -WorkspaceKey $WorkspaceKey `
                -LogType "EntraDeviceCleanup_Skipped" -LogData $devicesSkipped
        }
    }
    
    # Generate and send email report via Azure Communication Services
    if ($AcsConnectionString -and $SenderEmail -and $RecipientEmail) {
        Write-Output "`nGenerating email report..."
        
        $htmlReport = @"
<!DOCTYPE html>
<html>
<head>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        h1 { color: #0078D4; }
        h2 { color: #106EBE; margin-top: 30px; }
        table { border-collapse: collapse; width: 100%; margin-top: 15px; }
        th { background-color: #0078D4; color: white; padding: 12px; text-align: left; }
        td { border: 1px solid #ddd; padding: 10px; }
        tr:nth-child(even) { background-color: #f2f2f2; }
        .summary { background-color: #E3F2FD; padding: 15px; border-radius: 5px; margin: 20px 0; }
        .warning { color: #D32F2F; font-weight: bold; }
        .success { color: #388E3C; font-weight: bold; }
    </style>
</head>
<body>
    <h1>Entra ID Stale Device Cleanup Report</h1>
    <p><strong>Run Date:</strong> $($summary.RunDate)</p>
    <p><strong>Mode:</strong> $(if($WhatIf){"<span class='warning'>WhatIf (No deletions performed)</span>"}else{"<span class='success'>Live Deletion Mode</span>"})</p>
    
    <div class="summary">
        <h2>Summary</h2>
        <table>
            <tr><td><strong>Stale Devices (>$StaleDays days)</strong></td><td>$($summary.StaleDevices)</td></tr>
            <tr><td><strong>Autopilot Devices (Skipped)</strong></td><td>$($summary.AutopilotDevicesSkipped)</td></tr>
            <tr><td><strong>Devices with BitLocker (Skipped)</strong></td><td>$($summary.DevicesWithBitLocker)</td></tr>
            <tr><td><strong>Devices Deleted</strong></td><td class="success">$($summary.DevicesDeleted)</td></tr>
            <tr><td><strong>Delete Failures</strong></td><td class="warning">$($summary.DeleteFailures)</td></tr>
            <tr><td><strong>BitLocker Check Errors</strong></td><td class="warning">$($summary.BitLockerCheckErrors)</td></tr>
        </table>
    </div>
    
    <h2>Devices Processed for Deletion</h2>
    <table>
        <tr>
            <th>Display Name</th>
            <th>Operating System</th>
            <th>Last Sync</th>
            <th>Action</th>
            <th>Status</th>
        </tr>
"@
        
        foreach ($device in $deletionResults) {
            $lastSync = if ($device.LastSync) { $device.LastSync.ToString("yyyy-MM-dd") } else { "Never" }
            $htmlReport += @"
        <tr>
            <td>$($device.DisplayName)</td>
            <td>$($device.OperatingSystem)</td>
            <td>$lastSync</td>
            <td>$($device.Action)</td>
            <td>$($device.Status)</td>
        </tr>
"@
        }
        
        $htmlReport += @"
    </table>
    
    <h2>Devices Skipped</h2>
    <p><em>These devices were skipped for various reasons (Autopilot registration, BitLocker keys, or errors).</em></p>
    <table>
        <tr>
            <th>Display Name</th>
            <th>Operating System</th>
            <th>Last Sync</th>
            <th>Reason</th>
            <th>Details</th>
        </tr>
"@
        
        foreach ($device in $devicesSkipped) {
            $lastSync = if ($device.LastSync) { $device.LastSync.ToString("yyyy-MM-dd") } else { "Never" }
            $details = ""
            
            if ($device.Reason -eq "Autopilot registered device") {
                $details = "SN: $($device.AutopilotSerialNumber)"
            }
            elseif ($device.Reason -eq "BitLocker keys present") {
                $details = "$($device.BitLockerKeyCount) key(s)"
            }
            elseif ($device.Error) {
                $details = "<span class='warning'>$($device.Error)</span>"
            }
            
            $htmlReport += @"
        <tr>
            <td>$($device.DisplayName)</td>
            <td>$($device.OperatingSystem)</td>
            <td>$lastSync</td>
            <td>$($device.Reason)</td>
            <td>$details</td>
        </tr>
"@
        }
        
        $htmlReport += @"
    </table>
    <br>
    <p style="color: #666; font-size: 12px;">This email was sent via Azure Communication Services</p>
</body>
</html>
"@
        
        $emailSubject = if ($WhatIf) {
            "Entra ID Device Cleanup Report (WhatIf Mode) - $($summary.RunDate)"
        } else {
            "Entra ID Device Cleanup Report - $($summary.DevicesDeleted) Devices Deleted"
        }
        
        $emailSent = Send-AcsEmail -ConnectionString $AcsConnectionString -From $SenderEmail -To $RecipientEmail `
            -Subject $emailSubject -HtmlContent $htmlReport
        
        if (-not $emailSent) {
            Write-Warning "Email delivery may have failed. Check ACS logs for details."
        }
    }
    
    Write-Output "`nScript completed successfully!"
}
catch {
    Write-Error "Script failed with error: $_"
    throw
}
finally {
    # Disconnect from Microsoft Graph
    Disconnect-MgGraph | Out-Null
}
