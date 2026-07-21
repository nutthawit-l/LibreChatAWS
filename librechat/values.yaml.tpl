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

librechat-rag-api:
  enabled: true
  embeddingsProvider: ollama
  postgresql:
    enabled: false
    auth:
      database: "${POSTGRES_DB}"
      username: "${POSTGRES_USER}"
      existingSecret: "librechat-vectordb"
      secretKeys:
        userPasswordKey: postgres-password
        adminPasswordKey: postgres-password
        replicationPasswordKey: postgres-password
  rag:
    configEnv:
      DB_PORT: "${POSTGRES_PORT}"
      DB_HOST: "${POSTGRES_HOST}"
      EMBEDDINGS_PROVIDER: ollama
      OLLAMA_BASE_URL: "${OLLAMA_URL}"
      EMBEDDINGS_MODEL: "${OLLAMA_EMBED_MODEL}"

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
        - name: "Ollama"
          apiKey: "ollama"
          baseURL: "${OLLAMA_URL}/v1/"
          models:
            default:
              - "${OLLAMA_MODEL}"
            fetch: true
          titleConvo: true
          titleModel: "current_model"
          summarize: false
          summaryModel: "current_model"
          modelDisplayLabel: "Ollama"

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
