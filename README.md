# Fintech DevOps — AWS EKS Deployment

**Name:** Ashish sisodia &nbsp;|&nbsp; **Batch:** 2023–2027 &nbsp;|&nbsp; **University:** Bennett University &nbsp;|&nbsp; **Subject:** CSET 452

> Node.js backend · Nginx frontend · PostgreSQL · Deployed on AWS EKS using Terraform, Docker, Kubernetes, GitHub Actions & Argo CD

---

## Project Structure

```
fintech-devops/
├── .github/workflows/ci-cd.yaml
├── backend/          → server.js, Dockerfile, package.json
├── frontend/         → index.html, Dockerfile, nginx.conf
├── k8s/              → all Kubernetes manifests
└── terraform/
    ├── modules/      → vpc/ eks/ db/
    └── environments/ → dev/ prod/
```

---

## (a) Architecture Design

**VPC Layout — us-east-1 (Primary)**
- CIDR: `10.0.0.0/16`, spread across 2 Availability Zones
- Public Subnets `10.0.1.x / 10.0.2.x` → ALB, NAT Gateway
- Private Subnets `10.0.3.x / 10.0.4.x` → EKS worker nodes
- DB Subnets `10.0.5.x / 10.0.6.x` → RDS PostgreSQL

**Service Placement**
- ALB → public subnets (only internet-facing component)
- EKS nodes → private subnets (not directly reachable)
- RDS → DB subnets (accepts traffic from EKS security group only, port 5432)

**Traffic Flow**
```
User → Route 53 → ALB → /api/*  → Backend Pod → RDS
                      → /       → Frontend Pod (Nginx)
```

**Multi-Region — Active Passive**
- Primary: `us-east-1` handles all live traffic
- DR: `us-west-2` runs warm standby at minimum capacity
- Route 53 health checks every 10s — 3 failures → auto DNS switch to DR

**Trade-offs**

| Decision | Benefit | Cost |
|---|---|---|
| Active-passive DR | 70% cheaper than active-active | ~5 min manual DB promotion |
| SPOT EKS nodes | ~70% cheaper than On-Demand | Rare interruptions; K8s reschedules |
| RDS Multi-AZ | Eliminates DB single point of failure | ~2× DB cost |


---

## (b) Terraform Strategy

**Module Structure**
```
terraform/
├── modules/
│   ├── vpc/     → VPC, subnets, IGW, NAT, route tables
│   ├── eks/     → EKS cluster, node group, IAM roles
│   └── db/      → RDS instance, subnet group, security group
└── environments/
    ├── dev/     → main.tf  (small instances, no Multi-AZ)
    └── prod/    → main.tf  (larger instances, Multi-AZ, DR replica)
```

**Remote State — Bootstrap (run once)**
```bash
aws s3api create-bucket --bucket fintech-terraform-state --region us-east-1
aws s3api put-bucket-versioning --bucket fintech-terraform-state \
  --versioning-configuration Status=Enabled
aws dynamodb create-table --table-name terraform-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

**Environment Separation — Folder Based**
- `dev/` and `prod/` each have their own `main.tf` and `terraform.tfvars`
- Each calls the same modules with different variable values
- Separate S3 state keys: `dev/terraform.tfstate`, `prod/terraform.tfstate`
- Passwords passed via `TF_VAR_db_password` — never committed

**Dev environment calls (smaller, cheaper):**
```hcl
module "eks" {
  node_instance_types = ["t3.small"]
  desired_nodes       = 1
  capacity_type       = "SPOT"
}
module "db" {
  db_instance_class   = "db.t3.micro"
  multi_az            = false
}
```

**Prod environment calls (HA, larger):**
```hcl
module "eks" {
  node_instance_types = ["t3.medium"]
  desired_nodes       = 2
  capacity_type       = "SPOT"
}
module "db" {
  db_instance_class   = "db.t3.medium"
  multi_az            = true
}
```

**Multi-Region Handling**
- Provider alias `aws.dr` targets `us-west-2` inside `prod/main.tf`
- DR RDS read replica declared with `provider = aws.dr`
- Separate state file `dr/terraform.tfstate` avoids cross-region conflicts

**Challenges**

- State drift → enforced via `terraform refresh`; no manual console edits
- Concurrent runs → blocked by DynamoDB lock table
- Sensitive state → S3 encryption + `sensitive = true` on password variables
<img width="368" height="1016" alt="Screenshot 2026-05-06 134101" src="https://github.com/user-attachments/assets/7af44556-6fb2-4063-9330-fee66d7b447e" />
<img width="1488" height="1199" alt="Screenshot 2026-05-06 074836" src="https://github.com/user-attachments/assets/85665e82-5ea8-4324-90eb-35fd49687104" />
<img width="1919" height="909" alt="Screenshot 2026-05-06 100342" src="https://github.com/user-attachments/assets/3aa5bb68-573f-40fa-884c-7d86702b2b33" />

---

## (c) Docker & Image Strategy

**Backend — Multi-Stage Dockerfile**
```dockerfile
FROM node:20-alpine AS deps
WORKDIR /app
COPY package.json ./
RUN npm ci --only=production && npm cache clean --force

FROM node:20-alpine
WORKDIR /app
RUN adduser -S appuser -u 1001
COPY --from=deps /app/node_modules ./node_modules
COPY server.js ./
USER appuser
EXPOSE 3000
CMD ["node", "server.js"]
```

**Frontend — Nginx Alpine**
```dockerfile
FROM nginx:1.25-alpine
COPY index.html /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
```

**Optimization & Security**
- Alpine base → backend **188 MB**, frontend **92.6 MB**
- Multi-stage → build tools never land in production image
- Non-root user `appuser` → prevents container privilege escalation
- No secrets in Dockerfile → all passed as runtime env vars
- ECR image scanning → CVE check on every push

**Versioning Strategy**
- Images tagged with Git commit SHA — never `:latest`
- Example: `fintech-backend:a1b2c3d4`
- Every running pod traceable to exact commit
- Rollback = point deployment to previous SHA

**CI/CD Integration**
```bash
TAG=${{ github.sha }}
docker build -t $ECR/fintech-backend:$TAG ./backend/
docker push $ECR/fintech-backend:$TAG
sed -i "s|fintech-backend:.*|fintech-backend:$TAG|" k8s/backend-deployment.yaml
```

---

## (d) Kubernetes Deployment

**Zero-Downtime — Rolling Update**
```yaml
strategy:
  type: RollingUpdate
  rollingUpdate:
    maxSurge: 1        # one new pod created before old is removed
    maxUnavailable: 0  # old pod stays live until new pod is Ready
```
- `readinessProbe` on `/api/health` → traffic only flows to healthy pods
- `terminationGracePeriodSeconds: 30` → in-flight requests complete cleanly

**Autoscaling — HPA**
```yaml
minReplicas: 2
maxReplicas: 4
metrics:
  - cpu  → scale at 70% utilization
  - memory → scale at 80% utilization
```
- HPA chosen over VPA → stateless API scales horizontally, not vertically
- `minReplicas: 2` ensures one pod per AZ at all times

**Secrets Management**
- DB credentials stored in `k8s/postgres-secret.yaml` (Kubernetes Secret)
- Injected as env vars into pods — never in code or images
- `server.js` reads `process.env.DB_HOST`, `process.env.DB_PASSWORD`
- Production upgrade path → AWS Secrets Manager + External Secrets Operator

**Inter-Service Communication**
- Frontend Nginx → `http://backend-service:3000` (Kubernetes ClusterIP DNS)
- Backend → RDS endpoint from env var (injected via Secret)
- All external traffic enters only through ALB Ingress

**GitOps — Argo CD**
- Argo CD watches `k8s/` folder on `main` branch
- Any manifest change → automatic rolling sync to EKS
- `selfHeal: true` → reverts manual `kubectl` changes automatically
- `prune: true` → removes resources deleted from Git
<img width="1285" height="142" alt="Screenshot 2026-05-06 080435" src="https://github.com/user-attachments/assets/42833c69-2aaf-47c3-8229-80585ddabebb" />
<img width="1296" height="493" alt="Screenshot 2026-05-06 082943" src="https://github.com/user-attachments/assets/b9d43209-568c-4cf9-941f-376cfcb6142c" />

---

## (e) CI/CD Pipeline

**Trigger:** push to `main` branch

**Pipeline Stages**

| Stage | Tool | Action |
|---|---|---|
| Checkout | GitHub Actions | Pull latest code |
| Auth | AWS OIDC | Short-lived credentials, no stored keys |
| Build backend | Docker | Build with `github.sha` tag |
| Build frontend | Docker | Build with `github.sha` tag |
| Test | curl | Health check on `/api/health` |
| Push | ECR | Both images pushed to registry |
| Update manifest | sed + git | SHA written into deployment YAML |
| Deploy | Argo CD | Auto-detects YAML change, syncs to EKS |

**GitHub Actions Workflow**
```yaml
on:
  push:
    branches: [main]

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/github-actions-role
          aws-region: us-east-1
      - uses: aws-actions/amazon-ecr-login@v2
      - run: |
          TAG=${{ github.sha }}
          docker build -t $ECR/fintech-backend:$TAG ./backend/ && docker push $ECR/fintech-backend:$TAG
          docker build -t $ECR/fintech-frontend:$TAG ./frontend/ && docker push $ECR/fintech-frontend:$TAG
          sed -i "s|fintech-backend:.*|fintech-backend:$TAG|" k8s/backend-deployment.yaml
          sed -i "s|fintech-frontend:.*|fintech-frontend:$TAG|" k8s/frontend-deployment.yaml
          git config user.name "github-actions" && git config user.email "bot@github.com"
          git add k8s/ && git commit -m "ci: update image tags $TAG" && git push

  deploy:
    needs: build-and-push   # blocked if build fails
    runs-on: ubuntu-latest
    steps:
      - run: echo "Argo CD auto-syncs on manifest change"
```

**Rollback Strategy**
```bash
# Option 1 — Argo CD
argocd app history fintech
argocd app rollback fintech <ID>

# Option 2 — kubectl
kubectl rollout undo deployment/backend -n fintech

# Option 3 — Git revert (cleanest)
git revert HEAD && git push
# Pipeline rebuilds previous image → Argo CD redeploys
```
<img width="1919" height="1101" alt="Screenshot 2026-05-06 100155" src="https://github.com/user-attachments/assets/d659db85-1439-4793-8b72-b4149849b91f" />

<img width="1918" height="1097" alt="Screenshot 2026-05-06 100207" src="https://github.com/user-attachments/assets/6ed23ab5-63d3-48d8-8c52-b4dff3b0fcca" />
<img width="1919" height="1151" alt="Screenshot 2026-05-06 082902" src="https://github.com/user-attachments/assets/23d1d24b-8a5d-4c94-b76c-fda0a4f6bbd3" />
<img width="1915" height="1153" alt="Screenshot 2026-05-06 100358" src="https://github.com/user-attachments/assets/6efcd1ff-8f8c-4fae-9f5b-f67abfa95f00" />

---

## (f) Failure & Failover Scenario

**Scenario:** `us-east-1` goes down — traffic must reach `us-west-2`

**Traffic Failover — Route 53**
- Health check polls `/api/health` on primary ALB every 10s
- 3 consecutive failures (~30s) → Route 53 marks primary `UNHEALTHY`
- DNS automatically returns DR ALB IP — no manual intervention needed
- TTL = 60s → clients reach DR region within 60–90 seconds total

**Data Consistency — RDS Replication**
- RDS read replica in `us-west-2` continuously syncs from primary
- On failover, promote replica to writable primary:

```bash
# Promote replica (~3–5 min)
aws rds promote-read-replica \
  --db-instance-identifier fintech-prod-dr-replica \
  --region us-west-2

# Update K8s secret with new endpoint
kubectl create secret generic db-credentials \
  --from-literal=DB_HOST="new-dr-endpoint.rds.us-west-2.amazonaws.com" \
  --dry-run=client -o yaml | kubectl apply -f -

# Restart backend pods
kubectl rollout restart deployment/backend -n fintech
```

**Recovery Metrics**

| Metric | Value |
|---|---|
| RTO | ~30–60 seconds (DNS TTL + health check) |
| RPO | Seconds (async replication lag) |
| DB promotion | ~3–5 minutes |

**Tools Used**
- Route 53 → failover routing + health checks
- RDS cross-region read replica → continuous data sync
- Argo CD → same manifests auto-synced to DR cluster
- kubectl → secret update + pod restart after promotion

---

## Technologies Used

| Category | Tool |
|---|---|
| Containerization | Docker (multi-stage, Alpine) |
| Registry | Amazon ECR |
| Orchestration | Kubernetes — Minikube (local) / EKS (prod) |
| Infrastructure | Terraform (modular, S3 remote state) |
| CI/CD | GitHub Actions + Argo CD |
| Cloud | AWS — EKS, RDS, ALB, Route 53, S3, ECR |
| Database | PostgreSQL 15 |
| Monitoring | CloudWatch + Prometheus + Grafana |
