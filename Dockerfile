FROM nginx:alpine
MAINTAINER jaeger <jiang_gw@126.com>

RUN apk update && \
    apk add -u curl iptables --no-cache
RUN rm /etc/nginx/nginx.conf

COPY nginx.conf /etc/nginx/nginx.conf
COPY entrypoint.sh /entrypoint.sh

EXPOSE 80

ENTRYPOINT ["/entrypoint.sh"]
