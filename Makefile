CLUSTER ?= geo-demo
NS ?= geo
AWS_REGION ?= us-east-1
BUCKET ?= $(shell whoami)-geo-demo-uploads
IMG ?= $(shell whoami)/geo-flask:latest

.PHONY: build push deploy url load destroy
build: ; docker build -t $(IMG) ./app
push:  ; docker push $(IMG)
deploy:
	./infra/bootstrap.sh
	kubectl apply -f k8s/00-namespace.yaml
	kubectl -n $(NS) apply -f k8s/01-secret-db.yaml
	kubectl -n $(NS) apply -f k8s/02-postgres-statefulset.yaml
	kubectl -n $(NS) apply -f k8s/03-service-postgres.yaml
	sed "s#<YOUR_ECR_OR_DOCKERHUB_REPO>/geo-flask:latest#$(IMG)#; s#\${BUCKET}#$(BUCKET)#" k8s/20-flask-deploy.yaml | kubectl -n $(NS) apply -f -
	kubectl -n $(NS) apply -f k8s/21-service-flask.yaml
	kubectl -n $(NS) apply -f k8s/22-ingress.yaml
	kubectl -n $(NS) apply -f k8s/30-hpa.yaml
url: ; @kubectl -n $(NS) get ing flask -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'; echo
load:
	kubectl -n $(NS) run hey --image=rakyll/hey --restart=Never -- -z 60s -c 20 -q 5 http://flask.$(NS).svc.cluster.local/up || true
	kubectl -n $(NS) delete pod hey --ignore-not-found
destroy: ; ./infra/destroy.sh
