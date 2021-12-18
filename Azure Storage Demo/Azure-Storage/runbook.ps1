$AKSCluster = 'sidlabaks03'
$RG = 'Intel_RG_01'

# So far, we have 4 Storage Classes - but no Volumes or Claims
kubectl get pv,pvc,storageclass --all-namespaces -o name

# First, we will create a deployment with a static (manually created) Azure disk
# Another Namespace
kubectl create namespace azuredisk-static
kubectl config set-context --current --namespace azuredisk-static

# Then, we need our Node Resource Group
$NodeRG=(az aks show --resource-group $RG --name $AKSCluster --query nodeResourceGroup)

# Where we will create a disk
$DiskName="azure-managed-disk-aks-static"
az disk create `
  --resource-group $NodeRG `
  --name $DiskName `
  --size-gb 10 `
  --query id

# We need the ID of that disk for our deployment
code nginx-with-azuredisk-stat.yaml

# If we apply this
kubectl apply -f .\nginx-with-azuredisk-stat.yaml 

# Still no PV or PVC
kubectl get pv,pvc --all-namespaces

# But our Pod is running
kubectl get pods 

# And has mounted the Volume - check out the volume section
kubectl describe pod (kubectl get pods -o=jsonpath='{.items[0].metadata.name}') 

# Dynamic provisioning for Azure Disks
kubectl create namespace azuredisk-dynamic
kubectl config set-context --current --namespace azuredisk-dynamic

# Instead of a disk, we create a PVC
code pvc-azure-managed-disk-dynamic.yaml
kubectl apply -f pvc-azure-managed-disk-dynamic.yaml

# Still no PV - but a PVC
kubectl get pv,pvc

# Now, we'll point a deployment at that PVC
code nginx-with-azuredisk-dynamic.yaml

kubectl apply -f .\nginx-with-azuredisk-dynamic.yaml

# This triggers the PV
kubectl get pv

# The PVC is now also bound
kubectl get pvc

kubectl get pods 
kubectl describe pod (kubectl get pods -o=jsonpath='{.items[0].metadata.name}')

# This new disk is also visible in the portal!
$Url = "https://portal.azure.com/#@" + $TenantName + ".onmicrosoft.com/resource" + (az group show -n $NodeRG --query id -o tsv)
Start-Process $Url

# We can also see this through the CLI
az disk list -o table --resource-group $NodeRG

# Let's scale this up
kubectl scale deployment nginx-azdisk-dynamic-deployment --replicas=2

kubectl get pods 

# Won't work - disks can only be attached to a single Pod!
kubectl describe pod (kubectl get pods -o=jsonpath='{.items[0].metadata.name}' --field-selector=status.phase!=Running)

# Don't forget about the retention policy!
kubectl get storageclass managed-premium 

code storageclass-managed-premium-retain.yaml

kubectl apply -f storageclass-managed-premium-retain.yaml

kubectl get storageclass -o=custom-columns='NAME:.metadata.name,RECLAIMPOLICY:.reclaimPolicy' | grep -e managed -e NAME

code nginx-with-azuredisk-dynamic-retain.yaml 

kubectl apply -f nginx-with-azuredisk-dynamic-retain.yaml

kubectl get pvc,pv -o name

kubectl delete deployment nginx-azdisk-dynamic-deployment         
kubectl delete deployment nginx-azdisk-dynamic-deployment-retain   
kubectl delete pvc pvc-azure-managed-disk-dynamic
kubectl delete pvc pvc-azure-managed-disk-dynamic-retain

kubectl get pv 

# Needs to be deleted manually!
kubectl delete pv (kubectl get pv -o=jsonpath='{.items[0].metadata.name}')

kubectl get pv 

# Also remember: We have a limit of disks per node.
# On a default cluster, we get 3 Nodes of size DS2_v2. This would equal to 24 disks.
kubectl create namespace azuredisk-maxdisks
kubectl config set-context --current --namespace azuredisk-maxdisks

# Let's create 24 PVCs and Deployments
# for ($i=1; $i -le 24; $i++) {
# $ID='{0:d2}' -f $i
# $PVCName_Old="pvc-azure-managed-disk-dynamic"
# $PVCName_New="pvc-maxdisk-$ID"
# $DeploymentName_Old="nginx-azdisk-dynamic-deployment"
# $DeploymentName_New="nginx-maxdisk-$ID"

# (Get-Content -Path .\pvc-azure-managed-disk-dynamic.yaml) -replace $PVCName_Old,$PVCName_New | Out-File -FilePath pvc-maxdisks.yaml
# (Get-Content -Path .\nginx-with-azuredisk-dynamic.yaml) -replace $PVCName_Old,$PVCName_New -replace $DeploymentName_Old,$DeploymentName_New | Out-File -FilePath deployment-maxdisks.yaml

# kubectl apply -f pvc-maxdisks.yaml
# kubectl apply -f deployment-maxdisks.yaml
# }

# This also created extra disks in Azure
Start-Process $Url

# Check out the last pod and PVC
kubectl get pods
kubectl get pvc 

# kubectl describe pvc pvc-maxdisk-24

# kubectl describe pod (kubectl get pods -o=jsonpath='{.items[23].metadata.name}')

# If we need this many deployments, we need to scale up our cluster by increasing the nodes or by upsizing
az aks scale --resource-group  $RG --name $AKSCluster --node-count 4 --nodepool-name nodepool1

# Now that we can add more disks, the Pod will automatically start up
kubectl get pods
kubectl describe pod (kubectl get pods -o=jsonpath='{.items[23].metadata.name}')


# Azure Files
kubectl create namespace azurefile-static
kubectl config set-context --current --namespace azurefile-static

# Create a storage account
$azFileStorage="azfile"+(Get-Random -Minimum 100000000 -Maximum 99999999999)
az storage account create -n $azFileStorage -g $RG -l EastUS --sku Standard_LRS

# Get the connection string
$StorageConnString=(az storage account show-connection-string -n $azFileStorage -g $RG -o tsv)

# Create a share
az storage share create -n aksshare --connection-string $StorageConnString

# Get the storage key
$StorageKey=(az storage account keys list --resource-group $RG --account-name $azFileStorage --query "[0].value" -o tsv)

# And store it as a secret in the cluster
kubectl create secret generic azure-secret `
        --from-literal=azurestorageaccountname=$azFileStorage `
        --from-literal=azurestorageaccountkey=$StorageKey `
        -n default

# Let's deploy this as an Inlinevolume
code nginx-with-azurefiles-stat-inline.yaml
kubectl apply -f .\nginx-with-azurefiles-stat-inline.yaml

kubectl get pods 

# Let's scale this up
kubectl scale deployment nginx-azfile-static-deployment-inline --replicas=5

kubectl get pods 

# Lets check, if they really share this storage
# Both don't have a test file
kubectl exec -it (kubectl get pods -o=jsonpath='{.items[0].metadata.name}') -- bash -c "cat /usr/share/nginx/html/web-app/test"
kubectl exec -it (kubectl get pods -o=jsonpath='{.items[1].metadata.name}') -- bash -c "cat /usr/share/nginx/html/web-app/test"

# Let's create it on one pod
kubectl exec -it (kubectl get pods -o=jsonpath='{.items[0].metadata.name}') -- bash -c "echo Test > /usr/share/nginx/html/web-app/test"

# And see
kubectl exec -it (kubectl get pods -o=jsonpath='{.items[0].metadata.name}') -- bash -c "cat /usr/share/nginx/html/web-app/test"
kubectl exec -it (kubectl get pods -o=jsonpath='{.items[1].metadata.name}') -- bash -c "cat /usr/share/nginx/html/web-app/test"


# Now again - with a PVC and PV
code pv-azurefile.yaml
code pvc-azurefile.yaml
kubectl apply -f pv-azurefile.yaml
kubectl apply -f pvc-azurefile.yaml

kubectl get pvc

code nginx-with-azurefiles-stat-pvc.yaml
kubectl apply -f .\nginx-with-azurefiles-stat-pvc.yaml

kubectl get pods 

kubectl scale deployment nginx-azfile-static-deployment-pvc --replicas=5

kubectl get pods 

# Dynamic
kubectl create namespace azurefile-dynamic
kubectl config set-context --current --namespace azurefile-dynamic

code pvc-azure-files-dynamic.yaml
kubectl apply -f pvc-azure-files-dynamic.yaml
kubectl get pvc

code nginx-with-azurefiles-dynamic.yaml
kubectl apply -f nginx-with-azurefiles-dynamic.yaml

kubectl get pvc
kubectl get pods

# Cleanup
kubectl delete namespace azuredisk-maxdisks
kubectl delete namespace azuredisk-static 
kubectl delete namespace azuredisk-dynamic
kubectl delete namespace azurefile-dynamic
kubectl delete namespace azurefile-static
Clear-Host