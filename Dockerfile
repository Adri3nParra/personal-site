FROM hugomods/hugo:exts AS builder

WORKDIR /src
COPY . .

ARG BASE_URL=/
RUN hugo --minify --baseURL "${BASE_URL}"

# ---

FROM nginx:alpine

COPY --from=builder /src/public /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
