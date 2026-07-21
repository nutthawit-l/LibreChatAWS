# Generated at deploy time from ingress.yaml.tpl — do not edit by hand.
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: unpod
  labels:
    app.kubernetes.io/part-of: unpod
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    # Attach your ACM certificate ARN:
    # alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:ACCOUNT:certificate/ID
    alb.ingress.kubernetes.io/healthcheck-path: /
    # Long-lived websockets (LiveKit signaling / Centrifugo / chat)
    alb.ingress.kubernetes.io/load-balancer-attributes: idle_timeout.timeout_seconds=3600
spec:
  ingressClassName: alb
  rules:
    - host: ${WEB_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: web
                port:
                  number: 3000
    - host: ${API_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: backend-core
                port:
                  number: 8000
    - host: ${CHAT_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: api-services
                port:
                  number: 9116
    - host: ${CENTRIFUGO_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: centrifugo
                port:
                  number: 8000
