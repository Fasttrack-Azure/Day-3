# First, we need a Key Vault
$RG="Sid-Lab-RG-01"
$Region="EAST US"
$AKSCluster = "aksdelta01"
$KVName="AKSKeyVault"+(Get-Random -Minimum 100000000 -Maximum 99999999999)
az keyvault create --name $KVName --resource-group $RG --location $Region

# Let's save a secret
az keyvault secret set --vault-name $KVName --name "TestKey" --value "TestSecret"
az keyvault secret show --name "TestKey" --vault-name $KVName --query "value"

# New Namespace
kubectl create namespace keyvault
kubectl config set-context --current --namespace keyvault


# And the CSI Azure Provider
kubectl apply -f https://raw.githubusercontent.com/Azure/secrets-store-csi-driver-provider-azure/master/deployment/provider-azure-installer.yaml

# Verify the created pods
kubectl get pods -l app=secrets-store-csi-driver -n kube-system
kubectl get pods -l app=csi-secrets-store-provider-azure

# # To access our secrets and keys, we need a Secret Provider Class

#To access your key vault, you can use the user-assigned managed identity that you created when you enabled a managed identity on your AKS cluster:
az aks show -g $RG -n $AKSCluster --query addonProfiles.azureKeyvaultSecretsProvider.identity.clientId -o tsv

$ClientID="381331c6-d89d-4b66-a608-49a0849feb14"

#To grant your identity permissions that enable it to read your key vault and view its contents, run the following commands:
# set policy to access keys in your key vault
az keyvault set-policy -n $KVName --key-permissions get --spn $ClientID
# set policy to access secrets in your key vault
az keyvault set-policy -n $KVName --secret-permissions get --spn $ClientID
# set policy to access certs in your key vault
az keyvault set-policy -n $KVName --certificate-permissions get --spn $ClientID

# Create the class
kubectl apply -f secretproviderclass.yaml 

# Now let's deploy a Pod that access our Secret
code nginx-secrets-store.yaml

kubectl apply -f nginx-secrets-store.yaml

kubectl get pods
kubectl describe pod nginx-secrets-store  

# We can see the Secret in the Pod
kubectl exec -it nginx-secrets-store -- ls -l /mnt/secrets-store/

kubectl exec -it nginx-secrets-store -- cat /mnt/secrets-store/TestKey

# What if we upgrade the key?
# Currently, AKS and AKV are in sync
kubectl get secretproviderclasspodstatus `
        (kubectl get secretproviderclasspodstatus -o custom-columns=":metadata.name" ) -o yaml 

az keyvault secret show --name "TestKey" --vault-name $KVName --query "id" -o tsv

# Set a new value for the secret
az keyvault secret set --vault-name $KVName --name "TestKey" --value "NewSecret"
az keyvault secret show --name "TestKey" --vault-name $KVName --query "value"

# What does our pod show?
kubectl exec -it nginx-secrets-store -- bash -c "cat /mnt/secrets-store/TestKey"

# They are not in sync!
kubectl get secretproviderclasspodstatus `
        (kubectl get secretproviderclasspodstatus -o custom-columns=":metadata.name" ) -o yaml

az keyvault secret show --name "TestKey" --vault-name $KVName --query "id"

# Enable auto-rotation
#az aks update -g $RG -n $AKSCluster --enable-secret-rotation
#az aks addon update -g $RG -n $AKSCluster -a azure-keyvault-secrets-provider --enable-secret-rotation

# Default is 2 minutes
# Try again!
kubectl get secretproviderclasspodstatus `
        (kubectl get secretproviderclasspodstatus -o custom-columns=":metadata.name" ) -o yaml 

az keyvault secret show --name "TestKey" --vault-name $KVName --query "id"

# Enable auto-rotation
az aks update -g $RG -n $AKSCluster --enable-secret-rotation
az aks addon update -g $RG -n $AKSCluster -a azure-keyvault-secrets-provider --enable-secret-rotation

# The key has been updated!
kubectl exec -it nginx-secrets-store -- bash -c "cat /mnt/secrets-store/TestKey"

# How about environment variables?
# Delete the pod
kubectl delete pod nginx-secrets-store

# Create a new pod, which requires an environment variable
code nginx-secrets-store-with-ENV.yaml

kubectl apply -f nginx-secrets-store-with-ENV.yaml

# The Pod won't start because the variable is missing
kubectl get pod nginx-secrets-store
kubectl describe pod nginx-secrets-store

# Let's set the variable
code secret-provide-class-with-ENV-dist.yaml

kubectl edit SecretProviderClass azure-kvname-user-msi

# Delete and Create the Pod again
kubectl delete pod nginx-secrets-store
kubectl apply -f nginx-secrets-store-with-ENV.yaml

# And it's running!
kubectl get pod nginx-secrets-store-02

# Both, the file and the environment variable reflect our key
kubectl exec -it nginx-secrets-store-02 -- bash -c "cat /mnt/secrets-store/TestKey"
kubectl exec -it nginx-secrets-store-02 -- bash -c "printenv TestKey"

# Let's change it again:
az keyvault secret set --vault-name $KVName --name "TestKey" --value "AnotherNewSecret"

# Wait for 2 minutes
# They aren't in sync - environment variables are only exposed at Pod startup!
kubectl exec -it nginx-secrets-store-02 -- bash -c "cat /mnt/secrets-store/TestKey"
kubectl exec -it nginx-secrets-store-02 -- bash -c "printenv TestKey"

# Delete the Pod again
# In a deployment, we could also kill the Pod and have a new one created automatically
kubectl delete pod nginx-secrets-store-02
kubectl apply -f nginx-secrets-store-with-ENV.yaml

# And they are in sync
kubectl exec -it nginx-secrets-store-02 -- bash -c "cat /mnt/secrets-store/TestKey"
kubectl exec -it nginx-secrets-store-02 -- bash -c "printenv TestKey"

# Cleanup
kubectl delete namespace keyvault
Clear-Host