export GCP_PROJECT=scratch-pad-kunall
export GCP_REGION=us-central1
export GKE_CLUSTER_NAME=gke-ext-oidc
export CA_ISSUER_POOL=ext-gke-oidc
export ROOT_CA_ID=keycloak-root-ca

init:
	gcloud config set project ${GCP_PROJECT}
	gcloud services enable container.googleapis.com \
		privateca.googleapis.com
	gcloud config set privateca/location ${GCP_REGION}
	pip3 install --user "cryptography>=2.2.0"

create-pool:
	gcloud privateca pools create ${CA_ISSUER_POOL} --tier "devops"

create-root-ca:
	gcloud privateca roots create ${ROOT_CA_ID} --pool ${CA_ISSUER_POOL} --subject "CN=Keycloak Prod Root CA, O=Google"

create-cert:
	export CLOUDSDK_PYTHON_SITEPACKAGES=1; export KEYCLOAK_SVC_IP=$(kubectl get services -n keycloak -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}'); echo ${KEYCLOAK_SVC_IP}; gcloud privateca certificates create \
      --issuer-pool ${CA_ISSUER_POOL} \
      --subject="CN=${KEYCLOAK_SVC_IP}" \
	  --ip-san="${KEYCLOAK_SVC_IP}"\
      --generate-key \
      --key-output-file=./tls.key \
      --cert-output-file=./tls.crt

get-creds:
	gcloud container clusters get-credentials ${GKE_CLUSTER_NAME} --project=${GCP_PROJECT}

create-svc:
	kubectl apply -f keycloak-svc.yaml

remove-svc:
	kubectl delete -f keycloak-svc.yaml

create-app:
	kubectl create configmap tls-config -n keycloak \
		--from-file=/Users/kunall/scratchpad/learn/gke-external-oidc/tls.crt \
		--from-file=/Users/kunall/scratchpad/learn/gke-external-oidc/tls.key
	kubectl apply -f keycloak.yaml

remove-app:
	kubectl delete -f keycloak.yaml
	kubectl delete configmap tls-config -n keycloak

get-default-client-config:
	kubectl get clientconfig default -n kube-public -o yaml > client-config.yaml

patch-client-config:
	export BASE64_CERT=$(openssl base64 -A -in tls.crt); kubectl patch clientconfig -n kube-public default --type=json -p='[{"op": "add", "path": "/spec/authentication/0/oidc/certificateAuthorityData", "value": "'${BASE64_CERT}'" }]'