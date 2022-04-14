# Allow the script to connect to firewalls that have untrusted certs
add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 # Force TLS 1.2
$ErrorActionPreference = "Stop"

# Define variables
$paloalto_api_key = "" 
$paloalto_hosts = @("firewall.local.domain") # Host array. Upgrades will be processed serially


# Configurable settings
$panos_base_image = "9.1.0"
$download_base_image = "no"

$panos_feature_release = "9.1.13"
$download_feature_release = "no"
$install_feature_release = "no"
$reboot_after_install = "no"

function Get_Current_SW_Version # Retrieve current software version. The firewall will not be updated if it doesn't have to be
{
  $panos_check_info = Invoke-RestMethod -Uri "https://$hostname/api/?type=op&cmd=<show><system><info></info></system></show>&key=$paloalto_api_key"
  $script:panos_current_version = $panos_check_info.response.result.system."sw-version"
  Write-Host "$hostname is currently on software version $panos_current_version" 
}
function Refresh_Software_List # Refresh the software list so that the firewall knows about the most recent versions
{
  Write-Host Refreshing software list...
  $panos_refresh_sw_list = Invoke-RestMethod -Uri "https://$hostname/api/?type=op&cmd=<request><system><software><check></check></software></system></request>&key=$paloalto_api_key"
  Write-Host Software list is up-to-date as of $panos_refresh_sw_list.response.result."sw-updates"."last-updated-at"
}
function Download_Base_Image # Downloading the base image is only required when moving to a new major release
{
  if ($download_base_image -eq "yes"){
    Write-Host "Downloading base image version $panos_base_image"
    $bi_download_request = Invoke-RestMethod -Uri "https://$hostname/api/?type=op&cmd=<request><system><software><download><version>$panos_base_image</version></download></software></system></request>&key=$paloalto_api_key"
    Check_Job_Progress -job_id $bi_download_request.response.result.job
  }
  else {
    Write-Host "Skipping base image download"
  }
}
function Download_Feature_Release 
{
  if ($download_feature_release -eq "yes")
    {
      Write-Host "Downloading feature release version $panos_feature_release"
      $fr_download_request = Invoke-RestMethod -Uri "https://$hostname/api/?type=op&cmd=<request><system><software><download><version>$panos_feature_release</version></download></software></system></request>&key=$paloalto_api_key"
      Check_Job_Progress -job_id $fr_download_request.response.result.job
    }
  else 
    {
      Write-Host "Skipping feature release download"
    }
}
function Install_Feature_Release 
{
  
  if ($install_feature_release -eq "yes")
    {
      Write-Host "Installing feature release version $panos_feature_release"
      $fr_install_request = Invoke-RestMethod -Uri "https://$hostname/api/?type=op&cmd=<request><system><software><install><version>$panos_feature_release</version></install></software></system></request>&key=$paloalto_api_key"
      Check_Job_Progress -job_id $fr_install_request.response.result.job
    }
  else 
    {
      Write-Host "Skipping feature release install"
    }
}
function Check_Job_Progress($job_id) # Used to check software download and install status before moving to the next step
{
  $percent_completion = 0
  $running_job = Invoke-RestMethod -Uri "https://$hostname/api/?type=op&cmd=<show><jobs><id>$job_id</id></jobs></show>&key=$paloalto_api_key"
  $job_name = $running_job.response.result.job.type
# Check the job every 30 seconds until the download is complete
  do 
  {
    if ($running_job.response.result.job.status -eq "FIN"){break}

    $running_job = Invoke-RestMethod -Uri "https://$hostname/api/?type=op&cmd=<show><jobs><id>$job_id</id></jobs></show>&key=$paloalto_api_key"
    Write-Progress -Activity $job_name -PercentComplete $percent_completion
    $percent_completion = $percent_completion + 5 
    Start-Sleep -Seconds 30

  } 
while ($running_job.response.result.job.status -ne "FIN")

Write-Host $running_job.response.result.job.type complete!
Write-Progress -Activity $job_name -Completed
}
function Reboot_Firewall 
{

  if ($reboot_after_install -eq "yes")
    {
    # If you're connected to the firewall through a VPN, the reboot command will time out. This is expected behavior and the script will continue after a set time
      try
        {
        Write-Host "Rebooting firewall"
        Invoke-RestMethod -Uri "https://$hostname/api/?type=op&cmd=<request><restart><system></system></restart></request>&key=$paloalto_api_key" -UseBasicParsing -TimeoutSec 60 | Out-Null
        }
      catch 
        {
          Write-Host "Reboot request timed out. Moving on."
        } 
    }
  else 
    {
      Write-Host "Not rebooting this firewall"
    }
  Start-Sleep -Seconds 60 #wait for the firewall to reboot
}
function Check_Connectivity # Periodically check to see if the firewall is up. Script will stop if this check doesn't succeed before a set time
{
  Write-Host "Checking connectivity to firewall"
  $percent_completion = 0
  do 
  {
   try 
    { 
        $connection_check = Invoke-WebRequest -Uri "https://$hostname/api/?type=op&cmd=<show><jobs><all></all></jobs></show>&key=$paloalto_api_key" -UseBasicParsing   

        if ($connection_check.StatusCode -eq "200")
          {
            Write-Host "$hostname is now back up"
            Write-Host " "
            break
          }
        Invoke-WebRequest -Uri "https://$hostname/api/?type=op&cmd=<show><jobs><all></all></jobs></show>&key=$paloalto_api_key" -UseBasicParsing | Out-Null
   
      }
    catch 
      {
        Write-Progress -Activity "Reboot In Progress" -PercentComplete $percent_completion
        Start-Sleep -Seconds 30
        $percent_completion = $percent_completion + 2 
      }
     
  }
  while ($connection_check.StatusCode -ne "200")
}

# Main part of the script
foreach  ($hostname in $paloalto_hosts) 
{
  Get_Current_SW_Version 
  if ($panos_feature_release -ne $panos_current_version) 
    {
      Write-Host "This device will be upgraded to $panos_feature_release"
      Refresh_Software_List
      Download_Base_Image
      Download_Feature_Release
      Install_Feature_Release
      Reboot_Firewall
      Check_Connectivity
    }
  else 
    {
      Write-Host "This firewall is already up to date. Skipping upgrade"
      Write-Host " "
    }

}