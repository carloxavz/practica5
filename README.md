# Cafetería asíncrona

Una cafetería universitaria donde pides desde el teléfono y la respuesta llega de inmediato: "pedido recibido, número 11". Desde ahí la cocina trabaja por su cuenta y el pedido avanza solo por `recibido`, `preparando` y `listo`. Nadie se queda mirando la pantalla mientras le preparan el café; la página consulta el estado cada pocos segundos y te avisa cuando puedes ir a recogerlo.

Para lograrlo, el backend no le pide nada a la cocina directamente. Guarda el pedido en Firestore, deja un mensaje en un tema de Pub/Sub y responde. Pub/Sub le entrega ese mensaje a la cocina, un servicio privado en Cloud Run que nadie más puede llamar. La plantilla trae las tres aplicaciones completas y la infraestructura del frontend y el backend; tu grupo construye en Terraform todo lo que conecta al backend con la cocina.

| Pedir | Seguir el pedido | Pantalla de la cafetería |
|---|---|---|
| ![Menú con el carrito](docs/capturas/menu.png) | ![Número del pedido recién asignado](docs/capturas/pedido.png) | ![Pantalla con las tres columnas](docs/capturas/pantalla.png) |

Si el frontend no logra hablar con el backend, lo dice en vez de quedarse en blanco:

<img src="docs/capturas/sin-backend.png" alt="Frontend sin backend" width="260">

## Arquitectura al terminar la práctica

```mermaid
flowchart LR
    telefono(["Teléfono"])

    subgraph plantilla["Viene en la plantilla"]
        frontend["frontend<br/>Cloud Run, público"]
        backend["backend<br/>Cloud Run, público"]
        firestore[("Firestore<br/>pedidos e inventario")]
        registro["Artifact Registry<br/>imágenes de los servicios"]
    end

    subgraph grupo["Lo construye tu grupo"]
        tema{{"Tema de Pub/Sub"}}
        suscripcion["Suscripción push<br/>con token OIDC"]
        cocina["cocina<br/>Cloud Run, privado"]
        invocador["Cuenta invocadora"]
        agente["Agente de servicio<br/>de Pub/Sub<br/>service-NÚMERO@<br/>gcp-sa-pubsub.iam.<br/>gserviceaccount.com"]
    end

    telefono -->|"carga la página"| frontend
    telefono -->|"GET /menu, POST /pedidos"| backend
    backend -->|"guarda el pedido"| firestore
    backend -->|"publica el id"| tema
    tema --> suscripcion
    suscripcion -->|"POST / con token"| cocina
    suscripcion -->|"token a nombre de"| invocador
    cocina -->|"cambia el estado y descuenta"| firestore

    backend -.->|"pubsub.publisher"| tema
    agente -.->|"iam.serviceAccountTokenCreator"| invocador
    invocador -.->|"run.invoker"| cocina
```

Las flechas punteadas son los permisos de IAM que da tu grupo. La etiqueta es el rol sin el prefijo `roles/` y la flecha llega al recurso sobre el que se da: el backend puede publicar solo en ese tema, el agente de Pub/Sub puede firmar tokens como la cuenta invocadora y esa cuenta puede invocar solo a la cocina.

En la plantilla, el backend ya sabe publicar, pero la variable `TEMA` está vacía: guarda el pedido, registra una advertencia y no avisa a nadie. Por eso, recién desplegada, la cafetería recibe pedidos que se quedan en `recibido` para siempre.

## Estructura del repositorio

```
backend/main.py            API en Flask: menú, pedidos, inventario y publicación en Pub/Sub
backend/requirements.txt   Dependencias del backend con versión fija
backend/Dockerfile         Imagen del backend con gunicorn
cocina/main.py             Worker que recibe las entregas push y prepara los pedidos
cocina/requirements.txt    Dependencias de la cocina con versión fija
cocina/Dockerfile          Imagen de la cocina con gunicorn
frontend/index.html        La página: vista para pedir y pantalla de la cafetería
frontend/server.py         Servidor sin dependencias que inyecta BACKEND_URL en la página
frontend/Dockerfile        Imagen del frontend
infra/providers.tf         Versión de Terraform y del proveedor de Google
infra/variables.tf         Proyecto, prefijo, región e imágenes
infra/main.tf              APIs, registro, Firestore, backend y frontend con sus cuentas
infra/outputs.tf           Ruta del registro y URL de los servicios
infra/terraform.tfvars.example   Ejemplo de valores; cópialo como terraform.tfvars
docs/api.md                Endpoints del backend y formato del mensaje de Pub/Sub
docs/estados.md            Ciclo de vida de un pedido y quién hace cada cambio
docs/capturas/             Capturas de la aplicación usadas en este README
.gitignore                 Deja por fuera el estado de Terraform, tus tfvars y __pycache__
```

## Cómo empezar

### Flujo de trabajo

1. Crea el repositorio de tu grupo con **Use this template** en GitHub.
2. Edita en VS Code o en github.dev (tecla `.` en la página del repositorio).
3. Haz commit y push desde el editor.
4. En Cloud Shell clonas la primera vez y traes los cambios con `git pull` después. Desde Cloud Shell nunca haces push.
5. Docker y Terraform se ejecutan siempre en Cloud Shell. La consola de Google Cloud es para mirar y diagnosticar, no para crear recursos.

### Primer despliegue

En Cloud Shell:

```bash
git clone https://github.com/<tu-usuario>/<tu-repositorio>.git
cd <tu-repositorio>/infra
cp terraform.tfvars.example terraform.tfvars
cloudshell edit terraform.tfvars
```

En `terraform.tfvars` pon el ID de tu proyecto y el prefijo del grupo, y ajusta las rutas de las imágenes a esos mismos valores. Este archivo vive solo en Cloud Shell: el `.gitignore` evita que llegue a GitHub.

El orden importa, porque las imágenes necesitan el registro y los servicios necesitan las imágenes:

```bash
# 1. Solo el registro (y las APIs de las que depende)
terraform init
terraform apply -target=google_artifact_registry_repository.registro

# 2. Las imágenes
REGISTRO=$(terraform output -raw registro)
gcloud auth configure-docker us-central1-docker.pkg.dev --quiet
cd ..
docker build -t $REGISTRO/backend:v1 backend
docker push $REGISTRO/backend:v1
docker build -t $REGISTRO/frontend:v1 frontend
docker push $REGISTRO/frontend:v1

# 3. Todo lo demás
cd infra
terraform apply
terraform output
```

Abre `url_frontend` en el teléfono. Si usas otra región, cambia `us-central1` en el comando de `gcloud auth configure-docker`.

Cuando cambies el código de un servicio, construye y sube la imagen con una etiqueta nueva (`v2`, `v3`...), actualízala en `terraform.tfvars` y vuelve a aplicar. Si subes otra vez la misma etiqueta, Terraform no ve ningún cambio y Cloud Run sigue con la versión anterior.

## Probar cada servicio con `docker run`

Antes de subir una imagen, pruébala en Cloud Shell. Para ver una página servida en Cloud Shell usa **Vista previa en la Web** y elige el puerto.

**Frontend.** No necesita credenciales:

```bash
docker run --rm -p 8080:8080 -e BACKEND_URL=https://<url-del-backend> $REGISTRO/frontend:v1
```

Abre la vista previa en el puerto 8080. Si no pasas `BACKEND_URL`, verás el mensaje de error de la captura de arriba.

**Backend sin Firestore.** El contenedor arranca aunque no tenga credenciales; la validación de pedidos no toca la base, así que puedes comprobarla:

```bash
docker run --rm -d --name backend -p 8081:8080 $REGISTRO/backend:v1
curl -i -X POST localhost:8081/pedidos -H 'Content-Type: application/json' -d '{"cliente": "Ana", "items": []}'
docker logs backend
docker rm -f backend
```

Debe responder `400` con el error en JSON.

**Backend con Firestore.** Cuando la base ya existe (después del primer `terraform apply` completo), puedes darle al contenedor tus propias credenciales:

```bash
gcloud auth application-default login
docker run --rm -d --name backend -p 8081:8080 \
  -e GOOGLE_CLOUD_PROJECT=<tu-proyecto> \
  -e BASE_DATOS=<prefijo>-cafeteria \
  -e GOOGLE_APPLICATION_CREDENTIALS=/adc.json \
  -v $HOME/.config/gcloud/application_default_credentials.json:/adc.json:ro \
  $REGISTRO/backend:v1
curl localhost:8081/menu
curl -X POST localhost:8081/pedidos -H 'Content-Type: application/json' \
  -d '{"cliente": "Ana", "items": [{"producto": "tinto", "cantidad": 1}]}'
```

**Cocina.** Escucha en `/` el mismo sobre que le entregaría Pub/Sub. Con las mismas credenciales, puedes hacerte pasar por Pub/Sub y entregarle a mano un pedido que esté en `recibido`:

```bash
docker build -t cocina cocina
docker run --rm -d --name cocina -p 8082:8080 \
  -e GOOGLE_CLOUD_PROJECT=<tu-proyecto> \
  -e BASE_DATOS=<prefijo>-cafeteria \
  -e GOOGLE_APPLICATION_CREDENTIALS=/adc.json \
  -v $HOME/.config/gcloud/application_default_credentials.json:/adc.json:ro \
  cocina
ID=<id de un pedido en recibido>
curl -i -X POST localhost:8082/ -H 'Content-Type: application/json' \
  -d "{\"message\": {\"data\": \"$(printf %s "$ID" | base64)\"}, \"deliveryAttempt\": 1}"
docker logs cocina
```

Responde `204` cuando termina, unos segundos después. Mira el pedido en la pantalla de la cafetería: acabas de hacer a mano lo que Pub/Sub va a hacer solo.

La cocina tiene dos variables para provocar fallas: `TIEMPO_PREPARACION` (segundos que tarda, 6 por defecto) y `PROBABILIDAD_FALLO` (entre 0 y 1; con esa probabilidad responde `500` después de haber terminado el trabajo). Los detalles están en [docs/api.md](docs/api.md) y el recorrido de un pedido en [docs/estados.md](docs/estados.md).

El plato misterioso falla siempre, y sin un tema de mensajes muertos Pub/Sub lo sigue reintentando mientras retenga el mensaje, que por defecto son 7 días. Cada intento deja un error en los logs de la cocina, así que se van a llenar hasta que tu grupo resuelva esa parte del reto.

---

# Informe del grupo

## Integrantes

| Nombre | Código | Usuario de GitHub |
|---|---|---|
| Juan David Marciales Niebles | 1152431 | JDmn195 |
| Carlos Antonio Avendaño | 1152406 | carloxavz |

El despliegue se hizo con la cuenta de Carlos (carlosantonioav@ufps.edu.co) en el proyecto `nube-2026-ii`, prefijo `marci`, región `us-central1`.

## URL de la cafetería

Frontend: https://marci-frontend-24cnlwn55q-uc.a.run.app

Backend: https://marci-backend-24cnlwn55q-uc.a.run.app

> Para no generar costos, la infraestructura se destruyó con `terraform destroy` el 2026-11-09 (01:25 UTC). Antes de la revisión se levanta de nuevo, con las mismas URLs, desde Cloud Shell con `bash scripts/reproducir.sh` (requiere `infra/terraform.tfvars` con `cocina:v2`; tarda unos 7 minutos).

## Diagrama propio

```mermaid
flowchart LR
    telefono(["Teléfono"])
    todos(["allUsers"])

    subgraph proyecto["Proyecto nube-2026-ii, us-central1"]
        frontend["marci-frontend<br/>Cloud Run, público"]
        backend["marci-backend<br/>Cloud Run, público<br/>SA marci-backend"]
        firestore[("Firestore<br/>marci-cafeteria")]
        registro["Artifact Registry<br/>marci-imagenes"]
        tema_pedidos{{"Tema marci-pedidos"}}
        sub_cocina["Suscripción push marci-cocina<br/>OIDC, ack 60 s<br/>reintentos 10-60 s<br/>dead letter a 5 intentos"]
        cocina["marci-cocina<br/>Cloud Run, privado<br/>SA marci-cocina<br/>máx 3 instancias x 8"]
        invocador["Cuenta marci-invocador"]
        agente["Agente de Pub/Sub<br/>service-NÚMERO@<br/>gcp-sa-pubsub.iam.<br/>gserviceaccount.com"]
        tema_muertos{{"Tema marci-muertos"}}
        sub_muertos["Suscripción pull<br/>marci-muertos-lectura"]
    end

    telefono -->|"carga la página"| frontend
    telefono -->|"GET /menu, POST /pedidos"| backend
    backend -->|"guarda el pedido"| firestore
    backend -->|"publica el id"| tema_pedidos
    tema_pedidos --> sub_cocina
    sub_cocina -->|"POST / con token"| cocina
    sub_cocina -->|"token a nombre de"| invocador
    cocina -->|"estado e inventario"| firestore
    sub_cocina -->|"5 intentos fallidos"| tema_muertos
    tema_muertos --> sub_muertos
    registro -->|"imágenes"| frontend
    registro -->|"imágenes"| backend
    registro -->|"imágenes"| cocina

    todos -.->|"run.invoker"| frontend
    todos -.->|"run.invoker"| backend
    backend -.->|"pubsub.publisher"| tema_pedidos
    backend -.->|"datastore.user"| firestore
    cocina -.->|"datastore.user"| firestore
    agente -.->|"iam.serviceAccountTokenCreator"| invocador
    invocador -.->|"run.invoker"| cocina
    agente -.->|"pubsub.publisher"| tema_muertos
    agente -.->|"pubsub.subscriber"| sub_cocina
```

Las flechas continuas son el flujo de datos; las punteadas son los permisos de IAM (rol sin el prefijo `roles/`), cada una llegando al recurso sobre el que se concede.

## Evidencias por fase

### Fase 0

Se verificó el entorno de Cloud Shell: cuenta `carlosantonioav@ufps.edu.co`, proyecto `nube-2026-ii`, Terraform v1.9.5 y Docker 29.9.3. El repositorio es `https://github.com/carloxavz/practica5.git` y los colaboradores son JDmn195 y carloxavz.

![gcloud config list](evidencias/evidencia-0/gcloud-config-list.jpg)

```
[core]
account = carlosantonioav@ufps.edu.co
project = nube-2026-ii
origin https://github.com/carloxavz/practica5.git (fetch)
Terraform v1.9.5 (~/bin/terraform), Docker 29.9.3
```

### Fase 1

Se creó primero el registro (`apply -target`, 7 recursos: 6 APIs y `marci-imagenes`), se subieron las tres imágenes `v1` y luego se aplicó todo (8 recursos: Firestore `marci-cafeteria`, backend y frontend con sus cuentas y permisos). El pedido #1 de prueba quedó en `recibido` tras ~30 s, porque `TEMA` está vacío y el backend lo avisa en su log.

Nota: el push de backend y cocina falló 3 veces con `dial tcp ...:443: connect: connection refused`; se resolvió con `{"max-concurrent-uploads": 1}` en `/etc/docker/daemon.json` de Cloud Shell.

![Pedido recibido](evidencias/evidencia-1/pedido-recibido.jpg)
![Log del backend con el tema vacío](evidencias/evidencia-1/log-backend-tema-vacio.jpg)
![Artifact Registry con 3 imágenes](evidencias/evidencia-1/artifact-registry-3-imagenes.jpg)

```
Apply complete! Resources: 8 added, 0 changed, 0 destroyed.
url_backend  = "https://marci-backend-24cnlwn55q-uc.a.run.app"
url_frontend = "https://marci-frontend-24cnlwn55q-uc.a.run.app"
WARNING:backend:TEMA está vacío: el pedido uoshOWdn5GR33tyEzOEz se guardó pero nadie le avisa a la cocina
```

### Fase 2

Se creó el tema `marci-pedidos` y el permiso `pubsub.publisher` del backend sobre él; el backend ya publica. Sin embargo el tema no tiene suscripciones (la consola avisa "Se perderán los mensajes publicados en este tema"), así que el pedido #2 (`okse4t32mYq7kpU6GCrN`) sigue en `recibido` tras ~32 s.

![Pedido 2 recibido](evidencias/evidencia-2/pedido2-recibido.jpg)
![Log del backend publicando](evidencias/evidencia-2/log-backend-publicado.jpg)
![Temas de Pub/Sub](evidencias/evidencia-2/pubsub-temas.jpg)
![Aviso de tema sin suscripción](evidencias/evidencia-2/tema-aviso-sin-suscripcion.jpg)
![Tema con 0 suscripciones](evidencias/evidencia-2/tema-0-suscripciones.jpg)

```
Apply complete! Resources: 2 added, 1 changed, 0 destroyed.
INFO:backend:Pedido okse4t32mYq7kpU6GCrN publicado en projects/nube-2026-ii/topics/marci-pedidos
```

### Fase 3

Se desplegó la cocina privada, la cuenta `marci-invocador` (con `run.invoker` solo sobre la cocina), el permiso `iam.serviceAccountTokenCreator` del agente de Pub/Sub sobre el invocador y la suscripción push con OIDC. Un `curl` sin token recibe 403; el pedido #3 pasó a `listo` en ~11 s al primer intento. El #2 sigue en `recibido` porque se perdió en la fase 2.

![curl a la cocina con 403](evidencias/evidencia-3/curl-cocina-403.jpg)
![Pedido 3 listo](evidencias/evidencia-3/pedido3-listo.jpg)
![Pantalla con el pedido 2 aún en recibido](evidencias/evidencia-3/pantalla-pedido2-sigue-recibido.jpg)
![Log de la cocina procesando](evidencias/evidencia-3/log-cocina-procesando.jpg)
![Requests 403 y 204](evidencias/evidencia-3/requests-403-y-204.jpg)
![Detalle de la suscripción](evidencias/evidencia-3/suscripcion-detalle.jpg)
![Cabecera de la suscripción](evidencias/evidencia-3/suscripcion-cabecera.jpg)

Vista de teléfono (marco de 390 px de ancho), un pedido avanzando solo:

<img src="evidencias/evidencia-3/telefono-preparando.jpg" alt="Pedido en preparando, vista de teléfono" width="420"> <img src="evidencias/evidencia-3/telefono-listo.jpg" alt="Pedido listo, vista de teléfono" width="420">

```
$ curl -i -X POST https://marci-cocina-24cnlwn55q-uc.a.run.app/
HTTP/2 403
18:52:09.816 POST 403 0 ms curl/8.5.0       (sin token)
18:53:08.524 POST 204 8.003 s APIs-Google   (push de Pub/Sub con token OIDC)
18:53:16.552 INFO:cocina:Pedido 4o4ZoFWgXhEOtpB81jrf listo
```

### Fase 4

Se lanzó una ráfaga de 60 pedidos de 1 tinto, 20 en paralelo: 60 respuestas 201 en 1,10 s. La pantalla pasó de 16 en `recibido` (~5 s) a todo procesado en ~30 s; los números no salen en orden. En Firestore quedaron 22 pedidos `listo` y 38 `rechazado`, con el inventario de tinto en -2 (20 existencias): condición de carrera entre revisar y descontar. Cloud Run usó como máximo 3 instancias de la cocina.

![Pantalla a los 5 s](evidencias/evidencia-4/pantalla-5s.jpg)
![Pantalla a los 15 s](evidencias/evidencia-4/pantalla-15s.jpg)
![Pantalla a los 30 s](evidencias/evidencia-4/pantalla-30s.jpg)
![Inventario de tinto negativo](evidencias/evidencia-4/inventario-tinto-negativo.jpg)
![Mensajes no confirmados en Pub/Sub](evidencias/evidencia-4/pubsub-no-confirmados.jpg)
![Instancias de la cocina](evidencias/evidencia-4/cloudrun-instancias-cocina.jpg)
![Solicitudes y latencia de Cloud Run](evidencias/evidencia-4/cloudrun-requests-latencia.jpg)

```
{"total":60,"conteo":{"201":60},"segundos":"1.10"}
Firestore: 22 listo, 38 rechazado
Inventario de tinto: 20 -> -2
```

**La cola, vista en Pub/Sub.** La gráfica *Mensajes sin confirmar por región* de `marci-cocina` (ventana de 1 h) muestra picos de unos 45 mensajes entre las 7:43 y las 7:51 p. m. (UTC-5), que corresponden a las ráfagas de 60 pedidos de la medición de la fase 6, y cómo cada pico baja a 0 en uno o dos minutos mientras la cocina vacía la cola; *Antigüedad del mensaje sin confirmar* llega a ~1 min. En la primera ráfaga la métrica todavía no había llegado al abrir la consola.

![Mensajes sin confirmar: picos y vaciado de la cola](evidencias/evidencia-4/pubsub-no-confirmados-picos.jpg)

**Ráfaga repetida con la cocina idempotente** (fase 6, 01:14 UTC): 60 × 201 en 1,43 s; los pedidos se ven en recibido y preparando y salen desordenados, pero el tinto termina en **0**, no en negativo: 20 listos y el resto rechazados.

![Ráfaga 2: columnas recibido y preparando](evidencias/evidencia-4/rafaga2-pantalla-columnas.jpg)
![Ráfaga 2: tinto en 0](evidencias/evidencia-4/rafaga2-tinto-0-idempotente.jpg)
![Ráfaga 2: instancias de la cocina](evidencias/evidencia-4/cloudrun-instancias-rafaga2.jpg)

### Fase 5

Con `PROBABILIDAD_FALLO = "0.5"` se enviaron 4 pedidos de 1 tinto (inventario repuesto a 20). La cocina responde 500 después de terminar el trabajo, Pub/Sub reintenta a los ~12-20 s y la cocina de la plantilla vuelve a descontar. Resultado: 9 entregas procesadas y 9 tintos descontados (20 -> 11) en vez de 4 (promedio 2,25 entregas por pedido; teórico 2).

![Logs de duplicados y la cuenta](evidencias/evidencia-5/logs-cocina-duplicados-y-cuenta.jpg)

```
Veces "listo" por pedido: q34n... 4, 90mA... 2, yiPW... 2, D7pJ... 1  => 9 entregas
4 pedidos de 1 tinto descontaron 9 tintos (20 -> 11). Debieron ser 4 (quedar 16).
```

### Fase 6

Se desplegó `cocina:v2` idempotente (transacción de Firestore), el tema `marci-muertos`, la suscripción pull `marci-muertos-lectura` y la política de mensajes muertos con 5 intentos. Con la misma falla del 50 %, 4 pedidos generaron 7 entregas (3 repetidas, detectadas) y el inventario pasó de 20 a 16: cuadra. El plato misterioso (`CtSpGvdBgOH0rK8xYkgT`) se reintentó 5 veces en ~66 s y apareció en `marci-muertos-lectura`.

![Logs de la entrega repetida detectada](evidencias/evidencia-6/idempotencia-logs-entrega-repetida.jpg)
![Mensaje muerto leído](evidencias/evidencia-6/mensaje-muerto-leido.jpg)
![Mediciones](evidencias/evidencia-6/mediciones.jpg)

```
00:22:06 INFO:cocina:Pedido sLlrD4RFba2artjLVIhO, intento de entrega 2
00:22:06 INFO:cocina:Pedido sLlrD4RFba2artjLVIhO ya estaba listo; entrega repetida, no se descuenta otra vez
RESULTADO: 7 entregas para 4 pedidos (3 repetidas), tinto 20 -> 16.

$ gcloud pubsub subscriptions pull marci-muertos-lectura --auto-ack --limit=5
data = CtSpGvdBgOH0rK8xYkgT
CloudPubSubDeadLetterSourceDeliveryCount=5
CloudPubSubDeadLetterSourceSubscription=marci-cocina
```

Mediciones (60 pedidos de 1 tinto, 20 en paralelo, `scripts/medir.sh`; tiempo del último terminado = max(actualizado) en Firestore menos el primer POST):

| Corrida | Máx. instancias | Publicar (s) | Último terminado (s) | Terminados | Listos |
|---|---|---|---|---|---|
| max3-a1 | 3 | 6,9 | 54,7 (arranque en frío) | 60/60 | 20 |
| max3-a2 | 3 | 6,1 | 32,7 | 60/60 | 20 |
| max3-a3 | 3 | 11,7 | 32,9 | 60/60 | 20 |
| max1-a1 | 1 | 10,3 | 68,6 | 60/60 | 20 |
| max1-a2 | 1 | 11,6 | 59,3 | 60/60 | 20 |
| max1-a3 | 1 | 11,3 | 56,4 | 60/60 | 20 |

Promedio en caliente: ~32,8 s con 3 instancias y ~57,9 s con 1 (excluyendo arranques en frío). En todas hubo exactamente 20 pedidos listos con 20 tintos (en la fase 4 fueron 22 y el inventario quedó en -2). Se descartaron dos corridas que se solaparon con otra ráfaga y una primera serie en la que un pedido no se creó por la red de Cloud Shell.

## Decisiones del reto

**Cómo sabe la cocina que un pedido ya se preparó.** Consulta el campo `estado` del pedido en Firestore. Primer filtro barato: si ya está `listo` o `rechazado`, responde 204 sin hacer nada. Filtro definitivo: la lectura del estado, la lectura de existencias y la escritura (descontar y marcar `listo`) van en una sola transacción de Firestore (`@firestore.transactional` en `cocina/main.py`, función `terminar`). Si dos entregas del mismo pedido llegan a la vez a dos instancias, ambas pasan el primer filtro, pero Firestore serializa las transacciones: la segunda detecta que los documentos que leyó cambiaron, se reintenta, ve `estado = listo` y devuelve "repetido" sin descontar. Lo mismo arregla el inventario negativo de la fase 4, porque revisar y descontar ya no están separados. Además, `recibido` a `preparando` solo se escribe si el pedido está en `recibido`, así que un pedido `listo` no retrocede.

**Intentos antes de rendirse.** `max_delivery_attempts = 5`, el mínimo que admite Pub/Sub. Con `retry_policy` de 10 a 60 s, un pedido normal que falla por algo pasajero (un 500 simulado o contención de la transacción) se reintenta y casi siempre pasa en el 2.º o 3.er intento; 5 intentos cubren ~1-2 minutos de fallas pasajeras. El plato misterioso, que falla siempre, se rinde en ~66 s (medido) en vez de reintentarse 7 días. Riesgo: una falla pasajera que dure más de 5 intentos manda el pedido a muertos y queda en `preparando`; desde `marci-muertos-lectura` se puede leer y reprocesar.

**Permisos de los mensajes muertos.** `roles/pubsub.publisher` sobre `marci-muertos`, para que el agente de Pub/Sub reenvíe ahí el mensaje; `roles/pubsub.subscriber` sobre la suscripción `marci-cocina`, para que pueda confirmar (ack) y retirar el mensaje de la suscripción original al moverlo. Sin la suscripción `marci-muertos-lectura`, el tema de muertos no tendría a quién guardarle la copia y el mensaje se perdería (igual que el pedido de la fase 2).

**Cómo medimos.** Con `scripts/medir.sh`: 60 pedidos, `xargs -P 20` desde Cloud Shell, y sondeo de Firestore con `runQuery` hasta que todos están `listo` o `rechazado`; tiempo = max(`actualizado`) menos el primer POST. Fueron 3 repeticiones con `max_instancias_cocina=3` y 3 con `=1` (variable de Terraform, `-var`); los resultados están en la tabla de la fase 6. Lo que limitó: 6 s de preparación por el número de tandas (24 a la vez con 3 instancias, 8 con 1), la contención de la transacción sobre el documento `tinto` y el backoff de Pub/Sub cuando una transacción aborta, el arranque en frío, y la red de Cloud Shell al publicar (6-12 s). Firestore por pedido: 3 lecturas y 5 escrituras (backend 0 L / 2 E, cocina 3 L / 3 E), más 1 lectura por cada sondeo del teléfono; una entrega repetida cuesta 1 lectura y 0 escrituras.

**Reproducir.** `terraform destroy` (28 recursos) y `scripts/reproducir.sh` (registro, imágenes y luego todo), sin pasos en la consola.

Resultado: `terraform destroy -parallelism=1` borró 28 recursos (00:54:14 → 00:56:04 UTC). Se esperaron ~6 minutos por la reserva del nombre de la base de Firestore y `bash scripts/reproducir.sh` reconstruyó todo (01:01:58 → ~01:08 UTC): 7 recursos con `-target` del registro, las tres imágenes (`backend:v1`, `frontend:v1`, `cocina:v2`) y 21 recursos más, 28 en total, con las mismas URLs. Prueba de humo después de reconstruir: un pedido nuevo (#1) quedó `listo`, `curl -X POST` a la cocina sin token respondió `403` y `terraform plan -detailed-exitcode` salió con código 0 (sin diferencias entre el código y la nube).

![Reproducción: 7 + 21 recursos y URLs](evidencias/evidencia-6/reproduccion-apply.jpg)
![Prueba de humo tras reconstruir](evidencias/evidencia-6/reproduccion-prueba.jpg)

**Incidencias del entorno.** Cloud Shell rechazó conexiones (`connection refused`) cuando había muchas conexiones en paralelo; se resolvió con `max-concurrent-uploads=1` en Docker y `-parallelism=1` en Terraform.

## Preguntas

**1. ¿Por qué el pedido de la fase 2 nunca se preparó?** Un tema de Pub/Sub no almacena mensajes: solo entrega una copia a cada suscripción que exista en el momento de publicar. Cuando se publicó el pedido #2 (`okse4t32mYq7kpU6GCrN`), `marci-pedidos` no tenía suscripciones, así que no había ninguna copia que guardar y el mensaje se descartó (la consola lo advierte). La suscripción `marci-cocina`, creada en la fase 3, solo recibe mensajes publicados después de existir; por eso el #2 sigue en `recibido` (evidencia 3).

**2. ¿Qué pasa si se quita `run.invoker` de la cuenta invocadora?** Pub/Sub sigue firmando el token OIDC como `marci-invocador`, pero Cloud Run lo rechaza con 403 antes de llegar al código de la cocina. Se nota en cuanto se propaga el cambio de IAM (alrededor de 1-2 minutos, igual que al darlo) y con el siguiente pedido. El backend sigue respondiendo 201 y el cliente ve su número, pero el pedido se queda en `recibido` para siempre (o hasta 5 intentos y luego va a `marci-muertos-lectura`). El error no aparece en los registros de texto de la cocina: está en su registro de solicitudes `run.googleapis.com/requests` (POST 403, user agent `APIs-Google`) y en las métricas de la suscripción (mensajes sin confirmar creciendo, respuestas push 403), como el 403 del `curl` de la fase 3.

**3. Con `PROBABILIDAD_FALLO=0.5`, ¿cuál es el número promedio de entregas por pedido?** Cada entrega se confirma con probabilidad 0,5, así que el número de entregas es geométrico con media 1/(1-0,5) = 2, en ambas cocinas (la idempotencia no cambia cuántas veces llega el mensaje). Lo que cambia es cuántas veces se prepara y descuenta: con la cocina de la plantilla cada entrega descuenta, así que ≈2 tintos por pedido; con la cocina idempotente solo la primera entrega descuenta (las demás ven `listo` y responden 204), así que 1 por pedido. Medido: plantilla, 4 pedidos, 9 entregas y 9 tintos descontados (20 a 11, 2,25 por pedido); idempotente, 4 pedidos, 7 entregas, 3 repetidas detectadas, 4 tintos descontados (20 a 16, 1 por pedido). Además, en la idempotente las entregas repetidas se cortan en el primer filtro y responden 204 sin pasar otra vez por la falla simulada, por eso hubo menos entregas (1,75) que el promedio teórico de 2; con 4 pedidos la muestra es pequeña.
