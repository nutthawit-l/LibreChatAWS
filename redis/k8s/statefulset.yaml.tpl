apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: redis
  namespace: redis
  labels:
    app: redis
spec:
  serviceName: redis
  replicas: 1
  selector:
    matchLabels:
      app: redis
  template:
    metadata:
      labels:
        app: redis
    spec:
      containers:
        - name: redis
          image: ${IMAGE}
          imagePullPolicy: IfNotPresent
          command: ["sh", "-c"]
          args:
            - >-
              exec redis-server
              --appendonly yes
              --requirepass "$REDIS_PASSWORD"
              --maxmemory 64mb
              --maxmemory-policy allkeys-lru
          ports:
            - name: redis
              containerPort: 6379
          env:
            - name: REDIS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: redis-credentials
                  key: REDIS_PASSWORD
          readinessProbe:
            tcpSocket:
              port: redis
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            tcpSocket:
              port: redis
            initialDelaySeconds: 15
            periodSeconds: 20
          resources:
            requests:
              cpu: "50m"
              memory: 64Mi
            limits:
              cpu: "250m"
              memory: 128Mi
          volumeMounts:
            - name: data
              mountPath: /data
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: ${STORAGE_CLASS}
        resources:
          requests:
            storage: ${STORAGE_SIZE}
