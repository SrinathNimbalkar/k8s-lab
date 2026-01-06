Kubernetes Ingress on Minikube (macOS) — Hands-On Summary

This document summarizes how I successfully configured NGINX Ingress on a local Minikube cluster (macOS) and the key learnings from the process.

🎯 Objective

Expose an application running inside Kubernetes using Ingress, following real-world Kubernetes traffic flow:

Browser → Ingress → Service → Pod

🧠 Key Challenges (Context)

Most tutorials (including TechWorld with Nana) assume:

Linux or cloud Kubernetes clusters

Direct node IP access

However, my setup was:

Minikube

macOS

Docker driver

This introduces additional networking layers that require special handling.

🛠️ Steps Performed
1. Enable NGINX Ingress Controller

Ingress resources do nothing without a controller.

minikube addons enable ingress


Verification:

kubectl get pods -n ingress-nginx


✔ ingress-nginx-controller running

2. Deploy a Sample Application (nginx)
kubectl create deployment web --image=nginx
kubectl expose deployment web --port=80 --type=ClusterIP


Verification:

kubectl get pods
kubectl get svc web
kubectl get endpoints web


✔ Pod running
✔ Service created
✔ Endpoints attached

3. Create the Ingress Resource

Ingress rules define host-based routing.

apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web-ingress
spec:
  ingressClassName: nginx
  rules:
  - host: web.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web
            port:
              number: 80


Apply and verify:

kubectl apply -f ingress.yaml
kubectl describe ingress web-ingress


✔ Ingress synced
✔ Backend service resolved

🚨 Why Ingress Didn’t Work Initially

On Minikube (macOS):

Ingress controller is exposed via NodePort

Minikube VM is not directly reachable

Browser traffic never reached the ingress controller

Ingress configuration was correct — network exposure was missing.

🔑 Critical Fix: Expose Ingress via Minikube
minikube service ingress-nginx-controller -n ingress-nginx


This:

Creates a local tunnel

Exposes ingress on 127.0.0.1:<random-port>

Requires the terminal to stay open

Example:

http://127.0.0.1:62069

⚠️ Final Issue: Host Header Mismatch

Ingress routing depends on the HTTP Host header, not IP.

Ingress rule expected:

Host: web.local


But browser sent:

Host: 127.0.0.1


➡️ Result: buffering / no routing

✅ Final Fix: Update /etc/hosts

Because traffic reached localhost, the host mapping had to match:

sudo vi /etc/hosts


Add:

127.0.0.1   web.local


Now access:

http://web.local:<port>


🎉 NGINX page loads successfully

🧠 Final Mental Model
DNS (/etc/hosts) → gets traffic TO ingress
Host header      → tells ingress WHERE to route


Ingress only cares about host + path, not IP addresses.

🏁 Key Learnings

Ingress requires an Ingress Controller

Ingress routes traffic to Services, not Pods

Host header must match ingress rules

Minikube on macOS requires explicit exposure

Real cloud clusters (EKS/GKE/AKS) do not need these workarounds

📌 Interview-Ready One-Liner

Ingress routes external HTTP/S traffic to internal Kubernetes services using host and path rules, implemented by an ingress controller like NGINX.
