# Overview

GKE, integrates both [IAM][3] and [Kubernetes RBAC][4] to authorize users to perform actions if they have sufficient permissions according to either approaches.  Typically [Google Groups][5] are used to assign RBAC permissions to members.  
More often than not, these users already have a [Google Identity][1], which handles authentication. Though there are instances when developers may not have a [Google Identity][1].  
These developers are typically from a third party organisation which doesn't use Google Identity.  GCP allows [use of external identity providers][6] to authenticate users for GKE.

This writeup provides an [example][7] of configuring an external identity provider (Keycloak) to authenticate users into GKE.

# Functional Overview of various components
1. GKE Cluster
2. Authentication Engine - Keycloak
3. Developer Config for Login

## GKE Cluster
A Kubernetes cluster for use by external developers.
### Initialise the environment
```bash
export PROJECT_ID=
export GCP_REGION=us-central1
export GCP_ZONE=${GCP_REGION}-b
export GKE_CLUSTER_NAME=gke-ext-oidc
gcloud config set project ${GCP_PROJECT}
gcloud services enable container.googleapis.com \
    privateca.googleapis.com
```
#### Create the cluster with an Identity Service
```bash
gcloud container clusters create ${GKE_CLUSTER_NAME} \
    --zone ${GCP_ZONE} \
    --enable-identity-service
```
Identity Service for GKE creates a few Kubernetes objects in `anthos-identity-service` namespace.  Some of the important objects are:  
1. **ClientConfig CRD**: used by cluster administrators to configure OIDC settings before distributing to developers.  It contains various configuration items like identity provider details, user & group claim mappings.
2. `gke-oidc-service` **Deployment**: to validate identity tokens for ClientConfig resources.
## Authentication Engine - Keycloak
We are using a self-hosted [Keycloak][8] instance on GKE as our authentication engine.  It allows all the basic user management functions and also federates identity with OAuth providers like [Github][9].

> We are deploying this Keycloak instance in the same GKE cluster for simplicity
### Keycloak Service
```yaml
# keycloak-svc.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: keycloak
---
apiVersion: v1
kind: Service
metadata:
  name: keycloak-svc
  namespace: keycloak
  labels:
    app: keycloak
spec:
  ports:
  - name: http
    port: 8080
    targetPort: 8080
  - name: https
    port: 8443
    targetPort: 8443
  selector:
    app: keycloak
  type: LoadBalancer
```
A simple Kuberenetes Service, which exposes two endpoints.  
1. HTTP on port 8080
2. HTTPS on port 8443.  We will be using the `https` endpoint

```bash
kubectl create -f keycloak-svc.yaml
# Wait for the service to be created and an IP address to be allocated
export KEYCLOAK_SVC_IP=$(kubectl get services -n keycloak -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
```

### Using self-signed certificates
> Consider using a proper CA like Google Cloud's [Certificate Authority Service][10] for prod environments.  
> For example, check the [`Makefile`][11] targets: `create-pool`, `create-root-ca`, and `create-cert`

```bash
openssl req -new -newkey rsa:4096 -x509 -sha256 -days 365 -nodes -subj \
  "/CN=${KEYCLOAK_SVC_IP}"  \
  -addext "subjectAltName = DNS:localhost,IP:${KEYCLOAK_SVC_IP}" \
  -out "tls.crt" -keyout "tls.key"
```
Using the certificate info in `tls.crt` and `tls.key`, create a config map which will be used by the keycloak applicaiton deployed on GKE.

#### ConfigMap with Certificate Info
> For production, consider using `Secrets` instead of `ConfigMap`.  Using `ConfigMap` here for easier troubleshooting.
```bash
kubectl create configmap tls-config -n keycloak --from-file=tls.crt --from-file=tls.key
# kubectl create secret tls tls-secret --cert=tls.cert --key=tls.key
```

### Deploy Keycloak App
```yaml
# keycloak.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
  namespace: keycloak
  labels:
    app: keycloak
spec:
  replicas: 1
  selector:
    matchLabels:
      app: keycloak
  template:
    metadata:
      labels:
        app: keycloak
    spec:
      volumes:
      - name: tls-config-volume
        # secret:
        #   secretName: tls-config
        configMap:
          name: tls-config
          items:
          - key: tls.crt
            path: tls.crt
          - key: tls.key
            path: tls.key
      containers:
      - name: keycloak
        image: quay.io/keycloak/keycloak:18.0.1
        # Start keycloak service in production for HTTPS
        args: ["start"]
        volumeMounts:
        # Volume to hold the certificate to be used by Keycloak service
        - name: tls-config-volume
          mountPath: "/etc/x509/https"
        env:
        # Admin user configuration
        - name: KEYCLOAK_ADMIN
          value: "admin"
        - name: KEYCLOAK_ADMIN_PASSWORD
          value: "admin"
        # By defaulut production service expects a hostname.  Disable that config for K8S
        - name: KC_HOSTNAME_STRICT
          value: "false"
        # Certificate info for TLS
        - name: KC_HTTPS_CERTIFICATE_FILE
          value: /etc/x509/https/tls.crt
        - name: KC_HTTPS_CERTIFICATE_KEY_FILE
          value: /etc/x509/https/tls.key
        ports:
        - name: http
          containerPort: 8080
        - name: https
          containerPort: 8443
        readinessProbe:
        # Note the scheme for HTTPS readiness probe
          httpGet:
            path: /realms/master
            port: 8443
            scheme: HTTPS
```

```bash
# deploy app
kubectl create -f keycloak.yaml
# Wait for a few minutes to access Admin Console.  Default username `admin` & password `admin`
echo "Keycloak console: https://${KEYCLOAK_SVC_IP}:8443"
```

### Configure Keycloak to Authenticate Developers  
> These steps should be performed by the Administrator to onboard developers on GKE  
1. Log in to the admin console `https://${KEYCLOAK_SVC_IP}:8443`
2. Hover over `Master` realm on top left, and client `Create`
3. Enter `gkeExtAuth` as the name the new realm & click `Create`
4. In `gkeExtAuth`, `Realm Settings` >> `Tokens`, set `Access Token Lifespan` to `1 Hour`
5. Using navigation on left, add `user`
   - Username: testing
   - Email: testing@testing.com
   - First name: testing
   - Last name: testing
   - Set user enabled and email verified to: `True`
   - Click `Save`
   - Under credentials tab:
      - Set & confirm password
      - Set the `temporary` to: `OFF`
      - Click `Set Password`
     > Note the user ID for this user.
     ```bash
     export OIDC_USER_ID=<user ID value from the user list>
     ```
6. Using navigation on the left `Clients` >> `Create`
   - Client ID: `client4gke`
   - `Save`
   - In `client4gke`:
      - Access Type: `confidential`
      - Valid Redirect URIs: `http://localhost:10000/callback`
      - `Save`
      - In the `Credentials` tab:
         - Client Authenticator: `Client ID and Secret`
         > Note the client ID and secret in an environment variable
         ```bash
         export OIDC_CLIENT_ID=<client ID from keycloak>
         export OIDC_CLIENT_SECRET=<client secret from keycloak>
         # also set the issue URI as https://${KEYCLOAK_SVC_IP}:8443/realms/<realm name from step 3>
         export OIDC_ISSUER_URI=https://${KEYCLOAK_SVC_IP}:8443/realms/gkeExtAuth
         ```

### Enable OIDC
1. Download the current `default` ClientConfig
   ```bash
   # Optional: simply to keep a copy of the original config
   kubectl get clientconfig default -n kube-public -o yaml > client-config-original.yaml
   ```
2. Patch the `default` ClientConfig with our OIDC provider details:  
   1. Configure the certificate info used by keycloak server
      > We need to perform this step as we are using self-signed certificate
      ```bash
      export BASE64_CERT=$(openssl base64 -A -in tls.crt)
      kubectl patch clientconfig -n kube-public default --type=json -p='[{"op": "add", "path": "/spec/authentication/0/oidc/certificateAuthorityData", "value": "'${BASE64_CERT}'" }]'
      ```
   2. Set the client ID.  This is the client ID configured in the keycloak OIDC provider
      ```bash
      kubectl patch clientconfig -n kube-public default --type=json -p='[{"op": "add", "path": "/spec/authentication/0/oidc/clientID", "value": "'${OIDC_CLIENT_ID}'" }]'
      ```
   3. Set the `issuerURI`.  This issuer URI is the realm configured in keycloak OIDC.
      ```bash
      kubectl patch clientconfig -n kube-public default --type=json -p='[{"op": "add", "path": "/spec/authentication/0/oidc/issuerURI", "value": "'${OIDC_ISSUER_URI}'" }]'
      ```
   4. Set the `cloudConsoleRedirectURI` value.  This is a general constant used with GCP.
      ```bash
      kubectl patch clientconfig -n kube-public default --type=json -p='[{"op": "add", "path": "/spec/authentication/0/oidc/cloudConsoleRedirectURI", "value": "https://console.cloud.google.com/kubernetes/oidc" }]'
   5. Set the `extraParams`:
      ```bash
      kubectl patch clientconfig -n kube-public default --type=json -p='[{"op": "add", "path": "/spec/authentication/0/oidc/extraParams", "value": "prompt=consent" }]'
      ```
   6. Set the `kubectlRedirectURI`.  This is the callback URL on localhost for OIDC provider to respond to the auth request.
      ```bash
      kubectl patch clientconfig -n kube-public default --type=json -p='[{"op": "add", "path": "/spec/authentication/0/oidc/kubectlRedirectURI", "value": "http://localhost:10000/callback" }]'
      ```
   7. Set the `scopes`.  Scopes requested from auth:
      ```bash
      kubectl patch clientconfig -n kube-public default --type=json -p='[{"op": "add", "path": "/spec/authentication/0/oidc/scopes", "value": "email, profile" }]'
      ```
   8. Set the `userClaim`.  Request the user ID from OIDC provider.
      ```bash
      kubectl patch clientconfig -n kube-public default --type=json -p='[{"op": "add", "path": "/spec/authentication/0/oidc/userClaim", "value": "sub" }]'
      ```

### Create a login file for developers
```bash
kubectl get clientconfig default -n kube-public -o yaml > login-config.yaml
yq '.spec.authentication[].oidc.clientSecret += "'${OIDC_CLIENT_SECRET}'"' login-config.yaml > dev-login-config.yaml
```

## Create a RBAC Policy
```yaml
# secret-viewer-cluster-role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: secret-viewer
rules:
- apiGroups: [""]
  # The resource type for which access is granted
  resources: ["secrets"]
  # The permissions granted by the ClusterRole
  verbs: ["get", "watch", "list"]
```
Create the ClusterRole:
```bash
kubectl apply -f secret-viewer-cluster-role.yaml
```

```yaml
# secret-viewer-cluster-role-binding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name:  people-who-view-secrets
subjects:
- kind: User
  name: ISSUER_URI#USER
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: secret-viewer
  apiGroup: rbac.authorization.k8s.io
```
Create the ClusterRoleBinding:
```bash
sed -i "s|ISSUER_URI|${OIDC_ISSUER_URI}|g" secret-viewer-cluster-role-binding.yaml
sed -i "s|USER|${OIDC_USER_ID}|g" secret-viewer-cluster-role-binding.yaml
kubectl apply -f secret-viewer-cluster-role-binding.yaml
```

## Login as a developer
```bash
kubectl oidc login --cluster=GKE_CLUSTER_NAME --login-config=dev-login-config.yaml
```
> To authenticate the developer, follow the prompts in the web browser.  
> When properly authenticated, developers should be able to view `secrets` but not be able to list the `pods`
```bash
# should work
kubectl get secrets
# should not work
kubectl get pods 
```


------
[1]: https://developers.google.com/identity
[2]: https://cloud.google.com/identity
[3]: https://cloud.google.com/kubernetes-engine/docs/how-to/iam
[4]: https://kubernetes.io/docs/reference/access-authn-authz/rbac/
[5]: https://cloud.google.com/kubernetes-engine/docs/how-to/google-groups-rbac
[6]: https://cloud.google.com/kubernetes-engine/docs/how-to/oidc
[7]: https://github.com/finiteloopme/gke-external-oidc
[8]: https://www.keycloak.org/
[9]: https://github.com/settings/developers
[10]: https://cloud.google.com/certificate-authority-service
[11]: ./Makefile