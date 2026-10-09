# VPA, recommendation only (updateMode Off).
# Render: DEPLOY=<name> envsubst < this
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: ${DEPLOY}
  namespace: shop
  labels: { app.kubernetes.io/part-of: shop-demo }
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: ${DEPLOY}
  updatePolicy:
    updateMode: "Off"
