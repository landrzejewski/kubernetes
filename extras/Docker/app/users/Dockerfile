FROM node:18.0-alpine AS builder
WORKDIR /app
COPY package.json .
RUN npm install
COPY *.js ./

FROM node:18.0-alpine
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
WORKDIR /users
COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/*.js ./
RUN chown -R appuser:appgroup /users
USER appuser
EXPOSE 3000
ENTRYPOINT ["node", "index.js"]
