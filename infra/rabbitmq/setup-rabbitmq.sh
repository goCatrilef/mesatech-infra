#!/usr/bin/env bash
# Crea (de forma reproducible) los recursos de RabbitMQ de MesaTech usando la API HTTP de administracion.
# Ejecutar EN la EC2 C, despues de "docker compose up -d":   bash setup-rabbitmq.sh
# Es idempotente: se puede ejecutar de nuevo sin romper nada.
set -euo pipefail

cd "$(dirname "$0")"
set -a; source .env; set +a

API="http://localhost:15672/api"
AUTH="${RABBITMQ_ADMIN_USER}:${RABBITMQ_ADMIN_PASSWORD}"

VHOST="mesatech"
EXCHANGE="catalogo.exchange"
QUEUE="solicitudes.catalogo.queue"
ROUTING_KEY="categoria.creada"

put()  { curl -sS -f -u "$AUTH" -H 'content-type: application/json' -X PUT  "$API/$1" -d "$2" -o /dev/null && echo "OK  PUT  $1"; }
post() { curl -sS -f -u "$AUTH" -H 'content-type: application/json' -X POST "$API/$1" -d "$2" -o /dev/null && echo "OK  POST $1"; }

echo "== Esperando a que la API de administracion responda =="
for i in $(seq 1 30); do
  curl -sS -f -u "$AUTH" "$API/overview" -o /dev/null && break
  sleep 2
done

echo "== 1. Virtual host =="
put "vhosts/${VHOST}" '{}'

echo "== 2. Usuarios (sin tags: ninguno es administrador) =="
put "users/${RABBITMQ_PUBLISHER_USER}" "{\"password\":\"${RABBITMQ_PUBLISHER_PASSWORD}\",\"tags\":\"\"}"
put "users/${RABBITMQ_CONSUMER_USER}"  "{\"password\":\"${RABBITMQ_CONSUMER_PASSWORD}\",\"tags\":\"\"}"

echo "== 3. Permisos sobre el vhost (configure / write / read) =="
# El admin ve todo el vhost en la interfaz web.
put "permissions/${VHOST}/${RABBITMQ_ADMIN_USER}" '{"configure":".*","write":".*","read":".*"}'
# Publicador: SOLO puede escribir (publicar) en catalogo.exchange. No lee ni configura nada.
put "permissions/${VHOST}/${RABBITMQ_PUBLISHER_USER}" '{"configure":"","write":"^catalogo\\.exchange$","read":""}'
# Consumidor: SOLO puede leer su cola. "configure" limitado a esa misma cola porque Spring la verifica al arrancar.
put "permissions/${VHOST}/${RABBITMQ_CONSUMER_USER}" '{"configure":"^solicitudes\\.catalogo\\.queue$","write":"","read":"^solicitudes\\.catalogo\\.queue$"}'

echo "== 4. Exchange direct durable =="
put "exchanges/${VHOST}/${EXCHANGE}" '{"type":"direct","durable":true,"auto_delete":false,"internal":false}'

echo "== 5. Cola durable, sin autoeliminacion =="
put "queues/${VHOST}/${QUEUE}" '{"durable":true,"auto_delete":false}'

echo "== 6. Binding exchange -> cola con la routing key =="
post "bindings/${VHOST}/e/${EXCHANGE}/q/${QUEUE}" "{\"routing_key\":\"${ROUTING_KEY}\"}"

echo
echo "Listo. Verifica en http://<IP-autorizada>:15672 -> vhost '${VHOST}' -> Exchanges / Queues."
