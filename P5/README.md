si ya tenemos docker, entonces necesitaremos instalar lo siguiente, en mi caso lo haré con Minikube ya que es mas completo y facil de usar a largo plazo.

## 1. Instalar kubectl:

```bash
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
```

## 2. Instalar Minikube:

```bash
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube
```

## 3. Instalar Helm 3:

```bash
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh
```

## 4. Instalar k6:
Esto es para hacer pruebas de estrés.

```bash
curl -fsSL https://dl.k6.io/key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/k6-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" | sudo tee /etc/apt/sources.list.d/k6.list
sudo apt-get update
sudo apt-get install k6
```

---

## 5. Iniciar el clúster (Start)

Inicia Minikube y configura tu terminal para apuntar al entorno Docker de Minikube. Esto es necesario para que Kubernetes encuentre tus imágenes locales sin necesidad de subirlas a Docker Hub.

```bash
# Iniciar minikube
minikube start

# Apuntar el entorno de docker local hacia minikube
eval $(minikube docker-env)
```

## 6. Construir las imágenes (Build)

Una vez que el entorno de docker apunta a minikube, debes compilar las imágenes de los microservicios:

```bash
docker build -t api-gateway:latest ./api-gateway
docker build -t auth:latest ./auth/auth-service
docker build -t catalog:latest ./catalog/catalog-service
docker build -t orders:latest ./orders/order-service
docker build -t notifications:latest ./notifications/notification-service
```

## 7. Desplegar el proyecto (Deploy)

Utiliza Helm para instalar el stack completo en el namespace designado.

```bash
# Crear el namespace si no existe
kubectl create namespace sa-p5

# Actualizar dependencias de helm (NATS, MySQL, etc)
helm dependency update ./charts/sa-platform

# Instalar el chart completo
helm install sa-platform ./charts/sa-platform -n sa-p5 -f ./charts/sa-platform/values-dev.yaml
```

## 8. Modificar y Actualizar (Modify & Update)

Si haces cambios en el código de algún servicio, debes recompilar su imagen y reiniciar el deployment:

```bash
# Ejemplo: si modificaste auth-service
eval $(minikube docker-env)
docker build -t auth:latest ./auth/auth-service

# Reiniciar el pod para que tome la nueva imagen
kubectl rollout restart deployment sa-platform-auth -n sa-p5
```

Si haces cambios en los archivos `.yaml` de Helm, aplica los cambios usando `upgrade`:
```bash
helm upgrade sa-platform ./charts/sa-platform -n sa-p5 -f ./charts/sa-platform/values-dev.yaml
```

## 9. Monitorear y Probar (Test)

Revisar el estado de los pods para asegurar que todo está funcionando:
```bash
# Ver los pods (debes esperar a que todos estén 1/1 Running o 2/2 Running)
kubectl get pods -n sa-p5 -w

# Ver logs de un pod específico
kubectl logs deployment/sa-platform-auth -n sa-p5
```

Para acceder a la API Gateway desde tu máquina, puedes usar el túnel de minikube:
```bash
minikube service sa-platform-api-gateway -n sa-p5
```
*(Esto te abrirá un túnel y te asignará una IP local con puerto para hacer tus pruebas en Postman o en el navegador)*

## 10. Apagar y Limpiar (Stop & Clean)

Para desinstalar toda la arquitectura sin borrar el clúster:
```bash
helm uninstall sa-platform -n sa-p5
```

Para apagar el nodo de minikube (conservando los datos para la próxima vez que lo inicies):
```bash
minikube stop
```

Si deseas borrar el clúster por completo y empezar desde cero:
```bash
minikube delete
```