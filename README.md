# Overview

GKE, integrates both [IAM][3] and [Kubernetes RBAC][4] to authorize users to perform actions if they have sufficient permissions according to either approaches.  Typically [Google Groups][5] are used to assign RBAC permissions to members.
More often than not, these users already have a [Google Identity][1], which handles authentication.
Though there are instances when developers may not have a [Google Identity][1].
These developers are typically from a third party organisation which doesn't use Google Identity.  GCP allows [use of external identity providers][6] to authenticate users for GKE.

This writeup provides an [example][7] of configuring an external identity provider (Keycloak) to authenticate users into GKE.

# Environment
We are using a self-hosted [Keycloak][8] instance on GKE as our authentication engine.  It allows all the basic user management functions and also federates identity with OAuth providers like [Github][9].

## Keycloak Service
```yaml
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
Simple Kuberenetes Service, which exposes two endpoints.  
1. HTTP on port 8080
2. HTTPS on port 8443.  We will be using the `https` endpoint

```bash
kubectl create -f keycloak-svc.yaml
# Wait for the service to be created and an IP address to be allocated
export KEYCLOAK_SVC_IP=$(kubectl get services -n keycloak -o jsonpath='{.items[0].status.loadBalancer.ingress[0].ip}')
```

## Using self-signed certificates
> Instead of self-signed certificates, consider using a proper CA like Google Cloud's [Certificate Authority Service][10]  
> For example, check the `Makefile` targets: `create-pool`, `create-root-ca`, and `create-cert`

```bash
openssl req -new -newkey rsa:4096 -x509 -sha256 -days 365 -nodes -subj \
  "/CN=${KEYCLOAK_SVC_IP}"  \
  -addext "subjectAltName = DNS:localhost,IP:${KEYCLOAK_SVC_IP}" \
  -out "tls.crt" -keyout "tls.key"
```
Using the certificate info in `tls.crt` and `tls.key`, create a config map which will be used by the keycloak applicaiton deployed on GKE.

### ConfigMap with Certificate Info
> Consider using `Secrets` instead of `ConfigMap`.  Using `ConfigMap` here for easier troubleshooting.
```bash
kubectl create configmap tls-config -n keycloak --from-file=tls.crt --from-file=tls.key
# kubectl create secret tls tls-secret --cert=tls.cert --key=tls.key
```

## Deploy Keycloak App
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
```

# Initialise environment
```bash
make init
# make create-pool
make create-root-ca
make get-creds
```

# Setup Certificates
```bash
make create-svc
make create-cert
```

# Deploy Keycloak App
```bash
create-app
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