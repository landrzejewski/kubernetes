FROM node:18.0-alpine
RUN mkdir /users
COPY *.js /users
COPY package.json /users/
WORKDIR /users
RUN npm install
EXPOSE 3000
ENTRYPOINT ["node", "index.js"]
