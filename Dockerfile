FROM alpine:latest AS builder

ENV NGINX_VERSION 1.28
ENV NJS_VERSION 0.9.0
ENV LIBRESSL_VERSION=libressl-4.1.0
ENV BROTLI_BRANCH master

ARG TAG=unspecified

# install dependencies
RUN addgroup -S nginx && adduser -D -S -h /var/cache/nginx -s /sbin/nologin -G nginx nginx \
  && apk update && apk upgrade \
  && apk add --no-cache ca-certificates openssl && update-ca-certificates
RUN apk add --no-cache --virtual .build-deps \
  gcc libc-dev make pcre-dev zlib-dev linux-headers \
  gnupg libxslt-dev gd-dev geoip-dev perl-dev 
RUN apk add --no-cache --virtual .brotli-build-deps \
  autoconf libtool automake git g++ cmake go \
  perl rust cargo  patch libxml2-dev byacc flex \
  libstdc++ libmaxminddb-dev lmdb-dev file openrc 

RUN mkdir /usr/src

# download libressl
RUN cd /usr/src \
  && wget https://ftp.openbsd.org/pub/OpenBSD/LibreSSL/$LIBRESSL_VERSION.tar.gz \
  && tar xzf $LIBRESSL_VERSION.tar.gz \
  && rm $LIBRESSL_VERSION.tar.gz \
  && mv $LIBRESSL_VERSION libressl

# RUN ls -la /usr/src/libressl && exit 1

# clone brotli and njs
RUN cd /usr/src \
  && git clone --branch $BROTLI_BRANCH --depth=1 --recursive --shallow-submodules https://github.com/google/ngx_brotli \
  && git clone --branch $NJS_VERSION   --depth=1 --recursive --shallow-submodules https://github.com/nginx/njs 

# clone nginx
RUN cd /usr/src \
  && wget -qO nginx.tar.gz https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz \
  && tar -zxC /usr/src -f nginx.tar.gz && rm nginx.tar.gz

# configure nginx
RUN cd /usr/src/nginx-$NGINX_VERSION && ./configure \
  --with-ld-opt='-Wl,-z,relro -Wl,-z,now -fPIC' \
  --prefix=/etc/nginx \
  --sbin-path=/usr/sbin/nginx \
  --modules-path=/usr/lib/nginx/modules \
  --conf-path=/etc/nginx/nginx.conf \
  --error-log-path=/var/log/nginx/error.log \
  --http-log-path=/var/log/nginx/access.log \
  --pid-path=/var/run/nginx.pid \
  --lock-path=/var/run/nginx.lock \
  --http-client-body-temp-path=/var/cache/nginx/client_temp \
  --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
  --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
  --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
  --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
  --user=nginx \
  --group=nginx \
  --with-debug  \
  --with-pcre-jit \
  --with-http_ssl_module \
  --with-http_realip_module \
  --with-http_addition_module \
  --with-http_sub_module \
  --with-http_dav_module \
  --with-http_flv_module \
  --with-http_mp4_module \
  --with-http_gunzip_module \
  --with-http_gzip_static_module \
  --with-http_random_index_module \
  --with-http_secure_link_module \
  --with-http_stub_status_module \
  --with-http_auth_request_module \
  --with-http_xslt_module=dynamic \
  --with-http_image_filter_module=dynamic \
  --with-http_geoip_module=dynamic \
  --with-http_perl_module=dynamic \
  --with-threads \
  --with-stream \
  --with-stream_ssl_module \
  --with-stream_ssl_preread_module \
  --with-stream_realip_module \
  --with-stream_geoip_module=dynamic \
  --with-http_slice_module \
  --with-mail \
  --with-mail_ssl_module \
  --with-compat \
  --with-file-aio \
  --with-http_v2_module \
  --with-http_v3_module \
  --add-module=/usr/src/ngx_brotli \
  --add-module=/usr/src/njs/nginx \
  --with-cc-opt=-Wno-error \
  --with-select_module \
  --with-poll_module \
  --with-openssl=/usr/src/libressl \
  --build="docker-nginx ($TAG) $LIBRESSL_VERSION ngx_brotli-$(git --git-dir=/usr/src/ngx_brotli/.git rev-parse --short HEAD) njs-$(git --git-dir=/usr/src/njs/.git rev-parse --short HEAD)"

# build nginx
RUN cd /usr/src/nginx-$NGINX_VERSION \
  && make -j$(getconf _NPROCESSORS_ONLN) \
  && make -j$(getconf _NPROCESSORS_ONLN) install

# clean container
RUN cd /usr/src/nginx-$NGINX_VERSION \
  && rm -rf /etc/nginx/html/ \
  && mkdir /etc/nginx/conf.d/ \
  && mkdir -p /usr/share/nginx/html/ \
  && install -m644 html/index.html /usr/share/nginx/html/ \
  && install -m644 html/50x.html /usr/share/nginx/html/ \
  && ln -s /usr/lib/nginx/modules /etc/nginx/modules \
  && strip /usr/sbin/nginx* \
  && strip /usr/lib/nginx/modules/*.so \
  && rm -rf /etc/nginx/*.default /etc/nginx/*.so \
  && rm -rf /usr/src \
  && apk add --no-cache --virtual .gettext "gettext>=0.21-r2" \
  && mv /usr/bin/envsubst /tmp/ \
  && runDeps="$( \
  scanelf --needed --nobanner /usr/sbin/nginx /usr/lib/nginx/modules/*.so /tmp/envsubst \
  | awk '{ gsub(/,/, "\nso:", $2); print "so:" $2 }' \
  | sort -u \
  | xargs -r apk info --installed \
  | sort -u \
  )" \
  && apk add --no-cache --virtual .nginx-rundeps $runDeps \
  && apk del .brotli-build-deps \
  && apk del .build-deps \
  && apk del .gettext \
  && rm -rf /var/cache/apk/* \
  && mv /tmp/envsubst /usr/local/bin/ \
  # forward request and error logs to docker log collector to get output
  && ln -sf /dev/stdout /var/log/nginx/access.log \
  && ln -sf /dev/stderr /var/log/nginx/error.log 

COPY docker-entrypoint.sh /docker-entrypoint.sh

EXPOSE 80 443
STOPSIGNAL SIGTERM

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]