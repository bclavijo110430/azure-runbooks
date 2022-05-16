Param(
    [string[]]$Domains,
    [string]$EmailAddress,
    [string]$STResourceGroupName,
    [string]$storageName,
    [string]$AGResourceGroupName,
    [string]$AGName,
    [string]$identifiercert,
    [string]$AGOldCertName
)
$date=(Get-Date).ToString("yyyyMMdd")
#$date=Get-Date -Format FileDate
$domain= [System.String]::Concat($identifiercert,".",$date)


# Ensures that no login info is saved after the runbook is done
Disable-AzContextAutosave

# Log in as the service principal from the Runbook
$connection = Get-AutomationConnection -Name AzureRunAsConnection
Login-AzAccount -ServicePrincipal -Tenant $connection.TenantID -ApplicationId $connection.ApplicationID -CertificateThumbprint $connection.CertificateThumbprint

# Create a state object and save it to the harddrive
$state = New-ACMEState -Path $env:TEMP
$serviceName = 'LetsEncrypt'

# Fetch the service directory and save it in the state
Get-ACMEServiceDirectory $state -ServiceName $serviceName -PassThru;

# Get the first anti-replay nonce
New-ACMENonce $state;

# Create an account key. The state will make sure it's stored.
New-ACMEAccountKey $state -PassThru -Force;

# Register the account key with the acme service. The account key will automatically be read from the state
New-ACMEAccount $state -EmailAddresses $EmailAddress -AcceptTOS;

# Load an state object to have service directory and account keys available
$state = Get-ACMEState -Path $env:TEMP;

# It might be neccessary to acquire a new nonce, so we'll just do it for the sake of the example.
New-ACMENonce $state -PassThru;

# Create the identifier for the DNS name
$dnsIdentifiers = $Domains | ForEach-Object { New-ACMEIdentifier $_ };
# Create the order object at the ACME service.
#$order = New-ACMEOrder $state -Identifiers $identifier;$identifier2
$order = New-ACMEOrder $state -Identifiers $dnsIdentifiers;

$authorizations = @(Get-ACMEAuthorization -State $state -Order $order);


foreach($authz in $authorizations) {
    # Select a challenge to fullfill
    $challenge = Get-ACMEChallenge -State $state -Authorization $authZ -Type "http-01";

# Create the file requested by the challenge
$fileName = $env:TMP + '\' + $challenge.Token;
Set-Content -Path $fileName -Value $challenge.Data.Content -NoNewline;

$blobName = ".well-known/acme-challenge/" + $challenge.Token
$storageAccount = Get-AzStorageAccount -ResourceGroupName $STResourceGroupName -Name $storageName
$ctx = $storageAccount.Context
Set-AzStorageBlobContent -File $fileName -Container "public" -Context $ctx -Blob $blobName

# Signal the ACME server that the challenge is ready
$challenge | Complete-ACMEChallenge $state;
}

# Wait a little bit and update the order, until we see the states
while($order.Status -notin ("ready","invalid")) {
    Start-Sleep -Seconds 10;
    $order | Update-ACMEOrder $state -PassThru;
}

# Should the order get invalid, use Get-ACMEAuthorizationError to list error details.
if($order.Status -ieq ("invalid")) {
    $order | Get-ACMEAuthorizationError -State $state;
    throw "Order was invalid";
}

# We should have a valid order now and should be able to complete it
# Therefore we need a certificate key
$certKey = New-ACMECertificateKey -Path "$env:TEMP\$domain.key.xml";

# Complete the order - this will issue a certificate singing request
Complete-ACMEOrder $state -Order $order -CertificateKey $certKey;

# Now we wait until the ACME service provides the certificate url
while(-not $order.CertificateUrl) {
    Start-Sleep -Seconds 15
    #$order | Update-Order $state -PassThru
     $order | Update-ACMEOrder $state -PassThru
}

# As soon as the url shows up we can create the PFX
$password = ConvertTo-SecureString -String "pass" -Force -AsPlainText
Export-ACMECertificate $state -Order $order -CertificateKey $certKey -Path "$env:TEMP\$domain.pfx" -Password $password;

# Delete blob to check DNS
Remove-AzStorageBlob -Container "public" -Context $ctx -Blob $blobName

### RENEW APPLICATION GATEWAY CERTIFICATE ###
$appgw = Get-AzApplicationGateway -ResourceGroupName $AGResourceGroupName -Name $AGName
Add-AzApplicationGatewaySslCertificate -ApplicationGateway $appgw -Name "$domain" -CertificateFile "$env:TEMP\$domain.pfx" -Password $password
Set-AzApplicationGatewaySSLCertificate -Name $AGOldCertName -ApplicationGateway $appgw -CertificateFile "$env:TEMP\$domain.pfx" -Password $password
#Set-AzApplicationGatewaySSLCertificate -Name $domain -ApplicationGateway $appgw -CertificateFile "$env:TEMP\$domain.pfx" -Password $password
Set-AzApplicationGateway -ApplicationGateway $appgw
