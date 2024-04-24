export WORKDIR=`pwd`
PROJECT_NUMBER=$(gcloud projects describe ${PROJECT_ID} --format="value(projectNumber)")

kubectl apply - -f <<EOF
apiVersion: v1
data:
  server.insecure: "true"
kind: ConfigMap
metadata:
  name: argocd-cmd-params-cm
  namespace: argocd
EOF

kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: argocd-server-external
  namespace: argocd
  annotations:
    cloud.google.com/neg: '{"ingress": true}'
    cloud.google.com/backend-config: '{"ports": {"http":"argocd-backend-config"}}'
spec:
  type: ClusterIP
  ports:
  - name: http
    port: 80
    protocol: TCP
    targetPort: 8080
  selector:
    app.kubernetes.io/name: argocd-server
EOF

kubectl apply -f - <<EOF
apiVersion: cloud.google.com/v1
kind: BackendConfig
metadata:
  name: argocd-backend-config
  namespace: argocd
spec:
  healthCheck:
    checkIntervalSec: 30
    timeoutSec: 5
    healthyThreshold: 1
    unhealthyThreshold: 2
    type: HTTP
    requestPath: /healthz
    port: 8080
EOF

kubectl apply -f - <<EOF
apiVersion: networking.gke.io/v1beta1
kind: FrontendConfig
metadata:
  name: argocd-frontend-config
  namespace: argocd
spec:
  redirectToHttps:
    enabled: true
EOF

gcloud compute addresses create argocd-ingress-ip --project ${PROJECT_ID}  --global --ip-version IPV4 
export ARGOCD_IP=$(gcloud compute addresses describe argocd-ingress-ip --project ${PROJECT_ID} --global --format "value(address)") 
echo ${ARGOCD_IP}

cat <<EOF > ${WORKDIR}/dns-spec.yaml
swagger: "2.0"
info:
  description: "Cloud Endpoints DNS"
  title: "Cloud Endpoints DNS"
  version: "1.0.0"
paths: {}
host: "frontend.endpoints.${PROJECT_ID}.cloud.goog"
x-google-endpoints:
- name: "frontend.endpoints.${PROJECT_ID}.cloud.goog"
  target: "${ARGOCD_IP}"
EOF

kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd
  namespace: argocd
  annotations:
    kubernetes.io/ingress.global-static-ip-name: argocd-ingress-ip
    networking.gke.io/managed-certificates: argocd-example-cert
    networking.gke.io/v1beta1.FrontendConfig: argocd-frontend-config
spec:
  rules:
    - host: "frontend.endpoints.${PROJECT_ID}.cloud.goog"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server-external
                port:
                  number: 80
EOF

gcloud services enable --project ${PROJECT_ID} \
  container.googleapis.com \
  mesh.googleapis.com \
  gkehub.googleapis.com \
  multiclusterservicediscovery.googleapis.com \
  multiclusteringress.googleapis.com \
  trafficdirector.googleapis.com \
  certificatemanager.googleapis.com

gcloud container fleet mesh enable --project ${PROJECT_ID}

gcloud container fleet multi-cluster-services enable --project ${PROJECT_ID}

gcloud projects add-iam-policy-binding ${PROJECT_ID} --project ${PROJECT_ID} \
 --member "serviceAccount:${PROJECT_ID}.svc.id.goog[gke-mcs/gke-mcs-importer]" \
 --role "roles/compute.networkViewer"

gcloud compute addresses create whereami-ip --global --project ${PROJECT_ID}

export WHEREAMI_IP=$(gcloud compute addresses describe whereami-ip --project ${PROJECT_ID} --global --format "value(address)") 
echo ${WHEREAMI_IP}

cat <<EOF > ${WORKDIR}/dns-spec.yaml
swagger: "2.0"
info:
  description: "Cloud Endpoints DNS"
  title: "Cloud Endpoints DNS"
  version: "1.0.0"
paths: {}
host: "frontend.endpoints.${PROJECT_ID}.cloud.goog"
x-google-endpoints:
- name: "frontend.endpoints.${PROJECT_ID}.cloud.goog"
  target: "${WHEREAMI_IP}"
EOF

gcloud endpoints services deploy ${WORKDIR}/dns-spec.yaml --project ${PROJECT_ID}

gcloud compute security-policies create edge-fw-policy --project ${PROJECT_ID} \
    --description "Block XSS attacks"

gcloud compute security-policies rules create 1000 --project ${PROJECT_ID} \
    --security-policy edge-fw-policy \
    --expression "evaluatePreconfiguredExpr('xss-stable')" \
    --action "deny-403" \
    --description "XSS attack filtering"


### Need at least one Fleet Membership to assign controller to
gcloud container fleet ingress enable --project ${PROJECT_ID}

gcloud projects add-iam-policy-binding ${PROJECT_ID} --project ${PROJECT_ID} \
    --member "serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-multiclusteringress.iam.gserviceaccount.com" \
    --role "roles/container.admin"


### Do this right before a sync 
gcloud certificate-manager certificates create whereami-cert --project ${PROJECT_ID} \
    --domains="frontend.endpoints.${PROJECT_ID}.cloud.goog"

gcloud certificate-manager maps create whereami-cert-map --project ${PROJECT_ID}

gcloud certificate-manager maps entries create whereami-cert-map-entry --project ${PROJECT_ID} \
    --map="whereami-cert-map" \
    --certificates="whereami-cert" \
    --hostname="frontend.endpoints.${PROJECT_ID}.cloud.goog"

gcloud artifacts repositories create argocd-fleet-plugin-repo \
    --project=fleets-argocd-demo \
    --repository-format=docker \
    --location=us-central1 \
    --description="Docker repository for argocd fleet plugin"

declare -a service_accounts=(
  argocd-server
  argocd-fleet-plugin
  argocd-application-controller
)

kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-fleet-plugin
  namespace: argocd
EOF

for service_account in ${service_accounts}
do
  gcloud projects add-iam-policy-binding ${PROJECT_ID} --project ${PROJECT_ID} \
  --member "serviceAccount:${PROJECT_ID}.svc.id.goog[argocd/${service_account}]" \
  --role roles/gkehub.viewer

  gcloud projects add-iam-policy-binding ${PROJECT_ID} --project ${PROJECT_ID} \
  --member "serviceAccount:${PROJECT_ID}.svc.id.goog[argocd/${service_account}]" \
  --role roles/gkehub.gatewayEditor

  gcloud projects add-iam-policy-binding ${PROJECT_ID} --project ${PROJECT_ID} \
  --member "serviceAccount:${PROJECT_ID}.svc.id.goog[argocd/${service_account}]" \
  --role roles/container.developer
done

kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: argocd
  name: argocd-fleet-plugin-secrets-role
rules:
- apiGroups: [""] # Core API group
  resources: ["secrets"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  namespace: argocd
  name: argocd-fleet-plugin-secrets-rolebinding
subjects:
- kind: ServiceAccount
  name: argocd-fleet-plugin
  namespace: argocd
roleRef:
  kind: Role 
  name: argocd-fleet-plugin-secrets-role 
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: fleet-plugin
  namespace: argocd
data:
  token: "supersecret"
  baseUrl: "http://fleet-plugin.argocd.svc.cluster.local:8888"
  FLEET_PROJECT_NUMBER: "${FLEET_PROJECT_NUMBER}"
  PORT: ":4356"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: argocd-fleet-plugin
  namespace: argocd
spec:
  replicas: 1 # can be scaled up
  selector:
    matchLabels:
      app.kubernetes.io/name: fleet-plugin
  template:
    metadata:
      labels:
        app.kubernetes.io/name: fleet-plugin
    spec:
      serviceAccount: argocd-fleet-plugin
      serviceAccountName: argocd-fleet-plugin
      containers:
      - name: argocd-fleet-plugin
        image: us-central1-docker.pkg.dev/fleets-argocd-demo/argocd-fleet-plugin-repo/argocd-fleet-plugin@sha256:8586c23576077624910a28655b6383016fdd78a38aed4a8768694f0d9e984d2f
        imagePullPolicy: Always
        envFrom:
        - configMapRef:
            name: fleet-plugin
        ports:
          - containerPort: 4356
            name: http
        resources:
          requests:
            memory: "1Gi"
            cpu: "500m"
            ephemeral-storage: "1Gi"
          limits:
            memory: "1Gi"
            cpu: "500m"
            ephemeral-storage: "1Gi"
      volumes:
        - name: token
          secret:
            secretName: fleet-plugin
---
apiVersion: v1
kind: Service
metadata:
  name: fleet-plugin
  namespace: argocd
spec:
  selector:
    app.kubernetes.io/name: fleet-plugin
  ports:
  - name: http
    port: 8888
    targetPort: 4356
---
# This secret lives with the plugin, and is mounted into the plugin container. The ApplicationSet controller must be
# configured with the exact same secret.
apiVersion: v1
kind: Secret
metadata:
  name: fleet-plugin
  namespace: argocd
  labels:
    app.kubernetes.io/part-of: argocd
stringData:
  token: 'supersecret'
EOF