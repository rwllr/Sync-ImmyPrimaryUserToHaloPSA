Import-ImmyHaloModule
$ImmyComputers = Get-ImmyComputer -IncludeOffline
$users = Get-ImmyAzureADUser

$HaloClientSecret = Get-KeyVaultSecret -Uri "https://name.vault.azure.net/" -SecretName "HaloClientSecret"
$HaloClientID = Get-KeyVaultSecret -Uri "https://name.vault.azure.net/" -SecretName "HaloClientID"
$token = Connect-HaloAPI -ClientID $HaloClientID -BaseUri "$HaloURL" -Secret $HaloClientSecret -HostedTenant "tenant"

##TODO: Add primary email from AzureAD based on UPN from improved contact matching
##TODO: Add UPN to Halo contact

$ImmyComputersWithAutomateComputerId = $ImmyComputers | ForEach-Object {
    $ImmyComputer = $_
    if(!$ImmyComputer.PrimaryPersonEmail)
    {
        #Write-Warning "$($ImmyComputer.Name) does not have a Primary Person"
        return
    }
    $RmmComputer = Get-RmmComputer -ProviderType CWAutomate -Computer $ImmyComputer
    if ($RmmComputer) 
    {
        $ImmyComputer | Add-Member -NotePropertyName "CWAComputerId" -NotePropertyValue $RmmComputer.RmmDeviceId
        $ImmyComputer | Add-Member -NotePropertyName "CWAClientId" -NotePropertyValue $RmmComputer.RmmClientId
        $ImmyComputer | Add-Member -NotePropertyName "PrimaryPersonMail" -NotePropertyValue ($users | Where { $_.userprincipalname -eq $ImmyComputer.PrimaryPersonEmail }).mail
        return $ImmyComputer
    }
    
}

$CWATenants = $ImmyComputersWithAutomateComputerId | Where {$_.CWAClientId} | Select -Unique -ExpandProperty CWAClientId
$CWAHaloMappings = Invoke-HaloRestMethod -Endpoint "api/Control?includeintegrationsettings=true&integrationmoduleid=215"
$HaloClientIDs = $CWATenants | % {
    $CWATenant = $_
    Write-Warning $CWATenant
    $($CWAHaloMappings.automate_sitemappings | Where {$_.'third_party_client_id' -in $CWATenant}).'halo_client_id'
}
Write-Warning "Matches ID: $HaloClientIDs"
if ($HaloClientIDs) {

    $users = ($HaloClientIDs | % { Invoke-HaloRestMethod -Endpoint "api/users?count=1000&client_id=$_" }).users
    Write-Warning "$($users.count) users found"
    $assets = ($HaloClientIDs | % { Invoke-HaloRestMethod -Endpoint "api/asset?count=1000&client_id=$_" }).assets
    Write-Warning "$($assets.count) assets found"

    $MatchedObjects = $ImmyComputersWithAutomateComputerId | ForEach-Object {
        $Computer = $_
        $HaloComputer = $assets | Where {$Computer.CWAComputerId -eq $_.automate_id} 
        if ($Computer.PrimaryPersonMail) {$HaloOwner = $users | Where {$Computer.PrimaryPersonMail -eq $_.emailaddress}}
        else { $HaloOwner = $users | Where {$Computer.PrimaryPersonEmail -eq $_.emailaddress} }

        if ($HaloOwner -and $HaloComputer)
        {
            $userOwner = @(@{id=$($HaloOwner.id)})
            $newAsset = @{
                id = $HaloComputer.id
                users = $userOwner
            }
            return $newAsset
        }
    }
    Write-Output "There's $($MatchedObjects.count) matches"
    $MatchedObjects = ConvertTo-Json -Depth 10 @($MatchedObjects)
    #$MatchedObjects
    $null = Invoke-HaloRestMethod -Endpoint "api/asset" -Method POST -Body $MatchedObjects
}
