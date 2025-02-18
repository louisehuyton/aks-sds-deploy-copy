#!/bin/bash

ENV=$3

if [[ -z "$ENV" ]]; then
    echo -e "Environment not set" 
    exit 1
fi

set -ex

# Set Dynatrace VAULT_NAME & DYNATRACE_INSTANCE to Prod or non-prod values
VAULT_NAME="dtssharedservices${ENV}kv"
if [ $ENV = "prod" ]; then
  DYNATRACE_INSTANCE="ebe20728"
else
  DYNATRACE_INSTANCE="yrk32651"
fi

DYNATRACE_CLUSTERROLE_BINDING=dynatrace-cluster-role-binding.yaml

error_exit()
{
  echo "$1" 1>&2
  exit 1
}

kubectl apply -f ${DYNATRACE_CLUSTERROLE_BINDING}

if kubectl config current-context; then
  K8S_API_URL=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
  CLUSTER_NAME=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
  BEARER_TOKEN=$(kubectl get secret "$(kubectl get sa dynatrace-monitoring \
    -o jsonpath='{.secrets[0].name}' -n dynatrace)" -o jsonpath='{.data.token}' \
    -n dynatrace | base64 --decode)
else
  error_exit "context not set!! Aborting."
fi

API_KEY=$(az keyvault secret show \
 --name dynatrace-api-key-"${DYNATRACE_INSTANCE}" \
 --vault-name "${VAULT_NAME}" \
 --query value -o tsv)

if [ -z "$API_KEY" ]; then
  error_exit "API_KEY not set !! Aborting."
else
  echo "API_KEY is set to $API_KEY continuing."
fi

generate_kubernetes_credentials() {
  cat <<EOF
    {
      "label": "$CLUSTER_NAME",
      "endpointUrl": "$K8S_API_URL",
      "workloadIntegrationEnabled": true,
      "authToken": "$BEARER_TOKEN",
      "certificateCheckEnabled": false
    }
EOF
}

DT_OLD_CLUSTER_ID=$(curl --request GET \
 --url "https://$DYNATRACE_INSTANCE.live.dynatrace.com/api/config/v1/kubernetes/credentials" \
 --header 'Authorization: Api-Token '"$API_KEY"'' | jq .values[] | jq -r 'select(.name=="'"${CLUSTER_NAME}"'").id')

# If previously registered, ID of the AKS cluster in DT should be removed prior
# to the registration of the rebuilt cluster.
if [ -n "${DT_OLD_CLUSTER_ID}" ]; then
  echo "Dynatrace old cluster ID found for $CLUSTER_NAME. This will be deleted.."
  curl --request DELETE \
   --url "https://$DYNATRACE_INSTANCE.live.dynatrace.com/api/config/v1/kubernetes/credentials/${DT_OLD_CLUSTER_ID}" \
   --header 'Authorization: Api-Token '"$API_KEY"''
fi

echo "Validating payload.."
status=$(curl -s -o /dev/null -w "%{http_code}" --request POST --url "https://$DYNATRACE_INSTANCE.live.dynatrace.com/api/config/v1/kubernetes/credentials/validator" \
 --data "$(generate_kubernetes_credentials)" \
 --header 'Content-type: application/json' \
 --header 'Authorization: Api-Token '"$API_KEY"'')

if [ "${status}" = "400" ]; then
  error_exit "Payload validation failed!! Aborting."
else
  echo "Initiating Dynatrace registration.."
  # TODO switch fail to fail-with-body once ubuntu has greater than curl 7.76.0
  curl --request POST \
   --retry 5 \
   --retry-delay 0 \
   --fail  \
   --url "https://$DYNATRACE_INSTANCE.live.dynatrace.com/api/config/v1/kubernetes/credentials" \
   --data "$(generate_kubernetes_credentials)" \
   --header 'Content-type: application/json' \
   --header 'Authorization: Api-Token '"$API_KEY"''
fi
