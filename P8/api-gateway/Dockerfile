FROM nginx:1.29.1-alpine

# Trae los parches de seguridad ya publicados para esta misma versión de
# Alpine (no cambia de versión mayor, solo actualiza paquetes del SO).
RUN apk update && apk upgrade --no-cache

ARG APP_VERSION=0.0.0-dev
ARG FAULT_MODE=false

# Metadatos trazables de la imagen.
LABEL org.opencontainers.image.title="sa-api-gateway" \
      org.opencontainers.image.version="${APP_VERSION}"

COPY nginx.conf /tmp/nginx.conf

# Genera nginx.conf según el tipo de versión solicitada.
RUN set -eu; \
    case "$FAULT_MODE" in \
      false) health_code=200; health_status=ok ;; \
      true) health_code=500; health_status=error ;; \
      *) echo "FAULT_MODE debe ser true o false" >&2; exit 1 ;; \
    esac; \
    \
    sed \
      -e "s/__APP_VERSION__/${APP_VERSION}/g" \
      -e "s/__HEALTH_STATUS_CODE__/${health_code}/g" \
      -e "s/__HEALTH_STATUS__/${health_status}/g" \
      /tmp/nginx.conf > /etc/nginx/nginx.conf; \
    \
    rm /tmp/nginx.conf

# Prepara los directorios que Nginx necesita escribir sin utilizar root.
RUN chown -R 10001:10001 /var/cache/nginx \
    && chown -R 10001:10001 /var/log/nginx \
    && chown -R 10001:10001 /etc/nginx/conf.d \
    && touch /var/run/nginx.pid \
    && chown 10001:10001 /var/run/nginx.pid

USER 10001:10001
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
