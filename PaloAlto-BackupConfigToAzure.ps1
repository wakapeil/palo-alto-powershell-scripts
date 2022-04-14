[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 # Force TLS 1.2

# Define variables
$paloalto_api_key = ""
$paloalto_hosts = @("firewall.local.domain") # Host array. Backups will be processed serially
$StorageAccountName = "" # Azure storage account name
$SasToken = ""

$StorageContext = New-AzStorageContext -StorageAccountName $StorageAccountName -SasToken $SasToken

# Loop through each firewall in the $paloalto_hosts array
foreach  ($hostname in $paloalto_hosts){

  # Create new temp file
  New-TemporaryFile
  $tmp = New-TemporaryFile
  
  # Use the Palo Alto API to download config to the temp file.
  Write-Host "Downloading $hostname configuration"
  Invoke-WebRequest -Uri "https://$hostname/api/?type=export&category=configuration&key=$paloalto_api_key" -OutFile $tmp.FullName

  # Upload config to blob storage. Each firewall will have its own folder. Filenames will include timestamps
  Write-Host "Uploading $hostname config to blob storage" 
  Set-AzStorageBlobContent `
   -Container "$StorageAccountName" `
   -File $tmp.FullName `
   -Properties @{"ContentType" = "text/xml"} `
   -Blob "PaloAlto\$hostname\$(Get-Date -Format 'MM-MMMM')\$hostname-$(Get-Date -Format 'MM-dd-yyyy-hhmmss').xml" `
   -Context $StorageContext

  # Delete the local temp file
  Write-Host "deleting $hostname temp file" 
  Remove-Item $tmp.FullName -Force
}
