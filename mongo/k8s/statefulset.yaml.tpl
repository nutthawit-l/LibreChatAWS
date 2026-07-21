apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mongo
  namespace: mongo
  labels:
    app: mongo
spec:
  serviceName: mongo
  replicas: 1
  selector:
    matchLabels:
      app: mongo
  template:
    metadata:
      labels:
        app: mongo
    spec:
      containers:
        - name: mongo
          image: ${IMAGE}
          imagePullPolicy: IfNotPresent
          ports:
            - name: mongo
              containerPort: 27017
          env:
            - name: MONGO_INITDB_ROOT_USERNAME
              valueFrom:
                secretKeyRef:
                  name: mongo-credentials
                  key: MONGO_USER
            - name: MONGO_INITDB_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mongo-credentials
                  key: MONGO_PASSWORD
            - name: MONGO_INITDB_DATABASE
              valueFrom:
                secretKeyRef:
                  name: mongo-credentials
                  key: MONGO_DB
          readinessProbe:
            tcpSocket:
              port: mongo
            initialDelaySeconds: 15
            periodSeconds: 10
            timeoutSeconds: 5
          livenessProbe:
            tcpSocket:
              port: mongo
            initialDelaySeconds: 40
            periodSeconds: 20
            timeoutSeconds: 5
          resources:
            requests:
              cpu: "100m"
              memory: 256Mi
            limits:
              cpu: "500m"
              memory: 512Mi
          volumeMounts:
            - name: data
              mountPath: /data/db
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: ${STORAGE_CLASS}
        resources:
          requests:
            storage: ${STORAGE_SIZE}
