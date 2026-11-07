# MesaTech Cloud – EP1 + EP2 (DSY1107): backend completo

Backend de MesaTech Cloud: **BFF con Spring Security** + **dos microservicios** en EC2 distintas, cada uno con su propio RDS, integrados por **RabbitMQ** (Docker Compose en una tercera EC2).

```
React (MSAL) ─► Entra ID (token)
   │ Bearer
   ▼
API Gateway (HTTP API, CORS, JWT Authorizer)
   ▼
BFF (Spring Security, 2ª validación JWT + roles)         ← sin acceso a bases de datos
   ├─► Catálogo (EC2 A) ──► RDS Catálogo
   │        │ publica evento (persistente + confirmación)
   │        ▼
   │   RabbitMQ (EC2 C, Docker Compose)
   │        │ catalogo.exchange ─categoria.creada→ solicitudes.catalogo.queue
   │        ▼
   └─► Solicitudes (EC2 B) ──► RDS Solicitudes (solicitudes + copia local de categorías)
```

> **Modo de la evaluación EP2 (acordado con el profesor): se prueba solo con Postman, directo a Catálogo y Solicitudes. El BFF y React no se necesitan para la demo** (el BFF queda como material de la EP1).

> **No incluido:** React/MSAL, la configuración de Entra ID y la de API Gateway (son frontend/configuración en consola; abajo hay una guía de valores).

## Estructura

| Carpeta | Contenido |
|---|---|
| `mesatech-bff/` | BFF (puerto 8080): valida JWT de Entra ID, autoriza por rol y reenvía a los microservicios. |
| `mesatech-catalogo/` | Catálogo (EC2 A, puerto 8081): categorías y prioridades; **publicador**. |
| `mesatech-solicitudes/` | Solicitudes (EC2 B, puerto 8082): solicitudes y estados; **consumidor**. |
| `infra/rabbitmq/` | `compose.yaml`, `.env.example`, `setup-rabbitmq.sh` (vhost, usuarios, permisos, exchange, cola, binding). |

## Versiones

Java 21 · Spring Boot 4.1.1 (igual que los proyectos del profesor) · Spring Security 7 · Spring AMQP + Jackson 3 · Maven (wrapper incluido) · MySQL (RDS) · RabbitMQ `3.13.7-management`. Anotar también `docker --version` y `docker compose version` reales.

## Variables de entorno

Cada proyecto trae `.env.example` con valores ficticios. Copiarlo como `.env` junto al `pom.xml` (la app lo importa sola) o exportar variables en la EC2. **Nunca subir `.env` real** (está en `.gitignore`).

## Compilar

```bash
for p in mesatech-bff mesatech-catalogo mesatech-solicitudes; do (cd $p && ./mvnw clean package -DskipTests); done
```

## Despliegue y orden

1. **RDS**: dos instancias exclusivas y privadas (sin acceso público), con base y usuario de aplicación (`sql/schema-*.sql` o `ddl-auto=update`).
2. **EC2 C – RabbitMQ**: instalar Docker + Compose; copiar `infra/rabbitmq/`; `cp .env.example .env`; luego
   `docker compose config --quiet && docker compose pull && docker compose up -d && docker compose ps` y `bash setup-rabbitmq.sh`.
3. **EC2 B – Solicitudes**, 4. **EC2 A – Catálogo**, 5. **BFF** (`java -jar target/<artefacto>.jar`; BFF puede ir en A o B).

Recuperación tras caída: RabbitMQ → Solicitudes → Catálogo → BFF.

## Security groups mínimos

| Destino | Puerto | Origen |
|---|---|---|
| EC2 RabbitMQ | 5672 | SG de EC2 A y SG de EC2 B |
| EC2 RabbitMQ | 15672 | tu IP `/32` |
| RDS Catálogo / RDS Solicitudes | 3306 | SG de EC2 A / SG de EC2 B (respectivamente) |
| Catálogo 8081 y Solicitudes 8082 | TCP | SG del BFF (solo el BFF debe llamarlos) |
| BFF 8080 | TCP | API Gateway (HTTP API no tiene IP fija; sin VPC Link queda abierto, pero el BFF rechaza todo lo que no traiga un JWT válido) |
| EC2 A / B / C | 22 | tu IP `/32` |

## Seguridad en el BFF (EP1)

Valida **firma** (JWKS de Entra), **expiración**, **issuer**, **audience** y **scope** (`scp`). Si falla algo → `401`. Si el token es válido pero el rol no alcanza → `403`.

| Operación | Cliente | Operador | Administrador |
|---|:-:|:-:|:-:|
| `POST /v1\|v2/solicitudes` | ✔ | ✔ | ✔ |
| `GET /v1\|v2/solicitudes/mias` | ✔ | ✔ | ✔ |
| `GET /v1\|v2/solicitudes` y `/{id}` | ✘ | ✔ | ✔ |
| `PATCH /v1\|v2/solicitudes/{id}/estado` | ✘ | ✔ | ✔ |
| `GET /v1\|v2/solicitudes/categorias[/{id}]` | ✔ | ✔ | ✔ |
| `GET /v1\|v2/catalogo/**` | ✔ | ✔ | ✔ |
| `POST/PUT/DELETE /v1\|v2/catalogo/**` | ✘ | ✘ | ✔ |

Los roles se leen del claim `roles` (App Roles de Entra: `Cliente`, `Operador`, `Administrador`). El BFF envía la identidad del usuario a Solicitudes en la cabecera `X-Usuario` (claim `preferred_username`); las cabeceras que manda el cliente no se copian.

## Valores a configurar en Entra ID y API Gateway (guía)

**Entra ID**
- *App registration "API"*: Application ID URI `api://<client-id>`; scope `access_as_user` (Expose an API); **App Roles** `Cliente`, `Operador`, `Administrador` (allowed member types: Users); en el manifest `requestedAccessTokenVersion = 2` (así el issuer es `https://login.microsoftonline.com/<tenant>/v2.0`).
- *App registration "SPA"*: plataforma Single-page application con Redirect URI de React; permiso delegado al scope del API. Asignar usuarios de prueba a los roles en *Enterprise applications → Users and groups*.

**API Gateway (HTTP API)**: rutas `ANY /v1/{proxy+}` y `ANY /v2/{proxy+}` → integración HTTP hacia `http://<IP-BFF>:8080/{proxy}` (ajustar el mapeo para conservar el prefijo `/v1` o `/v2`); **JWT Authorizer** con issuer `https://login.microsoftonline.com/<tenant>/v2.0` y audience `<client-id del API>`; **CORS** con el origen de React, métodos `GET,POST,PUT,PATCH,DELETE,OPTIONS` y cabeceras `Authorization, Content-Type`.

## Contrato del evento (RabbitMQ)

Exchange `catalogo.exchange` (direct, durable) · routing key `categoria.creada` · cola `solicitudes.catalogo.queue` (durable) · vhost `mesatech` · mensaje persistente, `messageId` = `eventId`.

| Campo | Tipo | Descripción |
|---|---|---|
| `eventId` | string (UUID) | Identificador único del evento |
| `tipoEvento` | string | `CATEGORIA_CREADA` |
| `fechaEvento` | string ISO-8601 UTC | Momento de creación del evento |
| `categoriaId` | number | Id original en Catálogo (PK de la copia en Solicitudes) |
| `nombre` | string | Nombre de la categoría |

```json
{
  "eventId": "6f1c1d1e-8a43-4b0e-9c57-2f3a9d0b7e11",
  "tipoEvento": "CATEGORIA_CREADA",
  "fechaEvento": "2026-11-05T23:15:42.318754Z",
  "categoriaId": 7,
  "nombre": "Soporte de red"
}
```

## Endpoints de los microservicios (prefijo `/api`, detrás del BFF)

**Catálogo**: `GET /v1|v2/catalogo` · `GET/POST /v1|v2/catalogo/categorias` · `GET /v1|v2/catalogo/categorias/{id}` · `PUT/DELETE /v1/catalogo/categorias/{id}` · `GET/POST /v1/catalogo/prioridades` · `PUT/DELETE /v1/catalogo/prioridades/{id}`.
`POST` de categoría: guarda en RDS → publica → `201` con cabecera `X-Event-Id`; si el broker no confirma responde `502` indicando que **la categoría pudo quedar guardada**.

**Solicitudes**: `POST /v1|v2/solicitudes` · `GET /v1|v2/solicitudes` · `GET /v1|v2/solicitudes/mias` · `GET /v1|v2/solicitudes/{id}` · `PATCH /v1|v2/solicitudes/{id}/estado` · `GET /v1/solicitudes/categorias` · `GET /v1/solicitudes/categorias/{categoriaId}` (404 hasta que el evento llega: sirve para saber cuándo ya se puede crear la solicitud).

**v1 vs v2 (qué cambió y por qué v1 se mantiene):** v2 de catálogo incluye la prioridad dentro de cada categoría; v2 de solicitudes agrega `categoriaNombre`, `atencion` y `fechaCreacion`. v1 se conserva porque los clientes existentes dependen de su contrato.

**Estados:** `CREADA → ASIGNADA → EN_PROCESO → RESUELTA → CERRADA`; `CANCELADA` desde CREADA, ASIGNADA o EN_PROCESO. Pasar a `RESUELTA` sin estar `EN_PROCESO` responde `409`.

## Prueba rápida de los microservicios (sin BFF)

```bash
curl -X POST localhost:8081/api/v1/catalogo/prioridades -H 'content-type: application/json' \
     -d '{"nombre":"ALTA","tiempoRespuestaHoras":4}'
curl -i -X POST localhost:8081/api/v1/catalogo/categorias -H 'content-type: application/json' \
     -d '{"nombre":"Soporte de red","descripcion":"Fallas de conectividad","prioridadId":1}'
curl localhost:8082/api/v1/solicitudes/categorias/1
curl -X POST localhost:8082/api/v1/solicitudes -H 'content-type: application/json' -H 'X-Usuario: ana@mesatech.cl' \
     -d '{"titulo":"Sin internet","descripcion":"Piso 3","categoriaId":1,"prioridad":"ALTA"}'
curl -X PATCH localhost:8082/api/v1/solicitudes/1/estado -H 'content-type: application/json' \
     -d '{"estado":"RESUELTA"}'      # => 409 (no esta EN_PROCESO)
```

## Supuestos

- La prioridad de la solicitud (`BAJA/MEDIA/ALTA/CRITICA`) es un campo de la solicitud; solo la **categoría** se replica por evento (EP2).
- Los microservicios confían en el BFF (cabecera `X-Usuario`): por eso solo deben ser alcanzables desde el SG del BFF.

## Riesgos que se deben saber explicar (EP2)

- **Guardar en RDS y publicar son dos operaciones separadas**: si el guardado funciona y la publicación falla (P7), la categoría queda en Catálogo pero Solicitudes no la recibe. Reenviar el POST puede chocar con el nombre único (`409`).
- **Confirmación del publicador ≠ procesamiento**: el *confirm* indica que RabbitMQ aceptó el mensaje; la escritura en RDS Solicitudes la confirma el *ack* del consumidor.
- **Re-entrega**: si el consumidor guarda y cae antes del ack, el mensaje vuelve. La PK `categoria_id` evita filas duplicadas, pero no se garantiza «exactamente una vez».

## Pruebas con Postman (carpeta `postman/`)

Importar `MesaTech-EP2.postman_collection.json` y `MesaTech-EC2.postman_environment.json`; en el environment cambiar `catalogoUrl` y `solicitudesUrl` por las IP de las EC2 A y B. Sin BFF, la cabecera `X-Usuario` es opcional (por defecto `usuario.demo@mesatech.cl`; la colección usa la variable `usuario`).

| Prueba EP2 | Cómo hacerla |
|---|---|
| **P1** Separación real | Evidencia de consola: IDs de EC2 A/B, endpoints de los dos RDS y `SELECT` en cada uno. |
| **P2** Flujo completo | Carpeta **A** (A1, A2) y **B** (B1, B3): crear categoría → log del publicador → log del consumidor → fila en `categoria_local` → solicitud creada con esa categoría. |
| **P3** Consumidor detenido | Detener Solicitudes → **C1** (201) → **C2** (404) → en RabbitMQ la cola muestra Ready = 1. |
| **P4** Consumo diferido | Iniciar Solicitudes → **C2** (200); la cola queda con Ready = 0 y Unacked = 0. |
| **P5** Reinicio del broker | Consumidor detenido → **C1** → `docker compose up -d --force-recreate` (sin `-v`) → comprobar vhost/exchange/cola/mensaje → iniciar consumidor → **C2** (200). |
| **P6** Reinicio de apps | Reiniciar ambos servicios y repetir **A3**, **B2**, **B12**: los datos siguen. |
| **P7** Fallo de publicación | `docker compose stop` en EC2 C → **C1** responde `502 PUBLICACION_NO_CONFIRMADA` → consultar RDS Catálogo (la categoría quedó) → `docker compose start`. |
| **P8** Continuidad EP1 | v1/v2: **A3/A4** y **B10/B11**; regla de estado: **B5** (409). Login y rechazo sin token requieren BFF + Entra ID (no se prueban con este modo). |
