# Complete Setup Guide: Entra ID Stale Device Cleanup Automation

This guide walks you through setting up an automated Azure runbook that deletes stale Entra ID devices (without BitLocker keys or Autopilot registration) and sends comprehensive reports via email and Log Analytics.

---

## Table of Contents
1. [Prerequisites](#prerequisites)
2. [Step 1: Create Log Analytics Workspace](#step-1-create-log-analytics-workspace)
3. [Step 2: Set Up Azure Communication Services for Email](#step-2-set-up-azure-communication-services-for-email)
4. [Step 3: Create Azure Automation Account](#step-3-create-azure-automation-account)
5. [Step 4: Configure Managed Identity](#step-4-configure-managed-identity)
6. [Step 5: Install PowerShell Modules](#step-5-install-powershell-modules)
7. [Step 6: Create Automation Variables](#step-6-create-automation-variables)
8. [Step 7: Create the Runbook](#step-7-create-the-runbook)
9. [Step 8: Test the Runbook](#step-8-test-the-runbook)
10. [Step 9: Schedule the Runbook](#step-9-schedule-the-runbook)
11. [Step 10: Create Log Analytics Queries & Alerts](#step-10-create-log-analytics-queries--alerts)
12. [Troubleshooting](#troubleshooting)

---

## Prerequisites

- **Azure Subscription** with appropriate permissions
- **Global Administrator** or **Privileged Role Administrator** access in Entra ID
- **Contributor** access to Azure subscription for creating resources
- **Intune licensing** (for Autopilot device checking)
- **Estimated time:** 60-75 minutes

---

## Step 1: Create Log Analytics Workspace

### 1.1 Create Workspace via Azure Portal

1. Navigate to [Azure Portal](https://portal.azure.com)
2. Search for **"Log Analytics workspaces"** and click **Create**
3. Fill in the details:
   - **Subscription:** Select your subscription
   - **Resource Group:** Create new or use existing (e.g., `rg-automation`)
   - **Name:** `law-entra-device-cleanup`
   - **Region:** Select your preferred region
4. Click **Review + Create**, then **Create**

### 1.2 Get Workspace ID and Key via PowerShell

Since the Azure Portal interface has changed, use PowerShell to retrieve the keys:

```powershell
# Connect to Azure
Connect-AzAccount

# Set your resource group and workspace name
$resourceGroup = "rg-automation"
$workspaceName = "law-entra-device-cleanup"

# Get Workspace ID
$workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $resourceGroup -Name $workspaceName
Write-Host "Workspace ID: $($workspace.CustomerId)" -ForegroundColor Green

# Get Primary Key
$keys = Get-AzOperationalInsightsWorkspaceSharedKeys -ResourceGroupName $resourceGroup -Name $workspaceName
Write-Host "Primary Key: $($keys.PrimarySharedKey)" -ForegroundColor Green
```

> 💡 **Note:** Save these values securely - you'll need them in Step 6

---

## Step 2: Set Up Azure Communication Services for Email

### 2.1 Create Email Communication Services Resource

1. Go to [Azure Portal](https://portal.azure.com)
2. Search for **"Email Communication Services"**
3. Click **+ Create**
4. Fill in details:
   - **Subscription:** Your subscription
   - **Resource Group:** `rg-automation` (same as your other resources)
   - **Name:** `email-device-cleanup`
   - **Region:** Select your preferred region (e.g., United States)
   - **Data location:** United States (or your region)
5. Click **Review + Create**, then **Create**

### 2.2 Set Up Email Domain

You have two options: **Azure Managed Domain** (quick) or **Custom Domain** (professional).

#### Option A: Azure Managed Domain (Recommended for Quick Setup)

This is fastest - no DNS configuration needed!

1. Open your Email Communication Services resource
2. Go to **Provision** → **Domains**
3. Click **+ Add domain**
4. Select **Azure subdomain** (free)
5. Click **Add**
6. Azure will create a domain like: `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx.azurecomm.net`
7. Wait ~2 minutes for provisioning
8. Once **Status** shows **Verified**, you're ready!

**Your sender email will be:** `DoNotReply@xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx.azurecomm.net`

#### Option B: Custom Domain (Professional - Optional)

Use your own domain like `noreply@contoso.com`:

1. Go to **Provision** → **Domains**
2. Click **+ Add domain**
3. Select **Custom domain**
4. Enter your domain: `contoso.com`
5. Azure will show required DNS records:
   - **TXT record** for domain ownership verification
   - **SPF record** (TXT) for sender authentication
   - **DKIM records** (2 CNAME records) for email signing
6. Add these records to your DNS provider
7. Click **Verify** once DNS propagates (can take up to 24 hours)
8. Once verified, configure your sender email: `noreply@contoso.com`

### 2.3 Create Communication Services Resource

1. Search for **"Communication Services"** in Azure Portal
2. Click **+ Create**
3. Fill in details:
   - **Subscription:** Your subscription
   - **Resource Group:** `rg-automation`
   - **Name:** `acs-device-cleanup`
   - **Data location:** Same as Email resource
4. Click **Review + Create**, then **Create**

### 2.4 Link Email Domain to Communication Services

1. Open your **Communication Services** resource (`acs-device-cleanup`)
2. Go to **Email** → **Domains**
3. Click **Connect domain**
4. Select your **Email Communication Services** resource
5. Select your **domain** (Azure managed or custom)
6. Click **Connect**

### 2.5 Get Connection String

1. In your Communication Services resource
2. Go to **Settings** → **Keys**
3. You'll see:
   - **Connection string** (Primary and Secondary)
   - **Endpoint**
4. **Copy the Primary connection string** - looks like:
   ```
   endpoint=https://acs-device-cleanup.communication.azure.com/;accesskey=XXXXXXXXXXXXX
   ```

### 2.6 Note Your Sender Email

Depending on your domain choice:
- **Azure Managed:** `DoNotReply@xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx.azurecomm.net`
- **Custom Domain:** `noreply@yourdomain.com`

> 💡 **Save both the connection string and sender email** - you'll need them in Step 6

---

## Step 3: Create Azure Automation Account

### 3.1 Create Automation Account

1. In Azure Portal, search for **"Automation Accounts"**
2. Click **Create**
3. Fill in details:
   - **Subscription:** Your subscription
   - **Resource Group:** `rg-automation` (same as Log Analytics)
   - **Name:** `aa-entra-device-cleanup`
   - **Region:** Same as Log Analytics workspace
4. Click **Review + Create**, then **Create**

### 3.2 Enable System-Assigned Managed Identity

1. Open your Automation Account
2. Go to **Account Settings** → **Identity**
3. Under **System assigned** tab:
   - Toggle **Status** to **On**
   - Click **Save**
   - Click **Yes** to confirm
4. Note the **Object (principal) ID** that appears

---

## Step 4: Configure Managed Identity Permissions

### 4.1 Grant Microsoft Graph API Permissions

We need to grant permissions via PowerShell (can't be done in portal for Managed Identity):

```powershell
# Connect to Microsoft Graph
Connect-MgGraph -Scopes "Application.Read.All","AppRoleAssignment.ReadWrite.All"

# Get the Managed Identity Service Principal
$managedIdentityObjectId = "YOUR-MANAGED-IDENTITY-OBJECT-ID"  # From Step 3.2
$managedIdentitySP = Get-MgServicePrincipal -ServicePrincipalId $managedIdentityObjectId

# Get Microsoft Graph Service Principal
$graphSP = Get-MgServicePrincipal -Filter "displayName eq 'Microsoft Graph'"

# Define required permissions
$permissions = @(
    "Device.Read.All",                          # Read device information
    "Device.ReadWrite.All",                     # Delete devices
    "BitlockerKey.Read.All",                    # Read BitLocker keys
    "DeviceManagementServiceConfig.Read.All"    # Read Autopilot devices
)

# Grant each permission
foreach ($permission in $permissions) {
    $appRole = $graphSP.AppRoles | Where-Object { $_.Value -eq $permission }
    
    $body = @{
        principalId = $managedIdentitySP.Id
        resourceId  = $graphSP.Id
        appRoleId   = $appRole.Id
    }
    
    New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $managedIdentitySP.Id -BodyParameter $body
    Write-Host "Granted: $permission" -ForegroundColor Green
}

Write-Host "`nAll permissions granted successfully!" -ForegroundColor Green
```

### 4.2 Verify Permissions

1. Go to **Entra ID** → **Enterprise Applications**
2. Change filter to **Application type: Managed Identities**
3. Find your Automation Account name
4. Go to **Permissions** → verify the 4 permissions are listed

---

## Step 5: Install PowerShell Modules

### 5.1 Install Required Modules

1. In your Automation Account, go to **Shared Resources** → **Modules**
2. Click **+ Add a module**
3. Select **Browse from gallery**

Install these modules **in order** (wait for each to complete):

#### Module 1: Microsoft.Graph.Authentication
1. Search for `Microsoft.Graph.Authentication`
2. Select version **2.0.0 or higher**
3. Click **Import** and wait (~5-10 minutes)

#### Module 2: Microsoft.Graph.Identity.DirectoryManagement
1. Click **+ Add a module** again
2. Search for `Microsoft.Graph.Identity.DirectoryManagement`
3. Select version **2.0.0 or higher**
4. Click **Import** and wait

#### Module 3: Microsoft.Graph.Users.Actions
1. Click **+ Add a module** again
2. Search for `Microsoft.Graph.Users.Actions`
3. Select version **2.0.0 or higher**
4. Click **Import** and wait

#### Module 4: Microsoft.Graph.DeviceManagement.Enrollment
1. Click **+ Add a module** again
2. Search for `Microsoft.Graph.DeviceManagement.Enrollment`
3. Select version **2.0.0 or higher**
4. Click **Import** and wait

### 5.2 Verify Installation

1. Go to **Modules** → **Browse Gallery**
2. Each module should show **Status: Available**
3. This may take 20-30 minutes total

---

## Step 6: Create Automation Variables

### 6.1 Create Encrypted Variables

1. In Automation Account, go to **Shared Resources** → **Variables**
2. Click **+ Add a variable** for each of the following:

#### Variable 1: LogAnalyticsWorkspaceId
- **Name:** `LogAnalyticsWorkspaceId`
- **Type:** String
- **Value:** Your Workspace ID from Step 1.2
- **Encrypted:** ✅ Yes
- Click **Create**

#### Variable 2: LogAnalyticsWorkspaceKey
- **Name:** `LogAnalyticsWorkspaceKey`
- **Type:** String
- **Value:** Your Primary Key from Step 1.2
- **Encrypted:** ✅ Yes
- Click **Create**

#### Variable 3: AcsConnectionString
- **Name:** `AcsConnectionString`
- **Type:** String
- **Value:** Your connection string from Step 2.5
- **Encrypted:** ✅ Yes
- Click **Create**

#### Variable 4: SenderEmail
- **Name:** `SenderEmail`
- **Type:** String
- **Value:** Your sender email from Step 2.6
- **Encrypted:** ❌ No (or Yes if preferred)
- Click **Create**

### 6.2 Verify Variables

You should now have 4 variables listed in the Variables blade.

---

## Step 7: Create the Runbook

### 7.1 Create New Runbook

1. In Automation Account, go to **Process Automation** → **Runbooks**
2. Click **+ Create a runbook**
3. Settings:
   - **Name:** `Remove-StaleEntraDevices`
   - **Runbook type:** PowerShell
   - **Runtime version:** 7.2
   - **Description:** Removes stale Entra ID devices without BitLocker keys or Autopilot registration
4. Click **Create**

### 7.2 Add Runbook Code

1. The runbook editor will open
2. **Copy the entire PowerShell script** from the artifact
3. **Paste it** into the editor
4. Click **Save**

### 7.3 Publish the Runbook

1. Click **Publish**
2. Click **Yes** to confirm

---

## Step 8: Test the Runbook

### 8.1 First Test Run (WhatIf Mode)

1. In the runbook, click **Start**
2. Configure parameters:
   - **STALEDAYS:** `180` (or your preferred threshold)
   - **RECIPIENTEMAIL:** Your email address
   - **WHATIF:** `True` (important for first test!)
3. Click **OK**

### 8.2 Monitor the Job

1. The job page will open automatically
2. Click **Output** to see real-time logs
3. Wait for completion (may take 5-15 minutes depending on device count)

### 8.3 Verify Results

**Check Output Logs:**
- Look for "Stale devices identified: X"
- Verify Autopilot devices are being skipped
- Check "CANDIDATE" and "SKIPPED" entries
- Review summary at the end

**Check Email:**
- You should receive an HTML report
- Review devices that would be deleted
- Check devices skipped due to BitLocker keys
- Check devices skipped due to Autopilot registration

**Check Log Analytics:**
1. Go to your Log Analytics workspace
2. Click **Logs**
3. Run this query:
```kusto
EntraDeviceCleanup_Summary_CL
| order by TimeGenerated desc
| take 10
```
4. You should see your test run data

### 8.4 Production Test (Optional)

If the WhatIf results look correct:

1. Click **Start** again
2. Set **WHATIF:** `False`
3. Monitor carefully - this will actually delete devices!

---

## Step 9: Schedule the Runbook

### 9.1 Create Schedule

1. In your runbook, go to **Resources** → **Schedules**
2. Click **+ Add a schedule**
3. Click **Link a schedule to your runbook**
4. Click **+ Add a schedule**

### 9.2 Configure Schedule

**Recommended: Weekly Schedule**
- **Name:** `Weekly-Device-Cleanup`
- **Description:** Weekly cleanup of stale devices
- **Starts:** Select a date/time (e.g., Sunday 2:00 AM)
- **Timezone:** Your timezone
- **Recurrence:** Recurring
- **Recur every:** 1 Week
- **On these days:** Sunday (or your preferred day)
- **Expiration:** No end date

Click **Create**

### 9.3 Configure Parameters

After creating the schedule, set parameters:
- **STALEDAYS:** `180`
- **RECIPIENTEMAIL:** Your email or distribution list
- **WHATIF:** `False` (for production) or `True` (for ongoing testing)

Click **OK**

### 9.4 Alternative: Monthly Schedule

For less frequent cleanup:
- **Recur every:** 1 Month
- **On day:** First Sunday (or specific day)

---

## Step 10: Create Log Analytics Queries & Alerts

### 10.1 Useful KQL Queries

Navigate to your Log Analytics workspace → **Logs** and save these queries:

#### Query 1: Recent Deletions Summary
```kusto
EntraDeviceCleanup_Summary_CL
| where TimeGenerated > ago(90d)
| project 
    TimeGenerated,
    StaleDevices_d,
    AutopilotDevicesSkipped_d,
    DevicesWithBitLocker_d,
    DevicesDeleted_d,
    DeleteFailures_d,
    WhatIfMode_b
| sort by TimeGenerated desc
```

#### Query 2: All Deleted Devices
```kusto
EntraDeviceCleanup_Deletions_CL
| where TimeGenerated > ago(30d)
| where Action_s == "Deleted"
| project 
    TimeGenerated,
    DisplayName_s,
    OperatingSystem_s,
    LastSync_t,
    Status_s
| sort by TimeGenerated desc
```

#### Query 3: Devices Skipped (Autopilot & BitLocker)
```kusto
EntraDeviceCleanup_Skipped_CL
| where TimeGenerated > ago(30d)
| project 
    TimeGenerated,
    DisplayName_s,
    OperatingSystem_s,
    Reason_s,
    BitLockerKeyCount_d,
    AutopilotSerialNumber_s
| sort by TimeGenerated desc
```

#### Query 4: Deletion Trends
```kusto
EntraDeviceCleanup_Summary_CL
| where TimeGenerated > ago(90d)
| summarize 
    TotalDeleted = sum(DevicesDeleted_d),
    AvgDeleted = avg(DevicesDeleted_d),
    AutopilotSkipped = sum(AutopilotDevicesSkipped_d),
    BitLockerSkipped = sum(DevicesWithBitLocker_d)
    by bin(TimeGenerated, 7d)
| render timechart
```

#### Query 5: Failed Deletions
```kusto
EntraDeviceCleanup_Deletions_CL
| where Action_s == "Delete Failed"
| project 
    TimeGenerated,
    DisplayName_s,
    Error_s
| sort by TimeGenerated desc
```

#### Query 6: Autopilot Protection Effectiveness
```kusto
EntraDeviceCleanup_Summary_CL
| where TimeGenerated > ago(30d)
| project 
    TimeGenerated,
    AutopilotDevicesSkipped_d,
    StaleDevices_d,
    ProtectionRate = (AutopilotDevicesSkipped_d * 100.0) / StaleDevices_d
| sort by TimeGenerated desc
```

### 10.2 Create Alert Rule

Create an alert if too many devices are deleted in one run:

1. In Log Analytics, click **Alerts** → **+ Create** → **Alert rule**
2. **Scope:** Your Log Analytics workspace (already selected)
3. **Condition:**
   - Click **Add condition**
   - **Signal:** Custom log search
   - **Search query:**
   ```kusto
   EntraDeviceCleanup_Summary_CL
   | where DevicesDeleted_d > 100
   | project DevicesDeleted_d, TimeGenerated
   ```
   - **Alert logic:**
     - **Threshold:** Static
     - **Operator:** Greater than
     - **Threshold value:** 0
     - **Check every:** 1 day
     - **Lookback period:** 1 day
4. **Actions:**
   - Create action group to send email/SMS
   - **Name:** `AG-DeviceCleanup-HighCount`
5. **Alert rule details:**
   - **Name:** `High Device Deletion Count`
   - **Severity:** Warning (Sev 2)
6. Click **Create alert rule**

### 10.3 Create Dashboard (Optional)

1. Go to Log Analytics workspace
2. Click **Workbooks** → **+ New**
3. Add visualizations:
   - **Summary stats** (Total devices deleted, avg per run)
   - **Time chart** (Deletion trends)
   - **Table** (Recent deletions)
   - **Pie chart** (Skip reasons: Autopilot vs BitLocker)
4. Save the workbook as "Device Cleanup Dashboard"

---

## Troubleshooting

### Issue: "Connect-MgGraph : The term 'Connect-MgGraph' is not recognized"

**Solution:** Modules not installed or still importing
- Wait for all modules to finish installing
- Check module status in **Modules** blade
- Verify runtime version is 7.2

### Issue: "Insufficient privileges to complete the operation"

**Solution:** Managed Identity permissions not granted
- Re-run the PowerShell script from Step 4.1
- Verify permissions in Entra ID → Enterprise Applications
- Wait 10-15 minutes for permissions to propagate

### Issue: "Failed to retrieve Autopilot devices"

**Solution:** Missing permission or no Intune license
- Verify DeviceManagementServiceConfig.Read.All permission is granted
- Ensure tenant has Intune licensing
- Check if Autopilot is enabled in your environment
- **Important:** Script will abort if this fails to prevent accidental Autopilot device deletion

### Issue: "Permission denied checking BitLocker keys"

**Solution:** Missing BitLocker permission
- Verify BitlockerKey.Read.All permission is granted
- **Important:** Script will abort if this fails to prevent accidental deletion of devices with BitLocker keys

### Issue: "Failed to send data to Log Analytics"

**Solution:** Check Workspace ID and Key
- Verify variables are correct
- Ensure variables are marked as encrypted
- Test the workspace key is still valid
- Use PowerShell to regenerate keys if needed

### Issue: "Failed to send email via ACS"

**Solution:** Azure Communication Services configuration issue
- Verify connection string is correct
- Ensure sender email matches verified domain
- Check ACS resource is properly linked to email domain
- Verify email domain status is "Verified"

### Issue: No devices found

**Solution:** Filter date format or permissions
- Check the date filter format (ISO 8601)
- Verify Device.Read.All permission is granted
- Try running in Azure Cloud Shell to test Graph API directly

### Issue: Email not delivered

**Solution:** Check domain verification and limits
- Verify sender email matches domain type (Azure managed vs custom)
- Check ACS sending limits (sandbox: 100/hour)
- Review ACS Insights for delivery status
- Check recipient spam folder

---

## Testing Checklist

Before running in production, verify:

- ✅ Test run completed successfully in WhatIf mode
- ✅ Email report received and looks correct
- ✅ Log Analytics data visible in workspace
- ✅ Autopilot devices are correctly skipped
- ✅ Devices with BitLocker keys are correctly skipped
- ✅ Only expected stale devices are targeted
- ✅ Schedule is configured for appropriate time
- ✅ Alert rules are working
- ✅ Stakeholders are informed of automation

---

## Maintenance

### Monthly Tasks
- Review deletion reports and trends
- Check for failed deletions
- Verify alert rules are functioning
- Review Log Analytics retention costs
- Verify Autopilot and BitLocker checks are working

### Quarterly Tasks
- Review stale day threshold (adjust if needed)
- Update recipient email lists
- Review BitLocker key escrow policy
- Audit deleted device logs
- Review Autopilot device skipping effectiveness

### Annual Tasks
- Review and update permissions
- Rotate ACS connection string
- Rotate Log Analytics workspace key
- Review automation account costs
- Update documentation

---

## Cost Estimate

**Log Analytics:**
- Ingestion: ~1-5 MB per run = $0.01-0.05/month
- Retention (90 days): Minimal

**Azure Communication Services:**
- ~4 emails/month (weekly) = ~$0.005/month
- Essentially free for this use case

**Azure Automation:**
- First 500 minutes free per month
- Typical job: 5-15 minutes
- Cost: Free (for weekly schedule)

**Total estimated cost: $0-5/month**

---

## Security Best Practices

1. ✅ Use encrypted variables for all secrets
2. ✅ Managed Identity instead of service principals
3. ✅ Principle of least privilege for Graph API permissions
4. ✅ Always test in WhatIf mode first
5. ✅ Regular review of deletion logs
6. ✅ Alert on anomalous deletion counts
7. ✅ Document all configuration changes
8. ✅ Backup critical device data before automation
9. ✅ Script aborts if Autopilot or BitLocker checks fail
10. ✅ Monitor ACS email delivery status

---

## Support & Resources

- **Microsoft Graph API Docs:** https://learn.microsoft.com/graph/
- **Azure Automation Docs:** https://learn.microsoft.com/azure/automation/
- **Azure Communication Services Docs:** https://learn.microsoft.com/azure/communication-services/
- **Log Analytics KQL:** https://learn.microsoft.com/azure/data-explorer/kusto/
- **Windows Autopilot Docs:** https://learn.microsoft.com/autopilot/

---

## Next Steps

After successful implementation:
1. Monitor first few runs closely
2. Fine-tune stale day threshold based on results
3. Create additional custom queries for your needs
4. Consider expanding to other device management tasks
5. Document your specific configuration for team
6. Set up additional alerting for critical failures

---

**Setup Complete! 🎉**

Your automated stale device cleanup is now running with:
- ✅ Autopilot device protection
- ✅ BitLocker key protection
- ✅ Azure Communication Services email reports
- ✅ Log Analytics monitoring
- ✅ Safe abort on critical failures

---

## Step 1: Create Log Analytics Workspace

### 1.1 Create Workspace via Azure Portal

1. Navigate to [Azure Portal](https://portal.azure.com)
2. Search for **"Log Analytics workspaces"** and click **Create**
3. Fill in the details:
   - **Subscription:** Select your subscription
   - **Resource Group:** Create new or use existing (e.g., `rg-automation`)
   - **Name:** `law-entra-device-cleanup`
   - **Region:** Select your preferred region
4. Click **Review + Create**, then **Create**

### 1.2 Get Workspace ID and Key

1. Once created, open the Log Analytics workspace
2. Go to **Settings** → **Agents**
3. Copy and save:
   - **Workspace ID** (e.g., `12345678-1234-1234-1234-123456789abc`)
   - **Primary Key** (long base64 string)

> 💡 **Note:** Keep these values secure - you'll need them in Step 6

---

## Step 2: Set Up SendGrid for Email

### 2.1 Create SendGrid Account

1. Go to [SendGrid](https://sendgrid.com/) or create via Azure Marketplace
2. Sign up for a **free account** (100 emails/day free)
3. Complete email verification

### 2.2 Create API Key

1. Log into SendGrid dashboard
2. Go to **Settings** → **API Keys**
3. Click **Create API Key**
4. Settings:
   - **Name:** `Azure-Device-Cleanup`
   - **Permissions:** Select **Full Access** or **Mail Send** only
5. Click **Create & View**
6. **Copy the API key** (you can only see it once!)

### 2.3 Verify Sender Email

1. Go to **Settings** → **Sender Authentication**
2. Click **Verify a Single Sender**
3. Enter your email address and complete verification
4. Save this **verified sender email** for Step 6

---

## Step 3: Create Azure Automation Account

### 3.1 Create Automation Account

1. In Azure Portal, search for **"Automation Accounts"**
2. Click **Create**
3. Fill in details:
   - **Subscription:** Your subscription
   - **Resource Group:** `rg-automation` (same as Log Analytics)
   - **Name:** `aa-entra-device-cleanup`
   - **Region:** Same as Log Analytics workspace
4. Click **Review + Create**, then **Create**

### 3.2 Enable System-Assigned Managed Identity

1. Open your Automation Account
2. Go to **Account Settings** → **Identity**
3. Under **System assigned** tab:
   - Toggle **Status** to **On**
   - Click **Save**
   - Click **Yes** to confirm
4. Note the **Object (principal) ID** that appears

---

## Step 4: Configure Managed Identity Permissions

### 4.1 Grant Microsoft Graph API Permissions

We need to grant permissions via PowerShell (can't be done in portal for Managed Identity):

```powershell
# Connect to Microsoft Graph
Connect-MgGraph -Scopes "Application.Read.All","AppRoleAssignment.ReadWrite.All"

# Get the Managed Identity Service Principal
$managedIdentityObjectId = "YOUR-MANAGED-IDENTITY-OBJECT-ID"  # From Step 3.2
$managedIdentitySP = Get-MgServicePrincipal -ServicePrincipalId $managedIdentityObjectId

# Get Microsoft Graph Service Principal
$graphSP = Get-MgServicePrincipal -Filter "displayName eq 'Microsoft Graph'"

# Define required permissions
$permissions = @(
    "Device.Read.All",           # Read device information
    "Device.ReadWrite.All",      # Delete devices
    "BitlockerKey.Read.All"      # Read BitLocker keys
)

# Grant each permission
foreach ($permission in $permissions) {
    $appRole = $graphSP.AppRoles | Where-Object { $_.Value -eq $permission }
    
    $body = @{
        principalId = $managedIdentitySP.Id
        resourceId  = $graphSP.Id
        appRoleId   = $appRole.Id
    }
    
    New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $managedIdentitySP.Id -BodyParameter $body
    Write-Host "Granted: $permission" -ForegroundColor Green
}

Write-Host "`nAll permissions granted successfully!" -ForegroundColor Green
```

### 4.2 Verify Permissions

1. Go to **Entra ID** → **Enterprise Applications**
2. Change filter to **Application type: Managed Identities**
3. Find your Automation Account name
4. Go to **Permissions** → verify the 3 permissions are listed

---

## Step 5: Install PowerShell Modules

### 5.1 Install Required Modules

1. In your Automation Account, go to **Shared Resources** → **Modules**
2. Click **+ Add a module**
3. Select **Browse from gallery**

Install these modules **in order** (wait for each to complete):

#### Module 1: Microsoft.Graph.Authentication
1. Search for `Microsoft.Graph.Authentication`
2. Select version **2.0.0 or higher**
3. Click **Import** and wait (~5-10 minutes)

#### Module 2: Microsoft.Graph.Identity.DirectoryManagement
1. Click **+ Add a module** again
2. Search for `Microsoft.Graph.Identity.DirectoryManagement`
3. Select version **2.0.0 or higher**
4. Click **Import** and wait

#### Module 3: Microsoft.Graph.Users.Actions
1. Click **+ Add a module** again
2. Search for `Microsoft.Graph.Users.Actions`
3. Select version **2.0.0 or higher**
4. Click **Import** and wait

### 5.2 Verify Installation

1. Go to **Modules** → **Browse Gallery**
2. Each module should show **Status: Available**
3. This may take 15-20 minutes total

---

## Step 6: Create Automation Variables

### 6.1 Create Encrypted Variables

1. In Automation Account, go to **Shared Resources** → **Variables**
2. Click **+ Add a variable** for each of the following:

#### Variable 1: LogAnalyticsWorkspaceId
- **Name:** `LogAnalyticsWorkspaceId`
- **Type:** String
- **Value:** Your Workspace ID from Step 1.2
- **Encrypted:** ✅ Yes
- Click **Create**

#### Variable 2: LogAnalyticsWorkspaceKey
- **Name:** `LogAnalyticsWorkspaceKey`
- **Type:** String
- **Value:** Your Primary Key from Step 1.2
- **Encrypted:** ✅ Yes
- Click **Create**

#### Variable 3: SendGridApiKey
- **Name:** `SendGridApiKey`
- **Type:** String
- **Value:** Your SendGrid API Key from Step 2.2
- **Encrypted:** ✅ Yes
- Click **Create**

#### Variable 4: SenderEmail
- **Name:** `SenderEmail`
- **Type:** String
- **Value:** Your verified sender email from Step 2.3
- **Encrypted:** ❌ No (or Yes if preferred)
- Click **Create**

### 6.2 Verify Variables

You should now have 4 variables listed in the Variables blade.

---

## Step 7: Create the Runbook

### 7.1 Create New Runbook

1. In Automation Account, go to **Process Automation** → **Runbooks**
2. Click **+ Create a runbook**
3. Settings:
   - **Name:** `Remove-StaleEntraDevices`
   - **Runbook type:** PowerShell
   - **Runtime version:** 7.2
   - **Description:** Removes stale Entra ID devices without BitLocker keys
4. Click **Create**

### 7.2 Add Runbook Code

1. The runbook editor will open
2. **Copy the entire PowerShell script** from the artifact
3. **Paste it** into the editor
4. Click **Save**

### 7.3 Publish the Runbook

1. Click **Publish**
2. Click **Yes** to confirm

---

## Step 8: Test the Runbook

### 8.1 First Test Run (WhatIf Mode)

1. In the runbook, click **Start**
2. Configure parameters:
   - **STALEDAYS:** `90` (or your preferred threshold)
   - **RECIPIENTEMAIL:** Your email address
   - **WHATIF:** `True` (important for first test!)
3. Click **OK**

### 8.2 Monitor the Job

1. The job page will open automatically
2. Click **Output** to see real-time logs
3. Wait for completion (may take 5-15 minutes depending on device count)

### 8.3 Verify Results

**Check Output Logs:**
- Look for "Stale devices identified: X"
- Verify "CANDIDATE" and "SKIPPED" entries
- Check summary at the end

**Check Email:**
- You should receive an HTML report
- Review devices that would be deleted
- Check devices skipped due to BitLocker keys

**Check Log Analytics:**
1. Go to your Log Analytics workspace
2. Click **Logs**
3. Run this query:
```kusto
EntraDeviceCleanup_Summary_CL
| order by TimeGenerated desc
| take 10
```
4. You should see your test run data

### 8.4 Production Test (Optional)

If the WhatIf results look correct:

1. Click **Start** again
2. Set **WHATIF:** `False`
3. Monitor carefully - this will actually delete devices!

---

## Step 9: Schedule the Runbook

### 9.1 Create Schedule

1. In your runbook, go to **Resources** → **Schedules**
2. Click **+ Add a schedule**
3. Click **Link a schedule to your runbook**
4. Click **+ Add a schedule**

### 9.2 Configure Schedule

**Recommended: Weekly Schedule**
- **Name:** `Weekly-Device-Cleanup`
- **Description:** Weekly cleanup of stale devices
- **Starts:** Select a date/time (e.g., Sunday 2:00 AM)
- **Timezone:** Your timezone
- **Recurrence:** Recurring
- **Recur every:** 1 Week
- **On these days:** Sunday (or your preferred day)
- **Expiration:** No end date

Click **Create**

### 9.3 Configure Parameters

After creating the schedule, set parameters:
- **STALEDAYS:** `90`
- **RECIPIENTEMAIL:** Your email or distribution list
- **WHATIF:** `False` (for production) or `True` (for ongoing testing)

Click **OK**

### 9.4 Alternative: Monthly Schedule

For less frequent cleanup:
- **Recur every:** 1 Month
- **On day:** First Sunday (or specific day)

---

## Step 10: Create Log Analytics Queries & Alerts

### 10.1 Useful KQL Queries

Navigate to your Log Analytics workspace → **Logs** and save these queries:

#### Query 1: Recent Deletions Summary
```kusto
EntraDeviceCleanup_Summary_CL
| where TimeGenerated > ago(90d)
| project 
    TimeGenerated,
    StaleDevices_d,
    DevicesDeleted_d,
    DevicesWithBitLocker_d,
    DeleteFailures_d,
    WhatIfMode_b
| sort by TimeGenerated desc
```

#### Query 2: All Deleted Devices
```kusto
EntraDeviceCleanup_Deletions_CL
| where TimeGenerated > ago(30d)
| where Action_s == "Deleted"
| project 
    TimeGenerated,
    DisplayName_s,
    OperatingSystem_s,
    LastSync_t,
    Status_s
| sort by TimeGenerated desc
```

#### Query 3: Devices Skipped (with BitLocker)
```kusto
EntraDeviceCleanup_Skipped_CL
| where TimeGenerated > ago(30d)
| project 
    TimeGenerated,
    DisplayName_s,
    OperatingSystem_s,
    LastSync_t,
    BitLockerKeyCount_d
| sort by TimeGenerated desc
```

#### Query 4: Deletion Trends
```kusto
EntraDeviceCleanup_Summary_CL
| where TimeGenerated > ago(90d)
| summarize 
    TotalDeleted = sum(DevicesDeleted_d),
    AvgDeleted = avg(DevicesDeleted_d)
    by bin(TimeGenerated, 7d)
| render timechart
```

#### Query 5: Failed Deletions
```kusto
EntraDeviceCleanup_Deletions_CL
| where Action_s == "Delete Failed"
| project 
    TimeGenerated,
    DisplayName_s,
    Error_s
| sort by TimeGenerated desc
```

### 10.2 Create Alert Rule

Create an alert if too many devices are deleted in one run:

1. In Log Analytics, click **Alerts** → **+ Create** → **Alert rule**
2. **Scope:** Your Log Analytics workspace (already selected)
3. **Condition:**
   - Click **Add condition**
   - **Signal:** Custom log search
   - **Search query:**
   ```kusto
   EntraDeviceCleanup_Summary_CL
   | where DevicesDeleted_d > 100
   | project DevicesDeleted_d, TimeGenerated
   ```
   - **Alert logic:**
     - **Threshold:** Static
     - **Operator:** Greater than
     - **Threshold value:** 0
     - **Check every:** 1 day
     - **Lookback period:** 1 day
4. **Actions:**
   - Create action group to send email/SMS
   - **Name:** `AG-DeviceCleanup-HighCount`
5. **Alert rule details:**
   - **Name:** `High Device Deletion Count`
   - **Severity:** Warning (Sev 2)
6. Click **Create alert rule**

### 10.3 Create Dashboard (Optional)

1. Go to Log Analytics workspace
2. Click **Workbooks** → **+ New**
3. Add visualizations:
   - **Summary stats** (Total devices deleted, avg per run)
   - **Time chart** (Deletion trends)
   - **Table** (Recent deletions)
4. Save the workbook as "Device Cleanup Dashboard"

---

## Troubleshooting

### Issue: "Connect-MgGraph : The term 'Connect-MgGraph' is not recognized"

**Solution:** Modules not installed or still importing
- Wait for all modules to finish installing
- Check module status in **Modules** blade
- Verify runtime version is 7.2

### Issue: "Insufficient privileges to complete the operation"

**Solution:** Managed Identity permissions not granted
- Re-run the PowerShell script from Step 4.1
- Verify permissions in Entra ID → Enterprise Applications
- Wait 10-15 minutes for permissions to propagate

### Issue: "Failed to send data to Log Analytics"

**Solution:** Check Workspace ID and Key
- Verify variables are correct
- Ensure variables are marked as encrypted
- Test the workspace key is still valid

### Issue: "Failed to send email"

**Solution:** SendGrid configuration issue
- Verify API key is correct and has Mail Send permissions
- Ensure sender email is verified in SendGrid
- Check SendGrid account is active (not suspended)

### Issue: No devices found

**Solution:** Filter date format or permissions
- Check the date filter format (ISO 8601)
- Verify Device.Read.All permission is granted
- Try running in Azure Cloud Shell to test Graph API directly

### Issue: "Cannot find module 'Microsoft.Graph.Authentication'"

**Solution:** Module import issue
- Delete and re-import the module
- Ensure you're using PowerShell 7.2 runtime
- Check module dependencies are met

### Issue: BitLocker key check fails

**Solution:** Permission or API issue
- Verify BitlockerKey.Read.All permission is granted
- Some devices may not support BitLocker (non-Windows)
- Add error handling to skip devices that can't be checked

---

## Testing Checklist

Before running in production, verify:

- ✅ Test run completed successfully in WhatIf mode
- ✅ Email report received and looks correct
- ✅ Log Analytics data visible in workspace
- ✅ Devices with BitLocker keys are correctly skipped
- ✅ Only expected stale devices are targeted
- ✅ Schedule is configured for appropriate time
- ✅ Alert rules are working
- ✅ Stakeholders are informed of automation

---

## Maintenance

### Monthly Tasks
- Review deletion reports and trends
- Check for failed deletions
- Verify alert rules are functioning
- Review Log Analytics retention costs

### Quarterly Tasks
- Review stale day threshold (adjust if needed)
- Update recipient email lists
- Review BitLocker key escrow policy
- Audit deleted device logs

### Annual Tasks
- Review and update permissions
- Rotate SendGrid API key
- Rotate Log Analytics workspace key
- Review automation account costs

---

## Cost Estimate

**Log Analytics:**
- Ingestion: ~1-5 MB per run = $0.01-0.05/month
- Retention (90 days): Minimal

**SendGrid:**
- Free tier: 100 emails/day (sufficient for weekly reports)

**Azure Automation:**
- First 500 minutes free per month
- Typical job: 5-15 minutes
- Cost: Free (for weekly schedule)

**Total estimated cost: $0-5/month**

---

## Security Best Practices

1. ✅ Use encrypted variables for all secrets
2. ✅ Managed Identity instead of service principals
3. ✅ Principle of least privilege for Graph API permissions
4. ✅ Always test in WhatIf mode first
5. ✅ Regular review of deletion logs
6. ✅ Alert on anomalous deletion counts
7. ✅ Document all configuration changes
8. ✅ Backup critical device data before automation

---

## Support & Resources

- **Microsoft Graph API Docs:** https://learn.microsoft.com/graph/
- **Azure Automation Docs:** https://learn.microsoft.com/azure/automation/
- **SendGrid Docs:** https://docs.sendgrid.com/
- **Log Analytics KQL:** https://learn.microsoft.com/azure/data-explorer/kusto/

---

## Next Steps

After successful implementation:
1. Monitor first few runs closely
2. Fine-tune stale day threshold based on results
3. Create additional custom queries for your needs
4. Consider expanding to other device management tasks
5. Document your specific configuration for team

---

**Setup Complete! 🎉**

Your automated stale device cleanup is now running. You'll receive weekly reports and can monitor trends in Log Analytics.
