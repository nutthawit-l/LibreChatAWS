# Rendered by makefile — do not apply by hand. Source: values.yaml.tpl
replicaCount: 1

global:
  librechat:
    existingSecretName: "librechat-credentials-env"
    existingSecretApiKey: OPENAI_API_KEY

mongodb:
  enabled: false

redis:
  enabled: false

meilisearch:
  enabled: true
  persistence:
    enabled: true
    storageClass: "gp3"
  auth:
    existingMasterKeySecret: "librechat-credentials-env"

# RAG needs an embeddings provider; Groq has no embeddings API.
# Re-enable when wiring another embed backend (e.g. OpenAI / local).
librechat-rag-api:
  enabled: false

librechat:
  existingSecretName: "librechat-credentials-env"
  imageVolume:
    enabled: true
    size: 10Gi
    accessModes: ReadWriteOnce
    storageClassName: gp3
  configEnv:
    HOST: "0.0.0.0"
    PORT: "3080"
    DOMAIN_CLIENT: "${DOMAIN_CLIENT}"
    DOMAIN_SERVER: "${DOMAIN_SERVER}"
    MONGO_URI: "${MONGO_URI}"
    USE_REDIS: "true"
    REDIS_URI: "${REDIS_URI}"
    ALLOW_REGISTRATION: "${ALLOW_REGISTRATION}"
    ALLOW_EMAIL_LOGIN: "${ALLOW_EMAIL_LOGIN}"
    AWS_REGION: "${AWS_REGION}"
    AWS_BUCKET_NAME: "${AWS_BUCKET_NAME}"
    # Credentials live in Secret librechat-credentials-env
  configYamlContent: |
    version: 1.2.1
    cache: true
    fileStrategy: "s3"
    endpoints:
      custom:
        - name: "Groq"
          apiKey: "${GROQ_API_KEY}"
          baseURL: "https://api.groq.com/openai/v1/"
          models:
            default:
              - "${GROQ_MODEL}"
              - "llama-3.1-8b-instant"
              - "gemma2-9b-it"
            fetch: false
          titleConvo: true
          titleModel: "current_model"
          summarize: false
          summaryModel: "current_model"
          modelDisplayLabel: "Groq"

ingress:
  enabled: true
  className: alb
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    alb.ingress.kubernetes.io/healthcheck-path: /health
    alb.ingress.kubernetes.io/load-balancer-attributes: idle_timeout.timeout_seconds=3600
${ACM_CERT_ANNOTATION}
  hosts:
    - host: ${DOMAIN}
      paths:
        - path: /
          pathType: Prefix

service:
  type: ClusterIP
  port: 3080
  targetPort: 3080
  containerPort: 3080

resources:
  requests:
    cpu: "250m"
    memory: 512Mi
  limits:
    memory: 2Gi
