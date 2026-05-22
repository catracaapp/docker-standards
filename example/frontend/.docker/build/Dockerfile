# =====================================================================
# Frontend é estático: nginx serve um único index.html + faz reverse
# proxy de /api/* pro BFF via DNS interno.
# Sem multi-stage porque não há build step — é a exceção da regra.
# =====================================================================

FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html
EXPOSE 80
