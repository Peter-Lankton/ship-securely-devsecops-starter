# ==== config ====
APP_NAME=app
IMAGE=ship-securely/app:dev
PROFILE=ship
NAMESPACE=ship
K8S_DIR=infra/k8s
SBOM_FILE=artifacts/sbom.json

# ==== CI ====
ci: init build dockerlint sast secrets iac sbom sign verify sca zap

init:
	@mkdir -p artifacts .trivy-db

build:
	docker build -t $(IMAGE) app

dockerlint:
	@echo "== Hadolint (Dockerfile) =="
	docker run --rm -i hadolint/hadolint < app/Dockerfile > artifacts/hadolint.txt || true

sast:
	@echo "== Semgrep (SAST) =="
	docker run --rm -v $(PWD):/src returntocorp/semgrep semgrep --config p/owasp-top-ten --sarif --output /src/artifacts/semgrep.sarif /src/app || true

secrets:
	@echo "== TruffleHog (secrets) =="
	docker run --rm -v $(PWD):/repo -w /repo \
	  ghcr.io/trufflesecurity/trufflehog:latest \
	  filesystem --json . > artifacts/trufflehog.json || true
	@echo "wrote artifacts/trufflehog.json"

iac:
	@echo "== Checkov (IaC) =="
	docker run --rm -v $(PWD):/work bridgecrew/checkov -d /work/infra --output-file-path artifacts/checkov.json || true

sbom:
	@echo "== Syft (SBOM) =="
	docker run --rm -v $(PWD):/work anchore/syft:latest scan dir:/work/app -o json > $(SBOM_FILE)

sign:
	@echo "== (Optional) Cosign sign image (skips if key missing) =="
	@if [ -f cosign.key ]; then \
		cosign sign --key cosign.key $(IMAGE); \
	else \
		echo "cosign.key not found; skipping sign"; \
	fi

verify:
	@echo "== (Optional) Cosign verify (skips if pub key missing) =="
	@if [ -f cosign.pub ]; then \
		cosign verify --key cosign.pub $(IMAGE) > artifacts/cosign-verify.txt || true; \
	else \
		echo "cosign.pub not found; skipping verify"; \
	fi

sca:
	@echo "== Trivy (image scan) =="
	docker run --rm -v $(PWD):/workspace -v $(PWD)/.trivy-db:/root/.cache/trivy aquasec/trivy:latest image --ignore-unfixed --format json -o /workspace/artifacts/trivy-image.json $(IMAGE) || true

zap:
	@echo "== OWASP ZAP (baseline against local k8s service if available) =="
	@mkdir -p artifacts/zap
	# Try to get a service URL from Minikube; fallback to localhost
	@URL=$$(minikube -p $(PROFILE) service $(APP_NAME) -n $(NAMESPACE) --url 2>/dev/null | head -n1); \
	if [ -z "$$URL" ]; then URL=http://localhost:8080; fi; \
	echo "ZAP target: $$URL"; \
	docker run --rm -t -v $(PWD)/tools/zap:/zap/wrk owasp/zap2docker-stable zap-baseline.py -t $$URL -r /zap/wrk/report.html || true

# ==== CD (Minikube) ====
cd: mk-up build mk-image-load k8s-ns k8s-apply k8s-verify
	@echo "✅ Deployed $(APP_NAME) to Minikube ($(PROFILE)) in namespace $(NAMESPACE)"

mk-up:
	@if ! minikube status -p $(PROFILE) >/dev/null 2>&1; then \
	  echo "⛵ Starting Minikube ($(PROFILE))"; \
	  minikube start -p $(PROFILE) --cpus=2 --memory=4096; \
	else echo "⛵ Minikube ($(PROFILE)) is running"; fi

mk-down:
	- minikube stop -p $(PROFILE) || true

mk-delete:
	- minikube delete -p $(PROFILE) || true

mk-image-load:
	minikube -p $(PROFILE) image load $(IMAGE)

k8s-ns:
	- kubectl get ns $(NAMESPACE) >/dev/null 2>&1 || kubectl create ns $(NAMESPACE)

k8s-apply:
	@if [ -f "$(K8S_DIR)/kustomization.yaml" ]; then \
	  kubectl -n $(NAMESPACE) apply -k $(K8S_DIR); \
	else \
	  kubectl -n $(NAMESPACE) apply -f $(K8S_DIR); \
	fi
	-kubectl -n $(NAMESPACE) set image deploy/$(APP_NAME) $(APP_NAME)=$(IMAGE)

k8s-verify:
	kubectl -n $(NAMESPACE) rollout status deploy/$(APP_NAME)

k8s-port:
	@minikube -p $(PROFILE) service $(APP_NAME) -n $(NAMESPACE) --url

k8s-logs:
	kubectl -n $(NAMESPACE) logs -l app=$(APP_NAME) -f --tail=200
