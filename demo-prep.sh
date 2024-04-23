export WORKDIR=`pwd`
PROJECT_NUMBER=$(gcloud projects describe ${PROJECT_ID} --format="value(projectNumber)")

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

